// Onboarding/ViewModel/OnboardingViewModel.swift
import SwiftUI
import Combine
import os // Import os for logging if not already done

// Assume BackendType exists in Models/BackendType.swift
// Assume OllamaModelInfo exists in Models/OllamaModelInfo.swift

// Logger for ViewModel actions
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.Devgentic", category: "OnboardingViewModel")

@MainActor // Ensure changes to @Published properties happen on the main actor
class OnboardingViewModel: ObservableObject {

    // MARK: - Enums for State Management
    enum OnboardingStep: Identifiable {
        case welcome, selectCategory, selectMethod
        case configureOllamaLocal, configureOllamaApi, configureAgentLocal, configureAgentApi
        case complete
        var id: OnboardingStep { self }
    }
    enum SetupMethod: Identifiable {
         case guidedLocal, existingApi
         var id: SetupMethod { self }
    }

    // MARK: - Published Properties (State)
    @Published var currentStep: OnboardingStep = .welcome
    @Published var selectedCategory: BackendType? = nil
    @Published var selectedMethod: SetupMethod? = nil

    // --- State for Step 4a (Ollama Local Setup via Script) ---
    let recommendedOllamaModels: [OllamaModelInfo] = [ // Example list
        OllamaModelInfo(name: "llama3", displayName: "Llama 3", sizeDescription: "8B Instruct"),
        OllamaModelInfo(name: "mistral", displayName: "Mistral", sizeDescription: "7B Instruct"),
        OllamaModelInfo(name: "codellama", displayName: "Code Llama", sizeDescription: "7B Code"),
        OllamaModelInfo(name: "phi3", displayName: "Phi-3 Mini", sizeDescription: "3.8B Instruct (Small)"),
    ]
    @Published var selectedModelNames: Set<String> = ["llama3"] // Default selection

    // --- Script Execution State ---
    @Published var scriptLogOutput: [String] = []
    @Published var isScriptRunning: Bool = false
    @Published var requiresAdminPrivilege: Bool = false
    @Published var scriptErrorMessage: String? = nil
    @Published var isSetupComplete: Bool = false

    // Callback for completion
    var onComplete: (() -> Void)?

    // Keep track of the script execution Task to allow cancellation (optional)
    private var scriptTask: Task<Void, Never>? = nil
    // Services (consider dependency injection for better testability)
    private let scriptRunner = ScriptRunnerService()
    private let escalator = PrivilegeEscalationService()


    // MARK: - Flow Logic / Navigation
    // goToNextStep() and goToPreviousStep() remain unchanged from previous version
    func goToNextStep() {
        switch currentStep {
        case .welcome: currentStep = .selectCategory
        case .selectCategory:
            guard selectedCategory != nil else { return }
            currentStep = .selectMethod
        case .selectMethod:
            guard let category = selectedCategory, let method = selectedMethod else { return }
            switch (category, method) {
            case (.ollama, .guidedLocal): currentStep = .configureOllamaLocal
            case (.ollama, .existingApi): currentStep = .configureOllamaApi
            case (.agent, .guidedLocal): currentStep = .configureAgentLocal
            case (.agent, .existingApi): currentStep = .configureAgentApi
            }
        case .configureOllamaLocal, .configureOllamaApi, .configureAgentLocal, .configureAgentApi:
             logger.debug("Attempting next step from config - should be handled by Finish button calling completeOnboarding()")
        default: logger.warning("Unhandled 'Next' step transition logic from \(String(describing: self.currentStep))")
        }
    }

    func goToPreviousStep() {
        switch currentStep {
        case .selectCategory:
             currentStep = .welcome
             selectedCategory = nil
        case .selectMethod:
             currentStep = .selectCategory
             selectedMethod = nil
        case .configureOllamaLocal, .configureOllamaApi, .configureAgentLocal, .configureAgentApi:
             // If script is running, consider preventing 'Back' or cancelling
             if isScriptRunning {
                  logger.warning("Attempted to go back while script running. Cancelling script.")
                  cancelScriptExecution() // Call cancellation logic
             }
             currentStep = .selectMethod
             resetScriptState()
        default: logger.warning("Cannot go back from \(String(describing: self.currentStep))")
        }
    }


    // MARK: - Step 4a: Ollama Local Setup Script Logic

    /// Initiates the Ollama setup script via the ScriptRunnerService
    func startOllamaSetupScript() {
         guard !selectedModelNames.isEmpty else {
             scriptErrorMessage = "Please select at least one model to download."
             return
         }
         let modelsToPass = Array(selectedModelNames)
         logger.info("Starting Ollama setup script for models: \(modelsToPass.joined(separator: ", "))")

         // Reset state for a new run
         resetScriptState()
         isScriptRunning = true

        // Cancel any previous task before starting a new one
        scriptTask?.cancel()

        // Start the script execution in a background Task
        scriptTask = Task {
            do {
                let stream = scriptRunner.runOllamaSetupScript(models: modelsToPass)

                // Process events from the stream using async/await
                for try await event in stream.values {
                     // Check if the task has been cancelled between events
                     try Task.checkCancellation()
                     // Update state on the main actor
                     await handleScriptEvent(event)
                }
                // If the loop finishes without error, the script completed successfully
                // Ensure we're still on the main actor for the final state update
                await scriptDidCompleteSuccessfully()

            } catch is CancellationError {
                // Handle cancellation specifically if needed
                logger.info("Script execution task was cancelled.")
                await MainActor.run { // Ensure UI updates are on main actor
                     scriptDidFail(error: NSError(domain: "Onboarding", code: -999, userInfo: [NSLocalizedDescriptionKey: "Setup cancelled."]))
                 }
            } catch {
                // Handle errors from the publisher stream or the script runner itself
                logger.error("Script execution failed: \(error.localizedDescription)")
                 await MainActor.run { // Ensure UI updates are on main actor
                     scriptDidFail(error: error)
                 }
            }
        }
    }

    /// Helper function to handle events received from the ScriptRunnerService publisher
    @MainActor // Ensure UI updates are on main thread
    private func handleScriptEvent(_ event: ScriptOutputEvent) {
         switch event {
         case .log(let line):
             scriptDidOutput(logLine: line)
         case .requiresAdmin(let commandPath, let arguments):
             // Trigger the separate async task for privilege escalation
             handleAdminPrivilegeRequest(commandPath: commandPath, arguments: arguments)
         case .complete:
             // This signals the script process finished (exit 0)
             logger.debug("Received .complete event from script runner.")
             // Final success is marked when the publisher finishes without error
         }
     }


    /// Called asynchronously when the script runner signals the need for admin rights.
    /// This function runs the escalation and updates state, but doesn't block the main script stream.
    @MainActor
    func handleAdminPrivilegeRequest(commandPath: String, arguments: [String]) {
         logger.info("Handling admin privilege request for: \(commandPath)")
         guard !requiresAdminPrivilege else {
              logger.warning("Already awaiting admin privilege. Ignoring duplicate request.")
              return
         }
         requiresAdminPrivilege = true
         scriptDidOutput(logLine: "ℹ️ Admin privileges required...") // Log to user

        // Run the escalation in a separate Task
        Task {
            let success = await escalator.executeWithAdminPrivileges(commandPath: commandPath, arguments: arguments)

            // Update state on main thread after async call
            // No need for explicit MainActor.run here as the function is already @MainActor
            self.requiresAdminPrivilege = false // Hide prompt indicator
            if success {
                logger.info("Privileged command executed successfully.")
                // Let the script runner continue (it should detect the change or be re-run)
                self.scriptDidOutput(logLine: "✅ Admin task completed (script should continue)...")
            } else {
                logger.error("Privileged command failed or was cancelled.")
                // Treat cancellation/failure as a script error that stops the process
                self.scriptDidFail(error: NSError(domain: "PrivilegeEscalation", code: -1, userInfo: [NSLocalizedDescriptionKey: "Admin task failed or cancelled by user."]))
                // Cancel the main script task as it likely cannot continue
                self.cancelScriptExecution()
            }
        }
    }

    /// Cancels the script execution Task if it's running.
     func cancelScriptExecution() {
         logger.info("Attempting to cancel script execution task.")
         scriptTask?.cancel()
         scriptTask = nil
         // State update (e.g., setting error message) happens in the catch block of the Task
         // or you can set isScriptRunning = false here if cancellation should immediately stop showing progress
         // isScriptRunning = false // Consider if immediate UI feedback is needed on cancel
     }


    /// Appends a log line from the script to the output array
    @MainActor
    func scriptDidOutput(logLine: String) {
        scriptLogOutput.append(logLine)
        // Optional: Limit log lines to prevent excessive memory use
        if scriptLogOutput.count > 300 {
            scriptLogOutput.removeFirst(scriptLogOutput.count - 300)
        }
    }

    /// Sets state upon script failure
    @MainActor
    func scriptDidFail(error: Error) {
        // Don't overwrite if already cancelled with a specific message
        if !(error is CancellationError) && scriptErrorMessage == nil {
             scriptErrorMessage = "Error: \(error.localizedDescription)"
        } else if scriptErrorMessage == nil {
            scriptErrorMessage = "Setup cancelled."
        }
        scriptLogOutput.append("❌ Script failed: \(error.localizedDescription)")
        isScriptRunning = false
        isSetupComplete = false // Ensure setup is not marked complete on failure
        scriptTask = nil // Clear task reference
        logger.error("Script failed processing: \(error)")
    }

    /// Sets state upon script success (called when publisher finishes successfully)
    @MainActor
    func scriptDidCompleteSuccessfully() {
        guard scriptErrorMessage == nil else {
             logger.warning("Script publisher completed, but an error was previously recorded. Not marking as success.")
             isScriptRunning = false // Ensure running is false
             scriptTask = nil
             return
         }
        isScriptRunning = false
        isSetupComplete = true // Enable the "Finish" button
        scriptErrorMessage = nil
        scriptLogOutput.append("✅ Setup script completed successfully.")
        logger.info("Ollama local setup script marked as complete successfully.")
        scriptTask = nil // Clear task reference
    }

    /// Resets the state related to script execution
    @MainActor
    func resetScriptState() {
         scriptTask?.cancel() // Cancel any running task when resetting
         scriptTask = nil
         scriptLogOutput = []
         isScriptRunning = false
         requiresAdminPrivilege = false
         scriptErrorMessage = nil
         isSetupComplete = false
         // Do not reset selectedModelNames here
     }

    // MARK: - Onboarding Completion
    func completeOnboarding() {
         logger.info("Attempting to complete onboarding from step \(String(describing: self.currentStep))...")
         guard let finalCategory = selectedCategory else {
             logger.error("Cannot complete onboarding: category not selected.")
             return
         }

         // --- Final Validation before saving ---
         // Ensure completion is happening from a valid state, especially for script-based setup
         if currentStep == .configureOllamaLocal && !isSetupComplete {
             logger.error("Cannot complete onboarding: Ollama local setup script did not complete successfully.")
             // Optionally update UI error message:
             // scriptErrorMessage = "Setup did not complete successfully."
             return
         }
         // Add similar checks for other configuration steps if needed

         // 1. Save final selections to UserDefaults
         UserDefaults.standard.set(finalCategory.rawValue, forKey: SettingsKeys.selectedBackend)
         logger.debug("Saved selectedBackend: \(finalCategory.rawValue)")

         // Save settings based on the path taken and successful completion
         switch (finalCategory, selectedMethod) {
         case (.ollama, .guidedLocal):
             // Assumes completion check happened above
             let defaultModel = selectedModelNames.first ?? "llama3" // Fallback
             UserDefaults.standard.set(defaultModel, forKey: SettingsKeys.llmModelName)
             UserDefaults.standard.set("http://localhost:11434", forKey: SettingsKeys.agentBaseURL) // Ollama uses agentBaseURL key? Check SettingsKeys use. If separate key needed, add it. Let's assume it uses agentBaseURL for now.
             logger.info("Saved Ollama local setup config (default model: \(defaultModel), URL: http://localhost:11434)")

         case (.ollama, .existingApi):
              // TODO: Get URL/Model from Step 4b (.configureOllamaApi) view state
              logger.info("Saving Ollama API config (Logic TBD in Step 4b)")
         case (.agent, .guidedLocal):
              // TODO: Get URL/Model from Step 4c (.configureAgentLocal) view state
              logger.info("Saving Agent Local config (Logic TBD in Step 4c)")
         case (.agent, .existingApi):
              // TODO: Get URL/Strategy from Step 4d (.configureAgentApi) view state
              logger.info("Saving Agent API config (Logic TBD in Step 4d)")
         default:
             logger.error("Warning: Unexpected combination of category/method during completion.")
             return
         }

         // 2. Mark onboarding as complete
         UserDefaults.standard.set(true, forKey: SettingsKeys.isOnboardingComplete)
         logger.info("UserDefaults '\(SettingsKeys.isOnboardingComplete)' set to true.")

         // 3. Trigger the completion callback
         if let completeAction = onComplete {
              logger.info("Calling onComplete action to switch view.")
              completeAction()
         } else {
             logger.error("Error: onComplete action was not set in ViewModel.")
         }
     }

    // Deinitializer to cancel task if ViewModel is destroyed mid-run
     deinit {
         logger.debug("OnboardingViewModel deinit - cancelling script task if active.")
         scriptTask?.cancel()
     }
}

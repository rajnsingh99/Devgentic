// Onboarding/ViewModel/OnboardingViewModel.swift
import SwiftUI
import Combine
import os // Make sure os is imported

// Assume BackendType exists in Models/BackendType.swift
// Assume OllamaModelInfo exists in Models/OllamaModelInfo.swift

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.Devgentic", category: "OnboardingViewModel")

@MainActor
class OnboardingViewModel: ObservableObject {

    // MARK: - Enums for State Management
    /// Defines the different steps within the onboarding flow.
    enum OnboardingStep: Identifiable {
        case welcome
        case selectCategory
        case selectMethod
        case configureOllamaLocal // Guided local Ollama setup via script
        case configureOllamaApi   // Connect to existing Ollama API
        case configureAgentLocal  // Guided local Agent setup (TBD)
        case configureAgentApi    // Connect to existing Agent API
        case complete

        var id: OnboardingStep { self }
    }

    /// Represents the setup method chosen in Step 3.
    enum SetupMethod: Identifiable {
         case guidedLocal // User needs help setting up locally
         case existingApi // User has an existing API endpoint

         var id: SetupMethod { self }
    }


    // MARK: - Published Properties (State)

    /// The current step being displayed in the onboarding UI.
    @Published var currentStep: OnboardingStep = .welcome

    /// The backend category (Ollama or Agent) selected in Step 2.
    @Published var selectedCategory: BackendType? = nil

    /// The setup method (Guided Local or Existing API) selected in Step 3.
    @Published var selectedMethod: SetupMethod? = nil

    // --- State for Step 4a (Ollama Local Setup via Script) ---
    /// Hardcoded list of recommended Ollama models for selection.
    let recommendedOllamaModels: [OllamaModelInfo] = [
        OllamaModelInfo(name: "llama3", displayName: "Llama 3", sizeDescription: "8B Instruct"),
        OllamaModelInfo(name: "mistral", displayName: "Mistral", sizeDescription: "7B Instruct"),
        OllamaModelInfo(name: "codellama", displayName: "Code Llama", sizeDescription: "7B Code"),
        OllamaModelInfo(name: "phi3", displayName: "Phi-3 Mini", sizeDescription: "3.8B Instruct (Small)"),
    ]
    /// Set of selected Ollama model names to be installed by the script.
    @Published var selectedModelNames: Set<String> = ["llama3"] // Default selection

    // --- Script Execution State (for Step 4a) ---
    /// Log output received from the setup script.
    @Published var scriptLogOutput: [String] = []
    /// Flag indicating if the setup script is currently running.
    @Published var isScriptRunning: Bool = false
    /// Flag indicating if the script requires admin privilege elevation.
    @Published var requiresAdminPrivilege: Bool = false
    /// Stores any error message resulting from script execution or privilege escalation.
    @Published var scriptErrorMessage: String? = nil
    /// Flag indicating if the script-based setup completed successfully.
    @Published var isSetupComplete: Bool = false

    // --- State for Step 4b (Ollama API Setup) ---
    /// URL entered by the user for an existing Ollama API.
    @Published var ollamaApiUrl: String = "http://localhost:11434"
    /// Optional default model name for the Ollama API connection.
    @Published var ollamaApiModel: String = ""
    /// Status of the Ollama API connection test (nil: untested, true: success, false: fail).
    @Published var isApiConnectionOk: Bool? = nil
    /// Flag indicating if the Ollama API connection test is in progress.
    @Published var apiTestInProgress: Bool = false
    /// Stores any error message from the Ollama API connection test.
    @Published var apiTestError: String? = nil

    // --- State for Step 4d (Agent API Setup) ---
    /// URL entered by the user for an existing Agent API.
    @Published var agentApiUrl: String = ""
    /// Delegation strategy selected for the Agent API connection.
    @Published var agentDelegationStrategy: String = "auto" // Default, adjust as needed
    /// Status of the Agent API connection test.
    @Published var isAgentApiConnectionOk: Bool? = nil
    /// Flag indicating if the Agent API connection test is in progress.
    @Published var agentApiTestInProgress: Bool = false
    /// Stores any error message from the Agent API connection test.
    @Published var agentApiTestError: String? = nil


    /// Callback function provided by the hosting view to signal completion of the entire onboarding flow.
    var onComplete: (() -> Void)?

    // MARK: - Services & Helper Properties
    /// Reference to the background task running the setup script (for cancellation).
    private var scriptTask: Task<Void, Never>? = nil
    // Services (Consider using dependency injection for better testability)
    private let scriptRunner = ScriptRunnerService()
    private let escalator = PrivilegeEscalationService()
    // AIConnect is instantiated dynamically in test methods based on user input URL


    // MARK: - Flow Logic / Navigation

    /// Advances the onboarding flow to the next logical step based on current state and selections.
    func goToNextStep() {
        switch currentStep {
        case .welcome:
            currentStep = .selectCategory
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
             // Completion is handled by the "Finish" button in these views calling completeOnboarding()
             logger.debug("Attempting 'Next' from config step - completion handled by 'Finish' button.")
        default:
            // Corrected logger call
            logger.warning("Unhandled 'Next' step transition logic from \(String(describing: self.currentStep))")
        }
    }

    /// Moves the onboarding flow back to the previous logical step, resetting relevant state.
    func goToPreviousStep() {
        switch currentStep {
        case .selectCategory:
             currentStep = .welcome
             selectedCategory = nil // Clear selection when going back
        case .selectMethod:
             currentStep = .selectCategory
             selectedMethod = nil // Clear method selection
        case .configureOllamaLocal, .configureOllamaApi, .configureAgentLocal, .configureAgentApi:
             // If script is running for Ollama Local setup, cancel it
             if currentStep == .configureOllamaLocal && isScriptRunning {
                  logger.warning("Attempted to go back while script running. Cancelling script.")
                  cancelScriptExecution()
             }
             // Go back to method selection from any config step
             currentStep = .selectMethod
             // Reset state specific to the configuration step we are leaving
             resetScriptState()
             resetOllamaApiTestState()
             resetAgentApiTestState()
        default:
            // Corrected logger call
            logger.warning("Cannot go back from \(String(describing: self.currentStep))")
        }
    }


    // MARK: - Step 4a: Ollama Local Setup Script Logic

    /// Initiates the Ollama setup script via the ScriptRunnerService.
    func startOllamaSetupScript() {
         guard !selectedModelNames.isEmpty else {
             scriptErrorMessage = "Please select at least one model to download."
             return
         }
         let modelsToPass = Array(selectedModelNames)
         logger.info("Starting Ollama setup script for models: \(modelsToPass.joined(separator: ", "))")
         resetScriptState() // Reset state before starting
         isScriptRunning = true
         scriptTask?.cancel() // Cancel previous task if any

         scriptTask = Task { // Run in background task
            do {
                let stream = scriptRunner.runOllamaSetupScript(models: modelsToPass)
                for try await event in stream.values {
                     try Task.checkCancellation() // Allow cancellation
                     await handleScriptEvent(event) // Process event on main actor
                }
                // Stream finished without error -> success
                await scriptDidCompleteSuccessfully()
            } catch is CancellationError {
                logger.info("Script execution task was cancelled.")
                await scriptDidFail(error: NSError(domain: "Onboarding", code: -999, userInfo: [NSLocalizedDescriptionKey: "Setup cancelled."]))
            } catch {
                logger.error("Script execution failed: \(error.localizedDescription)")
                await scriptDidFail(error: error) // Handle other errors
            }
        }
    }

    /// Helper to process events from the ScriptRunnerService stream on the main actor.
    @MainActor
    private func handleScriptEvent(_ event: ScriptOutputEvent) {
         switch event {
         case .log(let line):
             scriptDidOutput(logLine: line)
         case .requiresAdmin(let commandPath, let arguments):
             handleAdminPrivilegeRequest(commandPath: commandPath, arguments: arguments) // This is already @MainActor
         case .complete:
             logger.debug("Received .complete event from script runner (process finished OK).")
             // Final success is handled when the publisher stream finishes without error.
         }
     }

    /// Handles the request for admin privileges signaled by the script.
    @MainActor
    func handleAdminPrivilegeRequest(commandPath: String, arguments: [String]) {
         logger.info("Handling admin privilege request for: \(commandPath)")
         guard !requiresAdminPrivilege else { return } // Prevent duplicates
         requiresAdminPrivilege = true
         scriptDidOutput(logLine: "ℹ️ Admin privileges required...")

         Task { // Run escalation in separate task
             let success = await escalator.executeWithAdminPrivileges(commandPath: commandPath, arguments: arguments)
             // No need for explicit MainActor.run as func is @MainActor
             self.requiresAdminPrivilege = false // Hide indicator
             if success {
                 logger.info("Privileged command executed successfully.")
                 self.scriptDidOutput(logLine: "✅ Admin task completed (script should continue)...")
             } else {
                 logger.error("Privileged command failed or was cancelled.")
                 self.scriptDidFail(error: NSError(domain: "PrivilegeEscalation", code: -1, userInfo: [NSLocalizedDescriptionKey: "Admin task failed or cancelled by user."]))
                 self.cancelScriptExecution() // Stop script if admin fails
             }
         }
    }

    /// Cancels the running script execution task.
    func cancelScriptExecution() {
         logger.info("Attempting to cancel script execution task.")
         scriptTask?.cancel()
         scriptTask = nil
         // Error/status update happens in the Task's catch block
     }

    /// Appends a log line from the script to the output array.
    @MainActor
    func scriptDidOutput(logLine: String) {
        scriptLogOutput.append(logLine)
        if scriptLogOutput.count > 300 { // Limit log history
            scriptLogOutput.removeFirst(scriptLogOutput.count - 300)
        }
    }

    /// Sets state upon script failure.
    @MainActor
    func scriptDidFail(error: Error) {
        if !(error is CancellationError) && scriptErrorMessage == nil {
             scriptErrorMessage = "Error: \(error.localizedDescription)"
        } else if scriptErrorMessage == nil {
            scriptErrorMessage = "Setup cancelled."
        }
        scriptLogOutput.append("❌ Script failed: \(error.localizedDescription)")
        isScriptRunning = false
        isSetupComplete = false
        scriptTask = nil
        logger.error("Script failed processing: \(error)")
    }

    /// Sets state upon script success.
    @MainActor
    func scriptDidCompleteSuccessfully() {
        guard scriptErrorMessage == nil else { // Don't mark success if an error occurred previously
             logger.warning("Script publisher completed, but an error was recorded. Not marking as success.")
             isScriptRunning = false
             scriptTask = nil
             return
         }
        isScriptRunning = false
        isSetupComplete = true // Enable Finish button
        scriptErrorMessage = nil
        scriptLogOutput.append("✅ Setup script completed successfully.")
        logger.info("Ollama local setup script marked as complete successfully.")
        scriptTask = nil
    }

    /// Resets the state related to script execution.
    @MainActor
    func resetScriptState() {
         cancelScriptExecution() // Cancel task before resetting state
         scriptLogOutput = []
         isScriptRunning = false
         requiresAdminPrivilege = false
         scriptErrorMessage = nil
         isSetupComplete = false
     }


    // MARK: - Step 4b: Ollama API Connection Test Logic

    /// Initiates a connection test to the entered Ollama API URL.
    func testOllamaApiConnection() {
        logger.info("Testing Ollama API connection to URL: \(self.ollamaApiUrl)")
        guard let url = URL(string: ollamaApiUrl), let host = url.host, !host.isEmpty else {
            // Handle invalid URL locally without async task
            logger.error("Invalid Ollama API URL format: \(self.ollamaApiUrl)")
            isApiConnectionOk = false
            apiTestError = "Invalid URL format."
            apiTestInProgress = false
            return
        }
        resetOllamaApiTestState() // Reset before starting
        apiTestInProgress = true

        Task {
            do {
                let connector = AIConnect(baseURL: self.ollamaApiUrl)
                // Hit base endpoint, expect 200 OK for success
                let _ = try await connector.fetchFromLocalServer(endpoint: "/")
                logger.info("Ollama API connection test successful to \(self.ollamaApiUrl)")
                // Update state on main actor (already on it due to class annotation)
                apiTestInProgress = false
                isApiConnectionOk = true
                apiTestError = nil
            } catch {
                logger.error("Ollama API connection test failed: \(error.localizedDescription)")
                // Update state on main actor
                apiTestInProgress = false
                isApiConnectionOk = false
                apiTestError = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    /// Resets the state related to Ollama API connection testing.
    @MainActor
    func resetOllamaApiTestState() {
         apiTestInProgress = false
         isApiConnectionOk = nil
         apiTestError = nil
     }


    // MARK: - Step 4d: Agent API Connection Test Logic

    /// Initiates a connection test to the entered Agent API URL.
    func testAgentApiConnection() {
        logger.info("Testing Agent API connection to URL: \(self.agentApiUrl)")
        guard let url = URL(string: agentApiUrl), let host = url.host, !host.isEmpty else {
            logger.error("Invalid Agent API URL format: \(self.agentApiUrl)")
            isAgentApiConnectionOk = false
            agentApiTestError = "Invalid URL format."
            agentApiTestInProgress = false
            return
        }
        resetAgentApiTestState() // Reset before starting
        agentApiTestInProgress = true

        Task {
            do {
                let connector = AIConnect(baseURL: self.agentApiUrl)
                // Hit Agent base endpoint or /health, expect 200 OK
                let _ = try await connector.fetchFromLocalServer(endpoint: "/") // Adjust if needed
                logger.info("Agent API connection test successful to \(self.agentApiUrl)")
                // Update state on main actor
                agentApiTestInProgress = false
                isAgentApiConnectionOk = true
                agentApiTestError = nil
            } catch {
                logger.error("Agent API connection test failed: \(error.localizedDescription)")
                 // Update state on main actor
                agentApiTestInProgress = false
                isAgentApiConnectionOk = false
                agentApiTestError = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    /// Resets the state related to Agent API connection testing.
    @MainActor
    func resetAgentApiTestState() {
         agentApiTestInProgress = false
         isAgentApiConnectionOk = nil
         agentApiTestError = nil
     }


    // MARK: - Onboarding Completion

    /// Finalizes onboarding, validates the current state, saves settings, and calls the completion handler.
    func completeOnboarding() {
         // Corrected logger call
         logger.info("Attempting to complete onboarding from step \(String(describing: self.currentStep))...")
         guard let finalCategory = selectedCategory else {
             logger.error("Cannot complete onboarding: category not selected.")
             return
         }

         // --- Final Validation ---
         switch currentStep {
         case .configureOllamaLocal:
             if !isSetupComplete {
                  logger.error("Cannot complete onboarding: Ollama local setup did not complete successfully.")
                  scriptErrorMessage = "Setup did not complete successfully." // Show feedback
                  return
             }
         case .configureOllamaApi:
             if isApiConnectionOk != true {
                 logger.error("Cannot complete onboarding: Ollama API connection test was not successful.")
                 apiTestError = "Connection test must succeed before finishing." // Show feedback
                 return
             }
         case .configureAgentLocal:
              // TODO: Add validation for Step 4c if needed (e.g., local connection test?)
              logger.warning("Completion validation for Agent Local setup (Step 4c) is not implemented.")
              break // Allow completion for now
         case .configureAgentApi:
             if isAgentApiConnectionOk != true {
                 logger.error("Cannot complete onboarding: Agent API connection test was not successful.")
                 agentApiTestError = "Connection test must succeed before finishing." // Show feedback
                 return
             }
         default:
             // This shouldn't normally be reached if Finish button is only enabled in config steps
             logger.error("Cannot complete onboarding: Unexpected current step \(String(describing: self.currentStep))")
             return
         }

         // 1. Save final selections to UserDefaults
         UserDefaults.standard.set(finalCategory.rawValue, forKey: SettingsKeys.selectedBackend)
         logger.debug("Saved selectedBackend: \(finalCategory.rawValue)")

         // Save settings based on the completed path
         switch (finalCategory, selectedMethod) {
         case (.ollama, .guidedLocal):
              let defaultModel = selectedModelNames.first ?? "llama3"
              UserDefaults.standard.set(defaultModel, forKey: SettingsKeys.llmModelName)
              UserDefaults.standard.set("http://localhost:11434", forKey: SettingsKeys.agentBaseURL) // Assume agentBaseURL used for Ollama
              logger.info("Saved Ollama local setup config (model: \(defaultModel), URL: http://localhost:11434)")
         case (.ollama, .existingApi):
              let urlToSave = ollamaApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
              let modelToSave = ollamaApiModel.trimmingCharacters(in: .whitespacesAndNewlines)
              UserDefaults.standard.set(urlToSave, forKey: SettingsKeys.agentBaseURL) // Assume agentBaseURL used for Ollama
              UserDefaults.standard.set(modelToSave.isEmpty ? "llama3" : modelToSave, forKey: SettingsKeys.llmModelName)
              logger.info("Saved Ollama API config (URL: \(urlToSave), Model: \(modelToSave.isEmpty ? "(default)" : modelToSave))")
         case (.agent, .guidedLocal):
              // TODO: Save URL/Model from Step 4c (.configureAgentLocal) view state
              logger.info("Saving Agent Local config (Logic TBD in Step 4c)")
         case (.agent, .existingApi):
              let urlToSave = agentApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
              let strategyToSave = agentDelegationStrategy
              UserDefaults.standard.set(urlToSave, forKey: SettingsKeys.agentBaseURL)
              UserDefaults.standard.set(strategyToSave, forKey: SettingsKeys.agentDelegationStrategy)
              UserDefaults.standard.removeObject(forKey: SettingsKeys.llmModelName) // Clear Ollama-specific setting
              logger.info("Saved Agent API config (URL: \(urlToSave), Strategy: \(strategyToSave))")
         default:
             logger.error("Warning: Unexpected combination of category/method during completion saving.")
             return // Don't complete if state is inconsistent
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

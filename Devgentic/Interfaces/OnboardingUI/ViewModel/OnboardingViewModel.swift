// Onboarding/ViewModel/OnboardingViewModel.swift
import SwiftUI
import Combine
import os

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
    /// Stores the *name* of the selected recommended model, or nil if "Other..." is chosen. Default to "llama3".
    @Published var selectedRecommendedModelName: String? = "llama3"
    /// Stores the custom model name entered by the user when "Other..." is selected.
    @Published var customModelName: String = ""

    // --- Script Execution State (Common for both phases) ---
    /// Log output received from the setup script.
    @Published var scriptLogOutput: [String] = []
    /// Flag indicating if the overall setup script process (initial or post-install) is active.
    @Published var isScriptRunning: Bool = false
    /// Flag indicating if the script requires admin privilege elevation (prompt should be shown).
    @Published var requiresAdminPrivilege: Bool = false
    /// Stores any error message resulting from script execution or privilege escalation.
    @Published var scriptErrorMessage: String? = nil
    /// Flag indicating if the *entire* script-based setup (both phases) completed successfully.
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
    /// Reference to the background task running the current script phase (for cancellation).
    private var scriptTask: Task<Void, Never>? = nil
    /// Tracks the currently running script phase ("initial", "post-install").
    private var scriptPhase: String = ""
    /// Stores the final validated model name to be passed to the script phases.
    private var llmNameToInstall: String = ""
    // Services (Consider using dependency injection for better testability)
    private let scriptRunner = ScriptRunnerService()
    private let escalator = PrivilegeEscalationService()
    // AIConnect is instantiated dynamically in test methods based on user input URL


    // MARK: - Flow Logic / Navigation

    /// Advances the onboarding flow to the next logical step, applying animation.
    func goToNextStep() {
        // Determine the next step first
        var nextStep: OnboardingStep? = nil
        switch currentStep {
        case .welcome:
            nextStep = .selectCategory
        case .selectCategory:
            guard selectedCategory != nil else { return }
            nextStep = .selectMethod
        case .selectMethod:
            guard let category = selectedCategory, let method = selectedMethod else { return }
            switch (category, method) {
            case (.ollama, .guidedLocal): nextStep = .configureOllamaLocal
            case (.ollama, .existingApi): nextStep = .configureOllamaApi
            case (.agent, .guidedLocal): nextStep = .configureAgentLocal
            case (.agent, .existingApi): nextStep = .configureAgentApi
            }
        case .configureOllamaLocal, .configureOllamaApi, .configureAgentLocal, .configureAgentApi:
             logger.debug("Attempting 'Next' from config step - completion handled by 'Finish' button.")
        default:
            // Corrected logger call
            logger.warning("Unhandled 'Next' step transition logic from \(String(describing: self.currentStep))")
        }

        // --- Apply state change *with* animation (Animation Fix) ---
        if let determinedNextStep = nextStep, determinedNextStep != currentStep {
            withAnimation(.easeInOut(duration: 0.3)) { // Apply animation wrapper
                currentStep = determinedNextStep // Update the state inside the animation block
            }
        }
    }

    /// Moves the onboarding flow back to the previous logical step, applying animation and resetting state.
    func goToPreviousStep() {
        // Determine the previous step first
        var previousStep: OnboardingStep? = nil
        switch currentStep {
        case .selectCategory:
             previousStep = .welcome
        case .selectMethod:
             previousStep = .selectCategory
        case .configureOllamaLocal, .configureOllamaApi, .configureAgentLocal, .configureAgentApi:
             // If script is running for Ollama Local setup, cancel it before navigating
             if currentStep == .configureOllamaLocal && isScriptRunning {
                  logger.warning("Attempted to go back while script running. Cancelling script.")
                  cancelScriptExecution() // Important to cancel before state reset/navigation
             }
             previousStep = .selectMethod
        default:
            // Corrected logger call
            logger.warning("Cannot go back from \(String(describing: self.currentStep))")
        }

        // --- Apply state change *with* animation (Animation Fix) ---
        if let determinedPreviousStep = previousStep, determinedPreviousStep != currentStep {
             // Reset state specific to the step *before* animating away from it
             if currentStep == .selectCategory { selectedCategory = nil }
             if currentStep == .selectMethod { selectedMethod = nil }
             // Reset all config states when going back to method selection
             if currentStep == .configureOllamaLocal || currentStep == .configureOllamaApi || currentStep == .configureAgentLocal || currentStep == .configureAgentApi {
                 resetScriptState()
                 resetOllamaApiTestState()
                 resetAgentApiTestState()
             }

            withAnimation(.easeInOut(duration: 0.3)) { // Apply animation wrapper
                currentStep = determinedPreviousStep // Update the state inside the animation block
            }
        } else {
            // Handle cases where state might need reset even if step doesn't change
             if currentStep == .selectCategory { selectedCategory = nil }
             if currentStep == .selectMethod { selectedMethod = nil }
        }
    }


    // MARK: - Step 4a: Ollama Local Setup Script Logic (Two-Phase Orchestration)
    // (This section is identical to the user-provided file, including debug logs)
    /// Initiates the *initial phase* of the Ollama setup script.
    func startOllamaSetupScript() {
        // --- Determine the single LLM name to install ---
        if let recommendedName = selectedRecommendedModelName {
            llmNameToInstall = recommendedName
        } else {
            // "Other..." selected, use the custom name field
            let customName = customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            // Validate custom name is not empty
            guard !customName.isEmpty else {
                scriptErrorMessage = "Please enter a custom model name."
                logger.warning("Start script failed: Custom model name is empty.")
                return
            }
            llmNameToInstall = customName
        }
        // --- End LLM Name Determination ---

        // Script description implies single LLM name argument
        let modelArg = llmNameToInstall.isEmpty ? [] : [llmNameToInstall]

        logger.info("Starting Ollama setup script phase 'initial' for model: '\(self.llmNameToInstall)'")
        resetScriptState() // Reset state before starting
        runScriptPhase(phase: "initial", models: modelArg)
    }

    /// Initiates the *post-install phase* of the Ollama setup script.
    private func startPostInstallPhase() {
        logger.info("Starting Ollama setup script phase 'post-install' for model: '\(self.llmNameToInstall)'")
        // Keep logs, clear errors, reset completion flags for the new phase
        scriptErrorMessage = nil
        isSetupComplete = false // Not complete until post-install finishes
        requiresAdminPrivilege = false // Ensure admin prompt is hidden

        let modelArg = llmNameToInstall.isEmpty ? [] : [llmNameToInstall]
        // isScriptRunning should be set by runScriptPhase
        runScriptPhase(phase: "post-install", models: modelArg)
    }

    /// Common function to run a specific phase of the script.
    private func runScriptPhase(phase: String, models: [String]) {
        self.scriptPhase = phase // Track current phase
        isScriptRunning = true // Indicate overall process is active
        scriptTask?.cancel() // Cancel any previous Task from another phase/run

        logger.debug("DEBUG: Starting Task for phase '\(phase)'")
        scriptTask = Task {
            do {
                logger.debug("DEBUG: Calling scriptRunner.runOllamaSetupScript for phase '\(phase)'")
                let stream = scriptRunner.runOllamaSetupScript(models: models, phase: phase)
                for try await event in stream.values {
                     try Task.checkCancellation() // Allow task cancellation
                     await handleScriptEvent(event, phase: phase) // Process event on main actor
                }
                // Stream finished without error -> this PHASE completed successfully
                logger.debug("DEBUG: Script stream finished successfully for phase '\(phase)'. Calling scriptPhaseDidComplete.")
                await scriptPhaseDidComplete(phase: phase)
            } catch is CancellationError {
                logger.info("Script execution task phase '\(phase)' was cancelled.")
                // Update state to reflect cancellation
                await scriptDidFail(error: NSError(domain: "Onboarding", code: -999, userInfo: [NSLocalizedDescriptionKey: "Setup cancelled."]))
            } catch {
                logger.error("Script execution phase '\(phase)' failed: \(error.localizedDescription)")
                await scriptDidFail(error: error) // Handle other errors
            }
        }
    }


    /// Helper to process events received from the ScriptRunnerService stream on the main actor.
    @MainActor
    private func handleScriptEvent(_ event: ScriptOutputEvent, phase: String) {
         // logger.debug("DEBUG: Handling script event: \(String(describing: event)) for phase '\(phase)'") // Optional verbose log
         switch event {
         case .log(let line):
             scriptDidOutput(logLine: line)

         case .alreadyInstalled:
             logger.info("Script signaled Ollama already installed during phase '\(phase)'.")
             scriptDidOutput(logLine: "✅ Ollama already installed.")
             if phase == "initial" {
                 // If detected during initial phase, skip admin and go directly to post-install
                 cancelScriptExecution() // Stop listening to initial phase process
                 startPostInstallPhase() // Start the next phase
             } // Ignore if received during post-install

         case .requiresAdmin(let commandJson):
             logger.info("Script signaled requires admin during phase '\(phase)'.")
             if phase == "initial" {
                 // Only handle admin request from initial phase
                 cancelScriptExecution() // Stop listening to initial phase process
                 parseAndHandleAdminRequest(jsonString: commandJson) // Parse JSON and trigger escalation
             } else {
                  logger.warning("Received unexpected admin request during phase '\(phase)'. Ignoring.")
             }

         case .phaseComplete:
             // This event signals the process exited 0, but final logic is in scriptPhaseDidComplete
             logger.info("Received phase complete signal for '\(phase)'.")
         }
     }

    /// Parses the JSON command info and triggers the admin privilege request.
    @MainActor
    private func parseAndHandleAdminRequest(jsonString: String) {
         scriptDidOutput(logLine: "ℹ️ Parsing admin command...")
         do {
             guard let jsonData = jsonString.data(using: .utf8) else {
                 throw ScriptRunnerService.ScriptError.jsonParsingFailed(NSError(domain: "Onboarding", code: 1, userInfo: [NSLocalizedDescriptionKey:"Invalid JSON string encoding"]))
             }
             // Use the AdminCommandInfo struct defined in ScriptRunnerService extension
             let commandInfo = try JSONDecoder().decode(ScriptRunnerService.AdminCommandInfo.self, from: jsonData)
             logger.info("Successfully parsed admin command: \(commandInfo.command)")
             // Now call the function that actually runs the command
             handleAdminPrivilegeRequest(commandPath: commandInfo.command, arguments: commandInfo.args ?? [])
         } catch {
             logger.error("Failed to parse admin command JSON: \(error.localizedDescription)")
             // Mark overall script as failed if JSON parsing fails
             scriptDidFail(error: ScriptRunnerService.ScriptError.jsonParsingFailed(error))
         }
    }

    /// Handles the request for admin privileges after JSON parsing. Runs the command via EscalationService.
    @MainActor
    func handleAdminPrivilegeRequest(commandPath: String, arguments: [String]) {
         logger.info("Handling admin privilege request for: \(commandPath)")
         guard !requiresAdminPrivilege else {
             logger.warning("Already awaiting admin privilege. Ignoring duplicate request.")
             return
         }
         requiresAdminPrivilege = true // Show prompt indicator in UI

         Task { // Run escalation in separate task
             let success = await escalator.executeWithAdminPrivileges(commandPath: commandPath, arguments: arguments)

             // Update state on main thread after async call
             self.requiresAdminPrivilege = false // Hide indicator
             if success {
                 logger.info("Privileged command executed successfully.")
                 self.scriptDidOutput(logLine: "✅ Admin task completed.")
                 // Crucially, now start the post-install phase
                 startPostInstallPhase()
             } else {
                 logger.error("Privileged command failed or was cancelled.")
                 // Treat cancellation/failure as a script error that stops the process
                 self.scriptDidFail(error: NSError(domain: "PrivilegeEscalation", code: -1, userInfo: [NSLocalizedDescriptionKey: "Admin task failed or cancelled by user."]))
                 // Do not proceed to post-install phase
             }
         }
    }

    /// Cancels the *current* script execution task.
    func cancelScriptExecution() {
         logger.info("Attempting to cancel script execution task (phase: \(self.scriptPhase)).")
         scriptTask?.cancel()
         scriptTask = nil
     }

    /// Appends a log line from the script to the output array.
    @MainActor
    func scriptDidOutput(logLine: String) {
        scriptLogOutput.append(logLine)
        if scriptLogOutput.count > 300 { // Limit log history
            scriptLogOutput.removeFirst(scriptLogOutput.count - 300)
        }
    }

    /// Sets state upon script failure for *any* phase.
    @MainActor
    func scriptDidFail(error: Error) {
        let phaseInfo = scriptPhase.isEmpty ? "" : " phase '\(scriptPhase)'"
        logger.error("DEBUG: Entering scriptDidFail for\(phaseInfo). Error: \(error.localizedDescription)") // DEBUG LOG
        // Use specific error message if available, otherwise generic failure/cancel message
        if !(error is CancellationError) && scriptErrorMessage == nil {
             scriptErrorMessage = "Error: \(error.localizedDescription)"
        } else if scriptErrorMessage == nil {
            scriptErrorMessage = "Setup cancelled."
        }
        scriptLogOutput.append("❌ Script\(phaseInfo) failed: \(error.localizedDescription)")
        isScriptRunning = false // Stop overall running indicator
        isSetupComplete = false // Ensure setup is not marked complete on failure
        scriptTask = nil // Clear task reference
        logger.error("Script\(phaseInfo) failed processing: \(error)")
    }

    /// Called when a script *phase* publisher completes without error. Determines next step.
    @MainActor
    func scriptPhaseDidComplete(phase: String) {
        logger.debug("DEBUG: Entering scriptPhaseDidComplete for phase '\(phase)'. Current isSetupComplete=\(self.isSetupComplete)") // DEBUG LOG
        if phase == "post-install" {
            // Post-install phase finished successfully, mark overall setup complete
            logger.debug("DEBUG: Post-install phase complete. Setting isSetupComplete = true.") // DEBUG LOG
            isScriptRunning = false // Stop overall running indicator
            isSetupComplete = true // Enable the "Finish" button
            scriptErrorMessage = nil
            scriptLogOutput.append("✅ Ollama setup and verification complete.")
            logger.info("Ollama local setup process fully completed successfully.")
            scriptTask = nil
            logger.debug("DEBUG: Exiting scriptPhaseDidComplete for post-install. isSetupComplete=\(self.isSetupComplete)") // DEBUG LOG
        } else if phase == "initial" {
             // Initial phase completed successfully.
             // If requiresAdmin or alreadyInstalled was signaled, the next phase was already started by handleScriptEvent.
             // If neither was signaled, it means Ollama was installed, but post-install (verification/pull)
             // might still be needed according to the workflow description. Start post-install now.
             logger.info("Initial phase completed successfully without needing admin. Starting post-install phase.")
             startPostInstallPhase() // Proceed to verification/pull phase
        }
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
         scriptPhase = ""
         // Keep llmNameToInstall unless explicitly cleared
     }


    // MARK: - Step 4b: Ollama API Connection Test Logic
    /// Initiates a connection test to the entered Ollama API URL.
    func testOllamaApiConnection() {
        logger.info("DEBUG: testOllamaApiConnection() called.")

        let urlString = ollamaApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = ollamaApiModel.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !urlString.isEmpty else {
            logger.warning("DEBUG: Ollama API URL is empty. Test aborted.")
            isApiConnectionOk = false; apiTestError = "URL cannot be empty."; apiTestInProgress = false; return
        }
        logger.info("Testing Ollama API connection to URL: \(urlString)")
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else {
            logger.error("DEBUG: Invalid Ollama API URL format: \(urlString)")
            isApiConnectionOk = false; apiTestError = "Invalid URL format."; apiTestInProgress = false; return
        }

        resetOllamaApiTestState(); apiTestInProgress = true
        logger.debug("DEBUG: apiTestInProgress set to true.")

        Task {
            do {
                // 1. --- Test Base Connection ---
                let connector = AIConnect(baseURL: urlString)
                logger.debug("DEBUG: Calling connector.fetchFromLocalServer(endpoint: \"/\") for base connection test.")
                let _ = try await connector.fetchFromLocalServer(endpoint: "/")
                logger.info("DEBUG: Base connection to \(urlString) successful.")

                // 2. --- Test Model Existence (if model name provided) ---
                if !modelName.isEmpty {
                    logger.debug("DEBUG: Model name '\(modelName)' provided. Checking existence.")
                    // Use the static method directly
                    let modelExists = try await AIConnect.checkOllamaModelExists(baseURL: urlString, modelName: modelName)

                    if modelExists {
                        logger.info("DEBUG: Model '\(modelName)' exists on server.")
                        // Both connection and model check passed
                        apiTestInProgress = false
                        isApiConnectionOk = true
                        apiTestError = nil
                        logger.debug("DEBUG: State updated for successful connection and model check.")
                    } else {
                        // Connection ok, but model not found
                        logger.warning("DEBUG: Model '\(modelName)' not found on server.")
                        apiTestInProgress = false
                        isApiConnectionOk = false // Mark as failed because model is missing
                        apiTestError = "Model '\(modelName)' not found on server."
                        logger.debug("DEBUG: State updated for failed model check.")
                    }
                } else {
                    // No model name provided, base connection was successful
                    logger.info("DEBUG: No model name provided. Base connection successful.")
                    apiTestInProgress = false
                    isApiConnectionOk = true // Mark as success
                    apiTestError = nil
                    logger.debug("DEBUG: State updated for successful base connection (no model check).")
                }

            } catch let modelCheckError as URLError where modelCheckError.userInfo["HTTPStatusCode"] as? Int == 404 {
                 // This specific catch block might not be strictly necessary anymore
                 // if checkOllamaModelExists handles 404 internally, but kept for robustness.
                 // It means the base connection likely worked, but the /api/show call failed with 404.
                 logger.warning("DEBUG: Model '\(modelName)' not found (caught 404 during check).")
                 apiTestInProgress = false
                 isApiConnectionOk = false
                 apiTestError = "Model '\(modelName)' not found on server."
                 logger.debug("DEBUG: State updated for failed model check (404).")

            } catch {
                // Catch errors from base connection OR model check (other than 404 handled above/internally)
                logger.error("DEBUG: Ollama API connection test failed: \(error.localizedDescription)")
                apiTestInProgress = false
                isApiConnectionOk = false
                apiTestError = "Connection failed: \(error.localizedDescription)"
                logger.debug("DEBUG: State updated for failed test (general error).")
            }
        }
    }

    /// Resets the state related to Ollama API connection testing.
    @MainActor
    func resetOllamaApiTestState() {
         logger.debug("DEBUG: resetOllamaApiTestState() called.") // DEBUG LOG
         apiTestInProgress = false
         isApiConnectionOk = nil
         apiTestError = nil
     }


    // MARK: - Step 4d: Agent API Connection Test Logic
    /// Initiates a connection test to the entered Agent API URL.
    func testAgentApiConnection() {
        logger.info("Testing Agent API connection to URL: \(self.agentApiUrl)")
        let urlString = agentApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else {
            logger.error("Invalid Agent API URL format: \(urlString)")
            isAgentApiConnectionOk = false; agentApiTestError = "Invalid URL format."; agentApiTestInProgress = false; return
        }
        resetAgentApiTestState(); agentApiTestInProgress = true

        Task {
            do {
                let connector = AIConnect(baseURL: urlString)
                let _ = try await connector.fetchFromLocalServer(endpoint: "/") // Adjust endpoint if needed
                logger.info("Agent API connection test successful to \(urlString)")
                agentApiTestInProgress = false; isAgentApiConnectionOk = true; agentApiTestError = nil
            } catch {
                logger.error("Agent API connection test failed: \(error.localizedDescription)")
                agentApiTestInProgress = false; isAgentApiConnectionOk = false
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
         logger.info("Attempting to complete onboarding from step \(String(describing: self.currentStep))...")
         guard let finalCategory = selectedCategory else {
             logger.error("Cannot complete onboarding: category not selected.")
             return
         }

         // --- Final Validation ---
         switch currentStep {
         case .configureOllamaLocal:
             logger.debug("DEBUG: Validating completeOnboarding for configureOllamaLocal. isSetupComplete=\(self.isSetupComplete)") // DEBUG LOG
             if !isSetupComplete {
                  logger.error("Cannot complete onboarding: Ollama local setup did not complete successfully.")
                  scriptErrorMessage = "Setup did not complete successfully."
                  return
             }
         case .configureOllamaApi:
             if isApiConnectionOk != true {
                 logger.error("Cannot complete onboarding: Ollama API connection test was not successful.")
                 apiTestError = "Connection test must succeed before finishing."
                 return
             }
         case .configureAgentLocal:
              logger.warning("Completion validation for Agent Local setup (Step 4c) is not implemented.")
              break // Allow completion for now
         case .configureAgentApi:
             if isAgentApiConnectionOk != true {
                 logger.error("Cannot complete onboarding: Agent API connection test was not successful.")
                 agentApiTestError = "Connection test must succeed before finishing."
                 return
             }
         default:
             logger.error("Cannot complete onboarding: Unexpected current step \(String(describing: self.currentStep))")
             return
         }

         // 1. Save final selections to UserDefaults
         UserDefaults.standard.set(finalCategory.rawValue, forKey: SettingsKeys.selectedBackend)
         logger.debug("Saved selectedBackend: \(finalCategory.rawValue)")

         // Save settings based on the completed path
         switch (finalCategory, selectedMethod) {
         case (.ollama, .guidedLocal):
              // Use the stored llmNameToInstall determined during startOllamaSetupScript
              let modelToSave = llmNameToInstall.isEmpty ? "llama3" : llmNameToInstall // Use stored name or fallback
              UserDefaults.standard.set(modelToSave, forKey: SettingsKeys.llmModelName)
              UserDefaults.standard.set("http://localhost:11434", forKey: SettingsKeys.agentBaseURL) // Assume agentBaseURL used for Ollama
              logger.info("Saved Ollama local setup config (model: \(modelToSave), URL: http://localhost:11434)")
         case (.ollama, .existingApi):
              let urlToSave = ollamaApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
              let modelToSave = ollamaApiModel.trimmingCharacters(in: .whitespacesAndNewlines)
              UserDefaults.standard.set(urlToSave, forKey: SettingsKeys.agentBaseURL) // Assume agentBaseURL used for Ollama
              UserDefaults.standard.set(modelToSave.isEmpty ? "llama3" : modelToSave, forKey: SettingsKeys.llmModelName)
              logger.info("Saved Ollama API config (URL: \(urlToSave), Model: \(modelToSave.isEmpty ? "(default)" : modelToSave))")
         case (.agent, .guidedLocal):
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

    // Deinitializer
     deinit {
         logger.debug("OnboardingViewModel deinit - cancelling script task if active.")
         scriptTask?.cancel()
     }
}

// Add required extension for ScriptRunnerService.AdminCommandInfo decoding
// (Make sure ScriptRunnerService.swift also defines this struct)
extension ScriptRunnerService {
     struct AdminCommandInfo: Decodable, Equatable {
         let command: String
         let args: [String]?
     }
}

// Assume BackendType enum exists in Models/BackendType.swift
// enum BackendType: String, Codable, CaseIterable { ... }
// Assume OllamaModelInfo struct exists in Models/OllamaModelInfo.swift
// struct OllamaModelInfo: Identifiable, Hashable { ... }



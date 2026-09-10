// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//// AgentOnboardingViewModel.swift
////
////  AgentOnboardingViewModel.swift
////  Devgentic
////
////  Created by Raj Singh on 19/05/25.
////
//
//import SwiftUI
//import os
//import Foundation // Required for NSRegularExpression
//
//@MainActor
//@Observable
//class AgentOnboardingViewModel: SetupFailedViewModelProtocol {
//    private static let logger = DGLogger(category: "AgentOnboardingViewModel")
//
//    // Overall onboarding steps
//    enum OnboardingFlowStep: Identifiable {
//        case welcome
//        case interactiveSetup // This will host the new multi-stage UI
//        case setupFailed
//        case setupComplete
//        var id: OnboardingFlowStep { self }
//    }
//
//    // Stages for the interactive setup part
//    enum InteractiveSetupStage: Identifiable, CaseIterable {
//        case pythonVerification
//        case ollamaSetup
//        case agentServerSetup
//        var id: InteractiveSetupStage { self }
//
//        var title: String {
//            switch self {
//            case .pythonVerification: return "Python Environment"
//            case .ollamaSetup: return "Ollama Configuration"
//            case .agentServerSetup: return "Agent Server"
//            }
//        }
//    }
//
//    // Status for each interactive stage
//    enum StageStatus {
//        case pending // Not yet started
//        case awaitingUserInput // User needs to do something (e.g., install Python manually)
//        case inProgress // Actively working
//        case completed // Successfully finished
//        case failed // An error occurred
//    }
//
//    // Published properties for overall flow
//    var currentFlowStep: OnboardingFlowStep = .welcome
//    var errorMessage: String? = nil
//    var scriptLog: [String] = [] // General logs if needed, or can be stage-specific
//
//    // Published properties for Interactive Setup
//    var currentInteractiveStage: InteractiveSetupStage = .pythonVerification
//    var showPythonInstallSheet: Bool = false // For the Python install prompt
//
//    // --- Python Verification Stage States ---
//    var pythonVerificationStatus: StageStatus = .pending
//    var pythonVerificationMessage: String = "Checking for Python 3.8+..."
//    var isPythonActionButtonEnabled: Bool = true
//    var pythonActionButtonTitle: String = "Begin Verification"
//    var isPythonNextButtonEnabled: Bool = false
//    var showEmbeddedPythonInstallPrompt: Bool = false // To show prompt in right panel
//
//    // --- Ollama Setup Stage States ---
//    var ollamaSetupStatus: StageStatus = .pending
//    var ollamaOverallProgressMessage: String = "Ready to configure Ollama."
//    // Hardcoded list of Ollama models
//    let hardcodedOllamaModels: [String] = [
//        "gemma:2b", "llama3:8b", "mistral:latest", "phi3:mini",
//        "qwen:4b", "llava:latest", "codellama:latest"
//    ]
//    var selectedOllamaModel: String
//    var ollamaAppInstallProgressMessage: String = ""
//    var ollamaModelDownloadProgress: Double = 0.0 // 0.0 to 1.0
//    var isOllamaActionButtonEnabled: Bool = true
//    var ollamaActionButtonTitle: String = "Begin Ollama Setup"
//    var isOllamaNextButtonEnabled: Bool = false
//    private var ollamaInstallAttempted: Bool = false // Track if we tried installing Ollama app
//
//    // --- Agent Server Setup Stage States ---
//    var agentServerStatus: StageStatus = .pending
//    var agentServerProgressMessage: String = "Ready to set up the agent server."
//    var isAgentServerFinishButtonEnabled: Bool = false
//    var agentServerActionButtonTitle: String = "Start Server Setup" // If manual start needed
//    var isAgentServerActionButtonEnabled: Bool = true // If manual start needed
//
//
//    // Callbacks
//    var onComplete: (() -> Void)?
//    var onAgentReady: ((URL, Int32) -> Void)?
//
//    // Services
//    private let orchestrator = OnboardingOrchestratorService()
//    private let privilegeEscalator = PrivilegeEscalationService()
//    private var setupTask: Task<Void, Never>? = nil
//    
//    // Stored results
//    private var agentLaunchResult: AgentLaunchResult?
//    private var venvPythonExecPath: String?
//    private var systemPythonPath: String? // Store the detected system Python path
//
//    init(onComplete: (() -> Void)? = nil, onAgentReady: ((URL, Int32) -> Void)? = nil) {
//        self.onComplete = onComplete
//        self.onAgentReady = onAgentReady
//        self.selectedOllamaModel = hardcodedOllamaModels.first ?? "gemma:2b" // Default selection
//        Self.logger.debug("AgentOnboardingViewModel initialized for interactive setup.")
//    }
//
//    // MARK: - Flow Control
//    func startOnboardingFlow() {
//        // Called from AgentWelcomeView's "Get Started"
//        resetForNewAttempt()
//        currentFlowStep = .interactiveSetup
//        // Initialize the first stage of interactive setup
//        currentInteractiveStage = .pythonVerification
//        pythonVerificationStatus = .pending
//        pythonVerificationMessage = "Ready to verify Python installation."
//        isPythonActionButtonEnabled = true
//        pythonActionButtonTitle = "Begin Verification"
//        isPythonNextButtonEnabled = false
//        showEmbeddedPythonInstallPrompt = false
//        appendLog("Interactive onboarding started. Current stage: Python Verification")
//    }
//    
//    func cancelSetup() {
//        Self.logger.info("User cancelled setup.")
//        setupTask?.cancel()
//        orchestrator.cancelCurrentTask()
//        resetForNewAttempt()
//        currentFlowStep = .welcome
//        appendLog("Setup cancelled by user.")
//    }
//
//    private func resetForNewAttempt() {
//        // Reset interactive stage states
//        pythonVerificationStatus = .pending
//        pythonVerificationMessage = "Ready to verify Python installation."
//        isPythonActionButtonEnabled = true
//        pythonActionButtonTitle = "Begin Verification"
//        isPythonNextButtonEnabled = false
//        showEmbeddedPythonInstallPrompt = false
//        
//        ollamaSetupStatus = .pending
//        ollamaOverallProgressMessage = "Ready to configure Ollama."
//        ollamaAppInstallProgressMessage = ""
//        ollamaModelDownloadProgress = 0.0
//        isOllamaActionButtonEnabled = true
//        ollamaActionButtonTitle = "Begin Ollama Setup"
//        isOllamaNextButtonEnabled = false
//        ollamaInstallAttempted = false
//        
//        agentServerStatus = .pending
//        agentServerProgressMessage = "Ready to set up the agent server."
//        isAgentServerFinishButtonEnabled = false
//        isAgentServerActionButtonEnabled = true
//        agentServerActionButtonTitle = "Start Server Setup"
//
//        scriptLog = []
//        errorMessage = nil
//        setupTask?.cancel()
//        setupTask = nil
//        orchestrator.cancelCurrentTask()
//        agentLaunchResult = nil
//        venvPythonExecPath = nil
//        systemPythonPath = nil
//        Self.logger.debug("State reset for new interactive setup attempt.")
//    }
//
//    // MARK: - Python Verification Stage
//    func handlePythonAction() {
//        guard pythonVerificationStatus != .inProgress else { return }
//        appendLog("Python action triggered. Status: \(String(describing: pythonVerificationStatus))")
//
//        pythonVerificationStatus = .inProgress
//        pythonVerificationMessage = "Verifying Python 3.8+ installation..."
//        isPythonActionButtonEnabled = false
//        isPythonNextButtonEnabled = false
//        showEmbeddedPythonInstallPrompt = false // Hide prompt if it was shown
//
//        setupTask = Task {
//            do {
//                let pythonCheck = try await orchestrator.checkPythonInstallation()
//                if pythonCheck.isInstalled, let path = pythonCheck.path {
//                    self.systemPythonPath = path // Save for later use if needed
//                    pythonVerificationStatus = .completed
//                    pythonVerificationMessage = "Python \(pythonCheck.version ?? "") found at \(path)."
//                    isPythonNextButtonEnabled = true
//                    isPythonActionButtonEnabled = false // Verification done
//                    pythonActionButtonTitle = "Verification Complete"
//                    appendLog(pythonVerificationMessage)
//                } else {
//                    pythonVerificationStatus = .failed
//                    pythonVerificationMessage = "Python 3.8+ not found. Please install or configure."
//                    showEmbeddedPythonInstallPrompt = true // Show embedded prompt options
//                    isPythonActionButtonEnabled = false // Disable 'Begin' as prompt is shown
//                    appendLog(pythonVerificationMessage)
//                }
//            } catch let error as OrchestrationError {
//                pythonVerificationStatus = .failed
//                pythonVerificationMessage = "Python check failed: \(error.localizedDescription)"
//                showEmbeddedPythonInstallPrompt = true // Show prompt on error too
//                isPythonActionButtonEnabled = false
//                appendLog("Error during Python check: \(error.localizedDescription)")
//            } catch {
//                pythonVerificationStatus = .failed
//                pythonVerificationMessage = "An unexpected error occurred during Python check: \(error.localizedDescription)"
//                showEmbeddedPythonInstallPrompt = true
//                isPythonActionButtonEnabled = false
//                appendLog("Unexpected error during Python check: \(error.localizedDescription)")
//            }
//        }
//    }
//
//    func handlePythonInstallAttemptViaHomebrew() {
//        // This is called from PythonInstallPromptView (if embedded or via sheet callback)
//        showEmbeddedPythonInstallPrompt = false // Hide prompt
//        pythonVerificationStatus = .inProgress
//        pythonVerificationMessage = "Attempting to install Python via Homebrew..."
//        isPythonActionButtonEnabled = false
//        appendLog(pythonVerificationMessage)
//
//        setupTask = Task {
//            do {
//                try await orchestrator.installPythonViaHomebrew { progressLine in
//                    DispatchQueue.main.async {
//                        self.appendLog("[Homebrew]: \(progressLine)")
//                        self.pythonVerificationMessage = "Installing Python (Homebrew): \(progressLine.prefix(60))..."
//                    }
//                }
//                appendLog("Homebrew Python installation attempt finished. Re-verifying...")
//                // Automatically re-verify after Homebrew attempt
//                handlePythonAction()
//            } catch {
//                pythonVerificationMessage = "Homebrew Python installation failed: \(error.localizedDescription)"
//                appendLog(pythonVerificationMessage)
//                // After failure, allow user to see prompt again or retry main action
//                pythonVerificationStatus = .failed
//                showEmbeddedPythonInstallPrompt = true
//                isPythonActionButtonEnabled = false
//            }
//        }
//    }
//
//    func handleUserWillInstallPythonManually() {
//        // This is called from PythonInstallPromptView
//        showEmbeddedPythonInstallPrompt = false // Hide prompt
//        pythonVerificationStatus = .awaitingUserInput
//        pythonVerificationMessage = "Please install Python 3.8+ manually, then click 'Re-check Python'."
//        pythonActionButtonTitle = "Re-check Python"
//        isPythonActionButtonEnabled = true // Enable the button to re-check
//        isPythonNextButtonEnabled = false
//        appendLog("User opted to install Python manually.")
//    }
//    
//    func proceedToOllamaSetup() {
//        guard pythonVerificationStatus == .completed else {
//            appendLog("Cannot proceed to Ollama setup, Python verification not complete.")
//            return
//        }
//        currentInteractiveStage = .ollamaSetup
//        ollamaSetupStatus = .pending
//        ollamaOverallProgressMessage = "Ready to configure Ollama."
//        isOllamaActionButtonEnabled = true
//        isOllamaNextButtonEnabled = false
//        appendLog("Proceeding to Ollama Setup stage.")
//    }
//
//    // MARK: - Ollama Setup Stage
//    func handleOllamaAction() {
//        guard ollamaSetupStatus != .inProgress else { return }
//
//        ollamaSetupStatus = .inProgress
//        ollamaOverallProgressMessage = "Starting Ollama configuration..."
//        isOllamaActionButtonEnabled = false
//        isOllamaNextButtonEnabled = false
//        ollamaModelDownloadProgress = 0.0
//        ollamaAppInstallProgressMessage = ""
//        appendLog(ollamaOverallProgressMessage)
//
//        setupTask = Task {
//            do {
//                // Part 1: Install Ollama Application (if not already installed)
//                // Perform the await call *before* the if statement
//                let isOllamaAlreadyInstalled = await orchestrator.isOllamaAppInstalled()
//
//                // Now use the result in the if condition
//                if !ollamaInstallAttempted && !isOllamaAlreadyInstalled {
//                    ollamaOverallProgressMessage = "Ollama application not found. Attempting installation..."
//                    appendLog(ollamaOverallProgressMessage)
//                    ollamaAppInstallProgressMessage = "Initiating Ollama app installation..."
//                    try await orchestrator.installOllamaApplication(
//                        progressUpdate: { progressLine in
//                            DispatchQueue.main.async {
//                                self.appendLog("[Ollama App Install]: \(progressLine)")
//                                self.ollamaAppInstallProgressMessage = progressLine
//                            }
//                        },
//                        privilegeEscalator: privilegeEscalator
//                    )
//                    appendLog("Ollama application installation process potentially completed.")
//                    ollamaAppInstallProgressMessage = "Verifying Ollama app installation..."
//                    try await Task.sleep(nanoseconds: 3_000_000_000) // 3s delay for installer
//                    guard await orchestrator.isOllamaAppInstalled() else { // This second await is fine as it's not part of a complex condition
//                        throw OrchestrationError.ollamaAppInstallFailed
//                    }
//                    ollamaAppInstallProgressMessage = "Ollama application installed successfully."
//                    appendLog(ollamaAppInstallProgressMessage)
//                } else if isOllamaAlreadyInstalled { // Use the stored result
//                     ollamaAppInstallProgressMessage = "Ollama application already installed."
//                     appendLog(ollamaAppInstallProgressMessage)
//                }
//                ollamaInstallAttempted = true
//
//
//                // Part 2: Download Selected Ollama Model
//                ollamaOverallProgressMessage = "Downloading Ollama model: \(selectedOllamaModel)..."
//                appendLog(ollamaOverallProgressMessage)
//                try await orchestrator.downloadOllamaModel(
//                    modelName: selectedOllamaModel
//                ) { progressLine, percentage in
//                    DispatchQueue.main.async {
//                        self.appendLog("[Ollama Model Pull]: \(progressLine)")
//                        if let percent = percentage {
//                            self.ollamaModelDownloadProgress = percent
//                            self.ollamaOverallProgressMessage = "Downloading \(self.selectedOllamaModel): \(Int(percent * 100))%"
//                        } else {
//                             self.ollamaOverallProgressMessage = "Pulling \(self.selectedOllamaModel): \(progressLine.prefix(60))..."
//                        }
//                    }
//                }
//                ollamaModelDownloadProgress = 1.0 // Mark as complete
//                ollamaOverallProgressMessage = "Ollama model \(selectedOllamaModel) downloaded successfully."
//                appendLog(ollamaOverallProgressMessage)
//
//                ollamaSetupStatus = .completed
//                isOllamaNextButtonEnabled = true
//                isOllamaActionButtonEnabled = false
//                ollamaActionButtonTitle = "Ollama Configured"
//
//            } catch let error as OrchestrationError {
//                ollamaSetupStatus = .failed
//                ollamaOverallProgressMessage = "Ollama setup failed: \(error.localizedDescription)"
//                isOllamaActionButtonEnabled = true
//                appendLog("Error during Ollama setup: \(error.localizedDescription)")
//            } catch {
//                ollamaSetupStatus = .failed
//                ollamaOverallProgressMessage = "An unexpected error occurred during Ollama setup: \(error.localizedDescription)"
//                isOllamaActionButtonEnabled = true
//                appendLog("Unexpected error during Ollama setup: \(error.localizedDescription)")
//            }
//        }
//    }
//    
//    func proceedToAgentServerSetup() {
//        guard ollamaSetupStatus == .completed else {
//            appendLog("Cannot proceed to Agent Server setup, Ollama setup not complete.")
//            return
//        }
//        currentInteractiveStage = .agentServerSetup
//        agentServerStatus = .pending
//        agentServerProgressMessage = "Ready to set up agent server."
//        isAgentServerActionButtonEnabled = true
//        isAgentServerFinishButtonEnabled = false
//        appendLog("Proceeding to Agent Server Setup stage.")
//    }
//
//    // MARK: - Agent Server Setup Stage
//    func handleAgentServerAction() {
//        guard agentServerStatus != .inProgress else { return }
//        guard let currentSystemPythonPath = self.systemPythonPath else {
//            agentServerProgressMessage = "System Python path not found. Cannot set up venv."
//            appendLog("Error: System Python path missing for agent server setup.")
//            agentServerStatus = .failed
//            return
//        }
//
//        agentServerStatus = .inProgress
//        agentServerProgressMessage = "Setting up Python virtual environment..."
//        isAgentServerActionButtonEnabled = false
//        isAgentServerFinishButtonEnabled = false
//        appendLog(agentServerProgressMessage)
//
//        setupTask = Task {
//            do {
//                // Part 1: Setup Virtual Environment and Install Dependencies
//                let venvPythonURL = try await orchestrator.setupPythonVirtualEnvironment(
//                    pythonExecutablePath: currentSystemPythonPath
//                ) { progressLine in
//                    DispatchQueue.main.async {
//                        self.appendLog("[Venv Setup]: \(progressLine)")
//                        self.agentServerProgressMessage = "Virtual Env: \(progressLine.prefix(60))..."
//                    }
//                }
//                self.venvPythonExecPath = venvPythonURL.path
//                agentServerProgressMessage = "Python virtual environment ready at \(venvPythonURL.path)."
//                appendLog(agentServerProgressMessage)
//
//                // Part 2: Launch Agent
//                agentServerProgressMessage = "Launching Devgentic agent..."
//                appendLog(agentServerProgressMessage)
//                let launchResult = try await orchestrator.launchAgent(venvPythonURL: venvPythonURL) { progressLine in
//                    DispatchQueue.main.async {
//                        self.appendLog("[Agent Launch]: \(progressLine)")
//                        self.agentServerProgressMessage = "Agent: \(progressLine.prefix(60))..."
//                    }
//                }
//                self.agentLaunchResult = launchResult
//                agentServerProgressMessage = "Devgentic agent launched at \(launchResult.url.absoluteString) (PID: \(launchResult.pid))."
//                appendLog(agentServerProgressMessage)
//                
//                agentServerStatus = .completed
//                isAgentServerFinishButtonEnabled = true
//                isAgentServerActionButtonEnabled = false
//                agentServerActionButtonTitle = "Server Setup Complete"
//
//            } catch let error as OrchestrationError {
//                agentServerStatus = .failed
//                agentServerProgressMessage = "Agent server setup failed: \(error.localizedDescription)"
//                isAgentServerActionButtonEnabled = true
//                appendLog("Error during agent server setup: \(error.localizedDescription)")
//            } catch {
//                agentServerStatus = .failed
//                agentServerProgressMessage = "An unexpected error during agent server setup: \(error.localizedDescription)"
//                isAgentServerActionButtonEnabled = true
//                appendLog("Unexpected error during agent server setup: \(error.localizedDescription)")
//            }
//        }
//    }
//
//    func finishInteractiveSetup() {
//        guard agentServerStatus == .completed else {
//            appendLog("Cannot finish setup, agent server setup not complete.")
//            return
//        }
//        appendLog("Interactive setup finished by user. Finalizing...")
//        Task {
//            await finalizeSuccessfulSetup()
//        }
//    }
//    
//    private func finalizeSuccessfulSetup() async {
//        guard let result = agentLaunchResult, let venvPython = venvPythonExecPath else {
//            Self.logger.error("Cannot finalize: Agent launch result or venv path is missing.")
//            currentFlowStep = .setupFailed
//            errorMessage = "Critical information missing for finalization."
//            return
//        }
//
//        Self.logger.info("Finalizing successful setup. Agent URL: \(result.url.absoluteString), PID: \(result.pid)")
//        appendLog("All setup stages complete. Saving settings...")
//
//        UserDefaults.standard.set(result.url.absoluteString, forKey: GlobalConstants.agentBaseURL)
//        UserDefaults.standard.set(result.pid, forKey: GlobalConstants.agentPID)
//        UserDefaults.standard.set(venvPython, forKey: GlobalConstants.venvPythonPath)
//        UserDefaults.standard.set(selectedOllamaModel, forKey: GlobalConstants.defaultAgentModel)
//        UserDefaults.standard.set(BackendType.agent.rawValue, forKey: GlobalConstants.selectedBackend)
//        
//        appendLog("Settings saved. Transitioning to setup complete screen.")
//        onAgentReady?(result.url, result.pid)
//        currentFlowStep = .setupComplete
//    }
//
//    private func appendLog(_ message: String) {
//        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
//        let logEntry = "[\(timestamp)] \(message)"
//        if scriptLog.count > 200 { scriptLog.removeFirst(100) }
//        scriptLog.append(logEntry)
//        Self.logger.info("\(message)")
//    }
//
//    private func handleFlowError(_ error: Error, finalMessage: String) {
//        let detailedError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
//        appendLog("Error: \(detailedError)")
//        Self.logger.error("Setup failed: \(detailedError). Final Message: \(finalMessage)")
//        self.errorMessage = "\(finalMessage)\nDetails: \(detailedError)"
//        self.currentFlowStep = .setupFailed
//    }
//    
//    deinit {
//        Self.logger.info("AgentOnboardingViewModel deinitialized.")
//        setupTask?.cancel()
//        orchestrator.cancelCurrentTask()
//    }
//}

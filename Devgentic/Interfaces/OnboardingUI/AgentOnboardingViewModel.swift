//
//  AgentOnboardingViewModel.swift
//  Devgentic
//
//  Created by Raj Singh on 19/05/25.
//

import SwiftUI
import Combine
import os

@MainActor
class AgentOnboardingViewModel: ObservableObject {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic", category: "AgentOnboardingViewModel")

    enum OnboardingStep: Identifiable {
        case welcome
        case prerequisitesCheck
        case pythonInstallNeeded
        case environmentSetup
        case setupFailed
        var id: OnboardingStep { self }
    }

    @Published var currentStep: OnboardingStep = .welcome
    @Published var isLoading: Bool = false
    @Published var loadingMessage: String = "Initializing..."
    @Published var scriptLog: [String] = []
    @Published var errorMessage: String? = nil
    @Published var showPythonInstallSheet: Bool = false

    // These closures are passed in from the view that creates this ViewModel
    var onComplete: (() -> Void)?
    var onAgentReady: ((URL, Int32) -> Void)? // Callback to inform about agent URL and PID

    private let orchestrator = OnboardingOrchestratorService()
    private let privilegeEscalator = PrivilegeEscalationService()
    private var setupTask: Task<Void, Never>? = nil
    
    // Properties to store results from the setup process
    private var agentLaunchResult: AgentLaunchResult?
    private var venvPythonExecPath: String?
    private let defaultAgentModel = "gemma:2b" // Default model, ensure orchestrator uses the same

    // Initializer that accepts both onComplete and onAgentReady
    init(onComplete: (() -> Void)? = nil, onAgentReady: ((URL, Int32) -> Void)? = nil) {
        self.onComplete = onComplete
        self.onAgentReady = onAgentReady
        Self.logger.debug("AgentOnboardingViewModel initialized.")
    }

    func startSetup() {
        guard !isLoading else {
            Self.logger.info("Setup already in progress.")
            return
        }
        
        resetForNewAttempt() // Clear previous state
        currentStep = .prerequisitesCheck
        isLoading = true
        loadingMessage = "Starting setup..."
        appendLog("Starting Devgentic Agent setup...")

        setupTask = Task {
            do {
                // 1. Check Python
                loadingMessage = "Checking Python installation..."
                appendLog("Step 1: Checking Python installation...")
                let pythonCheck = try await orchestrator.checkPythonInstallation()
                if pythonCheck.isInstalled, let path = pythonCheck.path {
                    appendLog("Python \(pythonCheck.version ?? "unknown version") found at \(path).")
                    // If Python is found, proceed with the full setup
                    try await proceedWithFullSetup(pythonExecutablePath: path)
                } else {
                    appendLog("Python 3.8+ not found.")
                    loadingMessage = "Python 3.8+ is required."
                    currentStep = .pythonInstallNeeded
                    showPythonInstallSheet = true // Trigger UI to show Python installation options
                    isLoading = false // Allow user interaction for Python install prompt
                }
            } catch let error as OrchestrationError {
                handleError(error, finalMessage: "Prerequisite check failed.")
            } catch {
                handleError(error, finalMessage: "An unexpected error occurred during prerequisite checks.")
            }
        }
    }

    func userWillInstallPythonManually() {
        showPythonInstallSheet = false // Dismiss the sheet/prompt
        currentStep = .welcome // Go back to welcome, user can click "Get Started" to retry
        isLoading = false
        loadingMessage = "Please install Python 3.8+ and click 'Get Started' again."
        appendLog("User opted to install Python manually. Please restart setup when ready.")
    }

    func attemptPythonInstallationViaHomebrew() {
        guard !isLoading else { return }
        
        showPythonInstallSheet = false
        currentStep = .prerequisitesCheck // Show "in progress" view
        isLoading = true
        loadingMessage = "Attempting to install Python via Homebrew..."
        appendLog("Attempting to install Python via Homebrew. This may take a while...")
        errorMessage = nil

        setupTask = Task {
            do {
                try await orchestrator.installPythonViaHomebrew { progressLine in
                    DispatchQueue.main.async {
                        self.appendLog(progressLine)
                        self.loadingMessage = "Installing Python: \(progressLine.prefix(80))..."
                    }
                }
                appendLog("Homebrew Python installation process completed. Re-checking Python...")
                // After attempting install, re-run the initial setup check
                self.startSetup() // This will re-check Python and proceed if successful
            } catch let error as OrchestrationError {
                appendLog("Homebrew Python installation failed: \(error.localizedDescription)")
                handleError(error, finalMessage: "Failed to install Python using Homebrew.")
                currentStep = .pythonInstallNeeded // Go back to prompt on failure
                showPythonInstallSheet = true
            } catch {
                appendLog("Unexpected error during Homebrew Python installation: \(error.localizedDescription)")
                handleError(error, finalMessage: "Unexpected error installing Python.")
                currentStep = .pythonInstallNeeded
                showPythonInstallSheet = true
            }
        }
    }

    private func proceedWithFullSetup(pythonExecutablePath: String) async throws {
        currentStep = .environmentSetup // Indicate that full setup is in progress
        isLoading = true // Ensure loading state is active
        
        // 2. Setup Virtual Environment
        loadingMessage = "Setting up Python virtual environment..."
        appendLog("Step 2: Setting up Python virtual environment '\(SettingsKeys.venvName)'...")
        let venvPythonURL = try await orchestrator.setupPythonVirtualEnvironment(pythonExecutablePath: pythonExecutablePath) { progressLine in
            DispatchQueue.main.async { self.appendLog(progressLine) }
        }
        self.venvPythonExecPath = venvPythonURL.path // Save venv python path for later use (e.g., AgentManager)
        appendLog("Python virtual environment ready at \(venvPythonURL.path).")

        // 3. Install Ollama Application (using local.py initial phase + admin if needed)
        loadingMessage = "Setting up Ollama application..."
        appendLog("Step 3: Setting up Ollama application...")
        if await orchestrator.isOllamaAppInstalled() {
            appendLog("Ollama application is already installed.")
        } else {
            try await orchestrator.installOllamaApplication(
                progressUpdate: { progressLine in DispatchQueue.main.async { self.appendLog(progressLine) } },
                privilegeEscalator: privilegeEscalator
            )
            appendLog("Ollama application setup process potentially completed by script.")
            // Add a small delay and re-check for Ollama.app to ensure FS changes are visible
            // and installer has finished its work if it ran silently.
            try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            guard await orchestrator.isOllamaAppInstalled() else {
                appendLog("Ollama application installation failed or not detected after setup attempt.")
                throw OrchestrationError.ollamaAppInstallFailed
            }
            appendLog("Ollama application successfully installed/verified.")
        }

        // 4. Download Ollama Model (using local.py post-install phase)
        loadingMessage = "Downloading default Ollama model (\(defaultAgentModel))..."
        appendLog("Step 4: Downloading Ollama model '\(defaultAgentModel)'...")
        try await orchestrator.downloadOllamaModel(modelName: defaultAgentModel) { progressLine in
            DispatchQueue.main.async { self.appendLog(progressLine) }
        }
        appendLog("Ollama model '\(defaultAgentModel)' download process finished.")

        // 5. Launch Agent
        loadingMessage = "Launching Devgentic agent..."
        appendLog("Step 5: Launching Devgentic agent...")
        let launchResult = try await orchestrator.launchAgent(venvPythonURL: venvPythonURL) { progressLine in
            DispatchQueue.main.async { self.appendLog(progressLine) }
        }
        self.agentLaunchResult = launchResult // Store URL and PID from the launch result
        appendLog("Devgentic agent launched successfully at \(launchResult.url.absoluteString) (PID: \(launchResult.pid)).")

        // All steps complete, finalize onboarding
        completeOnboarding()
    }

    func completeOnboarding() {
        // Ensure we have the necessary results from the setup process
        guard let result = agentLaunchResult else {
            Self.logger.error("Cannot complete onboarding: Agent launch result (URL/PID) is missing.")
            errorMessage = "Agent URL/PID not found. Setup may be incomplete."
            currentStep = .setupFailed
            isLoading = false
            return
        }
        guard let venvPython = venvPythonExecPath else {
             Self.logger.error("Cannot complete onboarding: Virtual environment Python path is missing.")
            errorMessage = "Python environment path not found. Setup may be incomplete."
            currentStep = .setupFailed
            isLoading = false
            return
        }

        Self.logger.info("Completing onboarding. Agent URL: \(result.url.absoluteString), PID: \(result.pid), Model: \(self.defaultAgentModel), Venv Python: \(venvPython)")
        appendLog("All setup stages complete. Finalizing...")

        // Save all necessary settings to UserDefaults
        UserDefaults.standard.set(result.url.absoluteString, forKey: SettingsKeys.agentBaseURL)
        UserDefaults.standard.set(result.pid, forKey: SettingsKeys.agentPID)
        UserDefaults.standard.set(venvPython, forKey: SettingsKeys.venvPythonPath)
        UserDefaults.standard.set(defaultAgentModel, forKey: SettingsKeys.defaultAgentModel)
        UserDefaults.standard.set(BackendType.agent.rawValue, forKey: SettingsKeys.selectedBackend)
        UserDefaults.standard.set(true, forKey: SettingsKeys.isOnboardingComplete)
        
        isLoading = false // No longer loading
        loadingMessage = "Setup Complete!" // Final message
        appendLog("Onboarding complete. Settings saved.")

        // Notify listeners that the agent is ready and onboarding is complete
        onAgentReady?(result.url, result.pid)
        onComplete?()
    }
    
    func cancelSetup() {
        Self.logger.info("User cancelled setup.")
        setupTask?.cancel() // Cancel the async Task
        orchestrator.cancelCurrentTask() // Interrupt any ongoing Process in the orchestrator
        resetForNewAttempt()
        currentStep = .welcome // Revert to the welcome screen
        appendLog("Setup cancelled by user.")
    }

    private func resetForNewAttempt() {
        isLoading = false
        scriptLog = []
        errorMessage = nil
        loadingMessage = ""
        setupTask?.cancel() // Ensure any previous task is cancelled
        setupTask = nil
        orchestrator.cancelCurrentTask() // Also ensure orchestrator's process is stopped
        agentLaunchResult = nil
        venvPythonExecPath = nil
        Self.logger.debug("State reset for new setup attempt.")
    }
    
    private func appendLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(timestamp)] \(message)"
        scriptLog.append(logEntry)
        Self.logger.info("\(message)") // Also log to system console for easier debugging
        // Limit the size of the log displayed in the UI
        if scriptLog.count > 200 {
            scriptLog.removeFirst(100)
        }
    }

    private func handleError(_ error: Error, finalMessage: String) {
        let detailedError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        appendLog("Error: \(detailedError)")
        Self.logger.error("Setup failed: \(detailedError). Final Message: \(finalMessage)")
        self.errorMessage = "\(finalMessage)\nDetails: \(detailedError)"
        self.currentStep = .setupFailed
        self.isLoading = false
        self.loadingMessage = "Setup Failed" // Update loading message to reflect failure
    }
    
    deinit {
        Self.logger.info("AgentOnboardingViewModel deinitialized. Cancelling any active task.")
        setupTask?.cancel()
        orchestrator.cancelCurrentTask()
    }
}

// Ensure SettingsKeys and BackendType are accessible.
// These might be defined globally or in a shared file.
// Example (if not defined elsewhere for compilation):
/*
struct SettingsKeys {
    static let agentBaseURL = "agentBaseURL"
    static let defaultAgentModel = "defaultAgentModel"
    static let selectedBackend = "selectedBackend"
    static let isOnboardingComplete = "isOnboardingComplete"
    static let agentPID = "agentPID"
    static let venvPythonPath = "venvPythonPath"
    static let venvName = "devgentic" // Added for consistency if orchestrator uses it
}

enum BackendType: String {
    case agent = "agent"
    case ollama = "ollama"
}
*/

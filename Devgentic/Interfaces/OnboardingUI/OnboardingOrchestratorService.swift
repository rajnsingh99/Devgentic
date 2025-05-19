//
//  OnboardingOrchestratorService.swift
//  Devgentic
//
//  Created by Raj Singh on 19/05/25.
//

import Foundation
import Combine
import os // For logging

// Logger for this service
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic", category: "OnboardingOrchestrator")

// Define potential errors that can occur during the orchestration process
enum OrchestrationError: LocalizedError {
    case pythonNotInstalled
    case pythonVersionTooLow(foundVersion: String)
    case homebrewNotInstalled
    case processExecutionFailed(command: String, exitCode: Int32, standardError: String)
    case virtualEnvironmentCreationFailed
    case requirementsInstallationFailed
    case scriptNotFound(scriptName: String)
    case ollamaAppInstallFailed
    case ollamaModelDownloadFailed
    case agentLaunchFailed(reason: String) // Added reason
    case agentDidNotReportURL
    case agentDidNotReportPID
    case unexpectedOutput(output: String)
    case adminPrivilegeRequiredButNotHandled
    case adminCommandParseFailed
    case cancelled
    case generic(message: String)

    var errorDescription: String? {
        switch self {
        case .pythonNotInstalled:
            return "Python 3.8+ is not installed. Please install it and try again."
        case .pythonVersionTooLow(let foundVersion):
            return "Python version \(foundVersion) is too low. Devgentic requires Python 3.8+."
        case .homebrewNotInstalled:
            return "Homebrew is not installed. It's needed if you want the app to attempt Python installation."
        case .processExecutionFailed(let command, let exitCode, let stdErr):
            return "Command '\(command)' failed with exit code \(exitCode). Error: \(stdErr.isEmpty ? "No specific error output." : stdErr)"
        case .virtualEnvironmentCreationFailed:
            return "Failed to create the Python virtual environment 'devgentic'."
        case .requirementsInstallationFailed:
            return "Failed to install Python dependencies from requirements.txt."
        case .scriptNotFound(let scriptName):
            return "Required script '\(scriptName)' was not found in the app bundle."
        case .ollamaAppInstallFailed:
            return "Failed to install the Ollama application."
        case .ollamaModelDownloadFailed:
            return "Failed to download the Ollama model."
        case .agentLaunchFailed(let reason):
            return "Failed to launch the Devgentic agent: \(reason)"
        case .agentDidNotReportURL:
            return "Agent launched but did not report its operational URL."
        case .agentDidNotReportPID:
            return "Agent launched but did not report its Process ID."
        case .unexpectedOutput(let output):
            return "Received unexpected output: \(output)"
        case .adminPrivilegeRequiredButNotHandled:
            return "Admin privilege was required by the script, but the command details could not be parsed or handled."
        case .adminCommandParseFailed:
            return "Failed to parse the admin command from the script's output."
        case .cancelled:
            return "The setup process was cancelled."
        case .generic(let message):
            return message
        }
    }
}

// Structure to hold Python check results
struct PythonCheckResult {
    let isInstalled: Bool
    let version: String?
    let path: String?
}

// Structure for Agent Launch results
struct AgentLaunchResult {
    let url: URL
    let pid: Int32
}

// Structure to decode the JSON payload for admin commands from local.py
// local.py output: {"command": ["/usr/sbin/installer", "-pkg", installer_path, "-target", "/"]}
struct AdminCommandPayload: Decodable {
    let command: [String] // The command and its arguments are a single array
}


// Main orchestrator service for the new agent onboarding
class OnboardingOrchestratorService {

    private var currentProcess: Process? // Renamed from currentTask to avoid confusion with Swift Tasks
    private let venvName = "devgentic"
    private let defaultOllamaModel = "gemma:2b" // Example model

    // MARK: - Public API (Python Checks, Venv, Ollama Install -  No changes from previous version)

    /// Checks if Python 3.8+ is installed and accessible.
    public func checkPythonInstallation() async throws -> PythonCheckResult {
        logger.info("Checking Python installation...")
        do {
            let whichPythonPath = try await runProcess(executableURL: URL(fileURLWithPath: "/usr/bin/which"), arguments: ["python3"])
            let pythonPath = whichPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)

            if pythonPath.isEmpty || pythonPath.contains("not found") {
                logger.warning("Python 3 not found via 'which python3'.")
                return PythonCheckResult(isInstalled: false, version: nil, path: nil)
            }

            logger.info("Python 3 found at: \(pythonPath)")

            let versionOutput = try await runProcess(executableURL: URL(fileURLWithPath: pythonPath), arguments: ["--version"])
            let versionString = versionOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if let version = parsePythonVersion(versionString) {
                logger.info("Python version: \(versionString)")
                if isVersionSufficient(version) {
                    return PythonCheckResult(isInstalled: true, version: versionString, path: pythonPath)
                } else {
                    logger.error("Python version \(versionString) is insufficient.")
                    throw OrchestrationError.pythonVersionTooLow(foundVersion: versionString)
                }
            } else {
                logger.error("Could not parse Python version from output: \(versionString)")
                throw OrchestrationError.unexpectedOutput(output: versionString)
            }
        } catch let error as OrchestrationError {
            throw error // Re-throw known orchestration errors
        } catch {
            logger.error("Failed to check Python installation: \(error.localizedDescription)")
            // This might happen if 'which' itself fails for unexpected reasons
            throw OrchestrationError.processExecutionFailed(command: "/usr/bin/which python3", exitCode: -1, standardError: error.localizedDescription)
        }
    }

    /// Attempts to install Python using Homebrew.
    public func installPythonViaHomebrew(progressUpdate: @escaping (String) -> Void) async throws {
        logger.info("Attempting to install Python via Homebrew...")
        progressUpdate("Checking for Homebrew...")

        // 1. Check for Homebrew
        guard let brewPath = try? await runProcess(executableURL: URL(fileURLWithPath: "/usr/bin/which"), arguments: ["brew"]).trimmingCharacters(in: .whitespacesAndNewlines),
              !brewPath.isEmpty, !brewPath.contains("not found") else {
            logger.error("Homebrew not found.")
            progressUpdate("Error: Homebrew not found. Please install Homebrew first.")
            throw OrchestrationError.homebrewNotInstalled
        }
        logger.info("Homebrew found at: \(brewPath)")
        progressUpdate("Homebrew found. Starting Python installation (this may take several minutes)...")

        // 2. Run `brew install python`
        do {
            try await runProcessStreaming(
                executableURL: URL(fileURLWithPath: brewPath),
                arguments: ["install", "python"],
                outputHandler: { line, isStdErr in // Expecting (String, Bool) from updated runProcessStreaming
                    progressUpdate(line)
                    if isStdErr { logger.error("[Brew Install Python STDERR]: \(line)") }
                    else { logger.debug("[Brew Install Python STDOUT]: \(line)") }
                }
            )
            progressUpdate("Python installation via Homebrew completed. Please re-check Python status.")
            logger.info("Python installation via Homebrew appears to have completed.")
        } catch {
            progressUpdate("Error during Homebrew Python installation: \(error.localizedDescription)")
            logger.error("Failed to install Python via Homebrew: \(error.localizedDescription)")
            if let orchError = error as? OrchestrationError {
                throw orchError
            }
            throw OrchestrationError.generic(message: "Failed to install Python using Homebrew: \(error.localizedDescription)")
        }
    }


    /// Sets up a Python virtual environment named 'devgentic' and installs dependencies.
    public func setupPythonVirtualEnvironment(pythonExecutablePath: String, progressUpdate: @escaping (String) -> Void) async throws -> URL {
        logger.info("Setting up Python virtual environment '\(self.venvName)' using \(pythonExecutablePath)...")
        progressUpdate("Creating virtual environment '\(venvName)'...")

        let fileManager = FileManager.default
        guard let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            logger.error("Could not find Application Support directory.")
            throw OrchestrationError.generic(message: "Could not find Application Support directory.")
        }

        let venvParentDir = appSupportDir.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.devgentic", isDirectory: true)
        try fileManager.createDirectory(at: venvParentDir, withIntermediateDirectories: true, attributes: nil)
        
        let venvDir = venvParentDir.appendingPathComponent(venvName, isDirectory: true)
        logger.info("Virtual environment path: \(venvDir.path)")

        // Remove existing venv if any, to ensure a clean state
        if fileManager.fileExists(atPath: venvDir.path) {
            logger.info("Removing existing virtual environment at \(venvDir.path)")
            progressUpdate("Removing old virtual environment...")
            try fileManager.removeItem(at: venvDir)
        }

        // 1. Create virtual environment: `python3 -m venv <venv_dir_path>`
        do {
            try await runProcessStreaming(
                executableURL: URL(fileURLWithPath: pythonExecutablePath),
                arguments: ["-m", "venv", venvDir.path],
                outputHandler: { line, isStdErr in
                    progressUpdate(line)
                    if isStdErr { logger.error("[Venv Create STDERR]: \(line)") }
                    else { logger.debug("[Venv Create STDOUT]: \(line)") }
                }
            )
            progressUpdate("Virtual environment created.")
            logger.info("Virtual environment '\(self.venvName)' created at \(venvDir.path)")
        } catch {
            progressUpdate("Error creating virtual environment: \(error.localizedDescription)")
            logger.error("Failed to create virtual environment: \(error.localizedDescription)")
            throw OrchestrationError.virtualEnvironmentCreationFailed
        }

        // 2. Install dependencies from requirements.txt
        let venvPythonPath = venvDir.appendingPathComponent("bin/python").path
        guard fileManager.fileExists(atPath: venvPythonPath) else {
            logger.error("Python executable not found in venv: \(venvPythonPath)")
            throw OrchestrationError.virtualEnvironmentCreationFailed
        }

        guard let requirementsPath = Bundle.main.path(forResource: "requirements", ofType: "txt") else {
            logger.error("requirements.txt not found in bundle.")
            throw OrchestrationError.scriptNotFound(scriptName: "requirements.txt")
        }
        logger.info("Installing dependencies from: \(requirementsPath)")
        progressUpdate("Installing Python dependencies...")

        do {
            try await runProcessStreaming(
                executableURL: URL(fileURLWithPath: venvPythonPath),
                arguments: ["-m", "pip", "install", "-r", requirementsPath],
                outputHandler: { line, isStdErr in
                    progressUpdate(line)
                    if isStdErr { logger.error("[Pip Install STDERR]: \(line)") }
                    else { logger.debug("[Pip Install STDOUT]: \(line)") }
                }
            )
            progressUpdate("Dependencies installed successfully.")
            logger.info("Successfully installed dependencies from requirements.txt into \(self.venvName).")
            return URL(fileURLWithPath: venvPythonPath)
        } catch {
            progressUpdate("Error installing dependencies: \(error.localizedDescription)")
            logger.error("Failed to install dependencies: \(error.localizedDescription)")
            throw OrchestrationError.requirementsInstallationFailed
        }
    }

    /// Coordinates the installation of the Ollama application using `local.py` script.
    public func installOllamaApplication(
        progressUpdate: @escaping (String) -> Void,
        privilegeEscalator: PrivilegeEscalationService // Assuming PrivilegeEscalationService is available
    ) async throws {
        logger.info("Starting Ollama application installation process...")
        progressUpdate("Checking for existing Ollama installation...")

        guard let localPyPath = Bundle.main.path(forResource: "local", ofType: "py") else {
            logger.error("local.py script not found in bundle.")
            throw OrchestrationError.scriptNotFound(scriptName: "local.py")
        }

        // Determine system's python3 path for running local.py initially
        let pythonCheck = try await checkPythonInstallation()
        guard pythonCheck.isInstalled, let systemPythonPath = pythonCheck.path else {
            logger.error("System Python 3 not found, cannot run local.py for Ollama app install.")
            throw OrchestrationError.pythonNotInstalled
        }
        
        logger.info("Using Python at \(systemPythonPath) to run local.py initial phase.")
        progressUpdate("Running Ollama setup script (initial phase)...")

        var adminCommandToExecute: AdminCommandPayload? = nil
        var ollamaAlreadyInstalledByScript = false
        var privilegeMarkerDetected = false // To know when to expect JSON

        do {
            try await runProcessStreaming(
                executableURL: URL(fileURLWithPath: systemPythonPath),
                arguments: [localPyPath, "--phase", "initial"],
                outputHandler: { line, isStdErr in // line, isStdErr
                    progressUpdate(line) // Show all output
//                    if isStdErr { logger.warn("[local.py initial STDERR]: \(line)") } // local.py might print info to stderr
//                    else { logger.info("[local.py initial STDOUT]: \(line)") }

                    if line.contains("Ollama is already installed.") {
                        ollamaAlreadyInstalledByScript = true
                        logger.info("local.py reported Ollama is already installed.")
                    }
                    if line.contains("###REQUIRES_ELEVATED_PRIVILEGES###") {
                        privilegeMarkerDetected = true
                        logger.info("local.py signaled for elevated privileges. Expecting JSON on next non-empty line.")
                        // The next non-empty line should be the JSON
                    } else if privilegeMarkerDetected, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // This line should be the JSON payload
                        logger.debug("Attempting to parse JSON for admin command: \(line)")
                        if let jsonData = line.data(using: .utf8) {
                            do {
                                adminCommandToExecute = try JSONDecoder().decode(AdminCommandPayload.self, from: jsonData)
                                logger.info("Parsed admin command from local.py: \(adminCommandToExecute?.command.joined(separator: " ") ?? "nil")")
                            } catch {
                                logger.error("Failed to parse admin command JSON '\(line)': \(error.localizedDescription)")
                                // Don't throw yet, let script finish; will check adminCommandToExecute later
                            }
                        }
                        privilegeMarkerDetected = false // Reset after processing the line (or attempting to)
                    }
                }
            )
            logger.info("local.py initial phase completed its execution.")
            progressUpdate("Ollama setup script (initial phase) finished.")

        } catch let error as OrchestrationError { // If runProcessStreaming throws an OrchestrationError (e.g. non-zero exit)
             if ollamaAlreadyInstalledByScript { // Check if the script signaled this before failing for other reasons
                logger.info("local.py indicated Ollama already installed (caught via OrchestrationError, possibly from non-zero exit despite message).")
                progressUpdate("Ollama application is already installed.")
                return // Successfully handled, Ollama is present.
            }
            logger.error("local.py initial phase failed: \(error.localizedDescription)")
            progressUpdate("Error during Ollama setup (initial phase): \(error.localizedDescription)")
            throw OrchestrationError.ollamaAppInstallFailed
        } catch { // Other errors
            logger.error("local.py initial phase failed with unexpected error: \(error.localizedDescription)")
            progressUpdate("Error during Ollama setup (initial phase): \(error.localizedDescription)")
            throw OrchestrationError.ollamaAppInstallFailed
        }

        // After script execution, evaluate outcomes:
        if ollamaAlreadyInstalledByScript {
            progressUpdate("Ollama application is already installed (detected by script).")
            logger.info("Skipping admin escalation as local.py reported Ollama already installed.")
            return
        }

        // If admin command was parsed from script output:
        if let commandPayload = adminCommandToExecute, !commandPayload.command.isEmpty {
            let commandPath = commandPayload.command.first! // First element is the command
            let arguments = Array(commandPayload.command.dropFirst()) // Rest are arguments

            progressUpdate("Ollama installer requires administrator privileges to run: \(commandPath)")
            logger.info("Executing Ollama installer with admin privileges: \(commandPath) \(arguments.joined(separator: " "))")
            
            let success = await privilegeEscalator.executeWithAdminPrivileges(
                commandPath: commandPath,
                arguments: arguments
            )
            if success {
                progressUpdate("Ollama installer executed with admin rights.")
                logger.info("Privileged command for Ollama installation executed successfully.")
            } else {
                progressUpdate("Ollama installer failed or was cancelled by user (admin rights).")
                logger.error("Privileged command for Ollama installation failed or was cancelled.")
                throw OrchestrationError.ollamaAppInstallFailed // Or a more specific error like .adminPrivilegeDenied
            }
        } else if privilegeMarkerDetected && adminCommandToExecute == nil {
            // Marker was seen, but no valid JSON command followed. This is an error in script communication.
            logger.error("Privilege marker was detected from local.py, but a valid admin command was not parsed.")
            progressUpdate("Error: Script indicated admin rights needed, but command was unclear.")
            throw OrchestrationError.adminCommandParseFailed
        } else if !(await isOllamaAppInstalled()) {
             // If script finished (no error), didn't say "already installed", didn't provide admin command (or it wasn't needed),
             // but Ollama.app is still not there. This is a failure.
             logger.warning("No admin command parsed or Ollama already installed signal from local.py, and Ollama app still not found. Installation might have failed silently or the flow is incomplete.")
             throw OrchestrationError.ollamaAppInstallFailed
        }
         progressUpdate("Ollama application setup process potentially complete. Verification will occur during model download.")
    }
    
    /// Checks if the Ollama.app is present in the /Applications directory.
    public func isOllamaAppInstalled() async -> Bool {
        let ollamaAppPath = "/Applications/Ollama.app"
        let isInstalled = FileManager.default.fileExists(atPath: ollamaAppPath)
        logger.info("Ollama.app at \(ollamaAppPath) exists: \(isInstalled)")
        return isInstalled
    }

    /// Downloads the specified Ollama model using the `local.py` script's post-install phase.
    public func downloadOllamaModel(modelName: String? = nil, progressUpdate: @escaping (String) -> Void) async throws {
        let modelToDownload = modelName ?? defaultOllamaModel
        logger.info("Starting Ollama model download for: \(modelToDownload)")
        progressUpdate("Downloading Ollama model: \(modelToDownload)... (This may take time)")

        guard let localPyPath = Bundle.main.path(forResource: "local", ofType: "py") else {
            logger.error("local.py script not found in bundle.")
            throw OrchestrationError.scriptNotFound(scriptName: "local.py")
        }

        // Use system's python3 for local.py, as it interacts with the system-installed Ollama CLI
        let pythonCheck = try await checkPythonInstallation()
        guard pythonCheck.isInstalled, let systemPythonPath = pythonCheck.path else {
            logger.error("System Python 3 not found, cannot run local.py for Ollama model download.")
            throw OrchestrationError.pythonNotInstalled
        }

        logger.info("Using Python at \(systemPythonPath) to run local.py post-install phase for model \(modelToDownload).")

        do {
            try await runProcessStreaming(
                executableURL: URL(fileURLWithPath: systemPythonPath),
                arguments: [localPyPath, "--phase", "post-install", modelToDownload],
                outputHandler: { line, isStdErr in // line, isStdErr
                    progressUpdate(line) // Show all output from script
//                    if isStdErr { logger.warn("[local.py post-install STDERR]: \(line)")}
//                    else {logger.info("[local.py post-install STDOUT]: \(line)")}
                }
            )
            progressUpdate("Ollama model \(modelToDownload) download process finished.")
            logger.info("local.py post-install phase for model \(modelToDownload) completed.")
            // Further verification (e.g., `ollama list`) could be added here if local.py's success is not guaranteed by exit code 0.
        } catch {
            progressUpdate("Error downloading Ollama model \(modelToDownload): \(error.localizedDescription)")
            logger.error("local.py post-install phase for model \(modelToDownload) failed: \(error.localizedDescription)")
            throw OrchestrationError.ollamaModelDownloadFailed
        }
    }


    /// Launches the Python-based Langchain agent.
    /// - Returns: An `AgentLaunchResult` containing the agent's URL and PID.
    public func launchAgent(venvPythonURL: URL, progressUpdate: @escaping (String) -> Void) async throws -> AgentLaunchResult {
        logger.info("Launching agent using Python from: \(venvPythonURL.path)")
        progressUpdate("Starting Devgentic agent...")

        guard let agentScriptPath = Bundle.main.path(forResource: "agent_launcher", ofType: "py") else {
            logger.error("agent_launcher.py not found in bundle.")
            throw OrchestrationError.scriptNotFound(scriptName: "agent_launcher.py")
        }
        
        var agentURLString: String? = nil
        var agentPIDString: String? = nil
        let agentURLMarker = "Agent running on:"
        let agentPIDMarker = "Agent PID:"
        var agentProcess: Process? // Keep a reference to manage it if needed during this launch phase

        // Using a Task to manage the agent's lifecycle and capture its startup URL & PID
        return try await withTaskCancellationHandler { // Handles cancellation of this async function
            try await withCheckedThrowingContinuation { continuation in
                agentProcess = Process()
                guard let process = agentProcess else {
                    continuation.resume(throwing: OrchestrationError.generic(message: "Failed to initialize agent process."))
                    return
                }
                self.currentProcess = process // Assign to instance var for potential cancellation from outside

                process.executableURL = venvPythonURL
                process.arguments = [agentScriptPath]

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                
                var accumulatedAgentError = ""

                // Read STDOUT
                outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                    let data = fileHandle.availableData
                    if let line = String(data: data, encoding: .utf8) { // Process potentially multiple lines
                        DispatchQueue.main.async { // Ensure UI updates and state changes are on main thread
                            line.split(separator: "\n").forEach { subLine in
                                let trimmedLine = String(subLine).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmedLine.isEmpty {
                                    progressUpdate(trimmedLine)
                                    logger.info("[Agent STDOUT]: \(trimmedLine)")
                                    if trimmedLine.contains(agentURLMarker) {
                                        if let urlPart = trimmedLine.split(separator: agentURLMarker).last?.trimmingCharacters(in: .whitespacesAndNewlines) {
                                            agentURLString = String(urlPart)
                                            logger.info("Detected agent URL string: \(String(urlPart))")
                                        }
                                    }
                                    if trimmedLine.contains(agentPIDMarker) {
                                        if let pidPart = trimmedLine.split(separator: agentPIDMarker).last?.trimmingCharacters(in: .whitespacesAndNewlines) {
                                            agentPIDString = String(pidPart)
                                            logger.info("Detected agent PID string: \(String(pidPart))")
                                        }
                                    }

                                    // Check if both URL and PID are found
                                    if let urlStr = agentURLString, let url = URL(string: urlStr),
                                       let pidStr = agentPIDString, let pid = Int32(pidStr),
                                       agentURLString != "RESUMED" { // Ensure not already resumed
                                        agentURLString = "RESUMED" // Mark as resumed to prevent multiple calls
                                        logger.info("Agent URL and PID successfully parsed. Resuming continuation.")
                                        continuation.resume(returning: AgentLaunchResult(url: url, pid: pid))
                                    }
                                }
                            }
                        }
                    }
                }

                // Read STDERR
                errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                    let data = fileHandle.availableData
                    if let line = String(data: data, encoding: .utf8) {
                         DispatchQueue.main.async {
                            line.split(separator: "\n").forEach { subLine in
                                let trimmedLine = String(subLine).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmedLine.isEmpty {
                                    progressUpdate("AGENT_ERROR: \(trimmedLine)")
                                    logger.error("[Agent STDERR]: \(trimmedLine)")
                                    accumulatedAgentError += trimmedLine + "\n"
                                }
                            }
                        }
                    }
                }

                // Process Termination Handler
                process.terminationHandler = { terminatedProcess in
                    logger.info("Agent process terminated with status: \(terminatedProcess.terminationStatus). URL found: \(agentURLString != nil), PID found: \(agentPIDString != nil)")
                    // Clean up pipe handlers
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    
                    // If continuation hasn't been resumed (marked by agentURLString == "RESUMED")
                    if agentURLString != "RESUMED" {
                        var reason = "Agent exited prematurely."
                        if agentURLString == nil && agentPIDString == nil { // Neither was found
                            reason = "Agent did not report URL or PID."
                        } else if agentURLString == nil { // PID found but URL not
                            reason = "Agent did not report its URL."
                        } else if agentPIDString == nil { // URL found but PID not
                            reason = "Agent did not report its PID."
                        }
                        let errorMsg = accumulatedAgentError.isEmpty ? reason : accumulatedAgentError
                        logger.error("Agent launch failed before URL/PID capture: \(errorMsg)")
                        continuation.resume(throwing: OrchestrationError.processExecutionFailed(
                            command: "agent_launcher.py",
                            exitCode: terminatedProcess.terminationStatus,
                            standardError: errorMsg
                        ))
                    }
                    // If continuation was already resumed, this termination might be normal (e.g. app quitting) or an unexpected crash.
                    // The AgentManager will handle monitoring for unexpected crashes post-launch.
                    if self.currentProcess == terminatedProcess { self.currentProcess = nil }
                }

                // Launch Process
                do {
                    logger.info("Attempting to run agent process: \(venvPythonURL.path) \(agentScriptPath)")
                    try process.run()
                    // Store the PID from the Process object itself immediately after launch
                    // This is a fallback if parsing from stdout fails or is delayed.
                    // However, agent_launcher.py now prints its PID, which is more reliable.
                    logger.info("Agent process launched (OS PID: \(process.processIdentifier)). Waiting for script to report URL and its own PID...")
                } catch {
                    logger.error("Failed to run agent process: \(error.localizedDescription)")
                    continuation.resume(throwing: OrchestrationError.agentLaunchFailed(reason: error.localizedDescription))
                    if self.currentProcess == process { self.currentProcess = nil }
                }
            }
        } onCancel: { // This is for withTaskCancellationHandler
            // This block is called if the Task wrapping withCheckedThrowingContinuation is cancelled.
            logger.info("Agent launch task cancelled. Interrupting agent process.")
            agentProcess?.interrupt() // Attempt graceful shutdown of the python script
            if self.currentProcess == agentProcess { // Clear if it's the one we are managing
                 self.currentProcess = nil
            }
        }
    }

    /// Cancels the current long-running task (e.g., script execution).
    public func cancelCurrentTask() {
        logger.info("Attempting to cancel current process (PID: \(self.currentProcess?.processIdentifier ?? -1)).")
        currentProcess?.interrupt() // Sends SIGINT, preferred for graceful shutdown
        // For more forceful termination: currentProcess?.terminate() // Sends SIGTERM
        currentProcess = nil
    }

    // MARK: - Private Helpers (parsePythonVersion, isVersionSufficient, runProcess, runProcessStreaming)

    private func parsePythonVersion(_ versionString: String) -> (major: Int, minor: Int, patch: Int)? {
        let components = versionString.split(separator: " ")
        // Ensure "Python" is the first word, case-insensitive
        guard components.count > 1, components[0].lowercased() == "python" else { return nil }
        
        // The version number is the last component
        let versionParts = components.last!.split(separator: ".").compactMap { Int($0) }
        guard versionParts.count >= 2 else { return nil } // Need at least major.minor

        return (versionParts[0], versionParts[1], versionParts.count > 2 ? versionParts[2] : 0)
    }

    private func isVersionSufficient(_ version: (major: Int, minor: Int, patch: Int)) -> Bool {
        return version.major == 3 && version.minor >= 8 || version.major > 3
    }

    /// Runs a process and returns its standard output as a string. For short, non-streaming commands.
    private func runProcess(executableURL: URL, arguments: [String]) async throws -> String {
        let process = Process()
        // Do not assign to self.currentProcess for these short-lived, non-cancellable-externally processes

        process.executableURL = executableURL
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        logger.debug("Running command: \(executableURL.path) \(arguments.joined(separator: " "))")

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { terminatedProcess in
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

                if terminatedProcess.terminationStatus == 0 {
                    logger.debug("Command finished successfully. Output (first 200 chars): \(output.prefix(200))...")
                    continuation.resume(returning: output)
                } else {
                    logger.error("Command failed with status \(terminatedProcess.terminationStatus). Stderr: \(errorOutput)")
                    continuation.resume(throwing: OrchestrationError.processExecutionFailed(
                        command: "\(executableURL.lastPathComponent) \(arguments.joined(separator: " "))",
                        exitCode: terminatedProcess.terminationStatus,
                        standardError: errorOutput
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                logger.error("Failed to run process \(executableURL.path): \(error.localizedDescription)")
                continuation.resume(throwing: OrchestrationError.processExecutionFailed(
                    command: "\(executableURL.lastPathComponent) \(arguments.joined(separator: " "))",
                    exitCode: -1, // Indicate launch failure
                    standardError: error.localizedDescription
                ))
            }
        }
    }
    
    /// Runs a process and streams its standard output and standard error line by line.
    /// This version is for tasks that might be cancelled via `cancelCurrentTask()`.
    private func runProcessStreaming(
        executableURL: URL,
        arguments: [String],
        outputHandler: @escaping (String, Bool) -> Void // String is line, Bool is isStdErr
    ) async throws {
        let process = Process()
        self.currentProcess = process // Assign to instance variable for external cancellation

        process.executableURL = executableURL
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var accumulatedStdErr = "" // To capture full stderr for error reporting

        // Handle STDOUT
        outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if let lineStream = String(data: data, encoding: .utf8) { // Don't trim newlines here, split later
                 DispatchQueue.main.async { // Ensure UI updates (via progressUpdate) are on main thread
                    lineStream.split(separator: "\n", omittingEmptySubsequences: false).forEach { subLine in
                        // Pass each line (even if empty if that's how stream works)
                        outputHandler(String(subLine), false)
                    }
                }
            }
        }

        // Handle STDERR
        errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if let errorStream = String(data: data, encoding: .utf8) {
                 DispatchQueue.main.async {
                    errorStream.split(separator: "\n", omittingEmptySubsequences: false).forEach { subLine in
                        let strSubLine = String(subLine)
                        outputHandler(strSubLine, true) // Mark as stderr
                        accumulatedStdErr += strSubLine + "\n" // Accumulate for error reporting
                    }
                }
            }
        }
        
        logger.debug("Running streaming command: \(executableURL.path) \(arguments.joined(separator: " "))")

        return try await withTaskCancellationHandler { // Handles cancellation of this async function
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { terminatedProcess in
                    // Ensure handlers are nilled out to stop further processing
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    
                    // Process any final data that might have arrived just before termination
                    let finalOutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    if !finalOutData.isEmpty, let finalOut = String(data: finalOutData, encoding: .utf8) {
                        DispatchQueue.main.async {
                            finalOut.split(separator: "\n", omittingEmptySubsequences: false).forEach { outputHandler(String($0), false) }
                        }
                    }
                    let finalErrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    if !finalErrData.isEmpty, let finalErr = String(data: finalErrData, encoding: .utf8) {
                         DispatchQueue.main.async {
                            finalErr.split(separator: "\n", omittingEmptySubsequences: false).forEach {
                                let strSubLine = String($0)
                                outputHandler(strSubLine, true)
                                accumulatedStdErr += strSubLine + "\n" // Ensure all stderr is captured
                            }
                        }
                    }

                    if terminatedProcess.terminationStatus == 0 {
                        logger.debug("Streaming command finished successfully.")
                        continuation.resume(returning: ())
                    } else {
                        // If the task was cancelled (currentProcess became nil), it's not necessarily an error from the script itself.
                        if self.currentProcess == nil && terminatedProcess.terminationReason == .exit && terminatedProcess.terminationStatus != 0 {
                             logger.warning("Streaming command terminated with non-zero status (\(terminatedProcess.terminationStatus)) but might have been cancelled by the app. Accumulated Stderr: \(accumulatedStdErr.prefix(500))")
                             continuation.resume(throwing: OrchestrationError.cancelled) // Or a more specific error
                        } else {
                            logger.error("Streaming command failed with status \(terminatedProcess.terminationStatus). Accumulated Stderr: \(accumulatedStdErr.prefix(500))")
                            continuation.resume(throwing: OrchestrationError.processExecutionFailed(
                                command: "\(executableURL.lastPathComponent) \(arguments.joined(separator: " "))",
                                exitCode: terminatedProcess.terminationStatus,
                                standardError: accumulatedStdErr.isEmpty ? "Process exited non-zero." : accumulatedStdErr
                            ))
                        }
                    }
                    // Clear currentProcess if it's this one that terminated
                    if self.currentProcess == terminatedProcess { self.currentProcess = nil }
                }

                do {
                    try process.run()
                } catch {
                    logger.error("Failed to run streaming process \(executableURL.path): \(error.localizedDescription)")
                    // Ensure handlers are nilled out on launch failure too
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: OrchestrationError.processExecutionFailed(
                        command: "\(executableURL.lastPathComponent) \(arguments.joined(separator: " "))",
                        exitCode: -1, // Indicate launch failure
                        standardError: error.localizedDescription
                    ))
                    if self.currentProcess == process { self.currentProcess = nil } // Clear if it's this one
                }
            }
        } onCancel: { // This is for withTaskCancellationHandler
             // This block is called if the Task wrapping withCheckedThrowingContinuation is cancelled.
             logger.info("Streaming process task cancelled. Interrupting process (PID: \(process.processIdentifier)).")
             process.interrupt() // Attempt graceful shutdown
             // Nilling out currentProcess here ensures the terminationHandler knows it was a cancellation.
             if self.currentProcess == process { self.currentProcess = nil }
        }
    }
}

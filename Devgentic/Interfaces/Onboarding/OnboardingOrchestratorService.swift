////
////  OnboardingOrchestratorService.swift
////  Devgentic
////
////  Created by Raj Singh on 19/05/25.
////  Updated for modular Python agent.
////
//
//import Foundation
//import Combine
//import os
//import System
//
//private let logger = DGLogger(category: "OnboardingOrchestrator")
//
//enum OrchestrationError: LocalizedError {
//    case pythonNotInstalled
//    case pythonVersionTooLow(foundVersion: String)
//    case homebrewNotInstalled
//    case processExecutionFailed(command: String, exitCode: Int32, standardError: String)
//    case virtualEnvironmentCreationFailed
//    case requirementsInstallationFailed
//    case scriptNotFound(scriptName: String) // Keep for requirements.txt, local.py etc.
//    case agentPackageNotFound(packageName: String) // For the devgentic_agent package
//    case ollamaAppInstallFailed
//    case ollamaModelDownloadFailed
//    case agentLaunchFailed(reason: String)
//    case agentDidNotReportURL
//    case agentDidNotReportPID
//    case unexpectedOutput(output: String)
//    case adminPrivilegeRequiredButNotHandled
//    case adminCommandParseFailed
//    case cancelled
//    case generic(message: String)
//    case pythonPathError
//    case resourcePathError
//
//    var errorDescription: String? {
//        switch self {
//        case .pythonNotInstalled:
//            return "Python 3.8+ is not installed. Please install it and try again."
//        case .pythonVersionTooLow(let foundVersion):
//            return "Python version \(foundVersion) is too low. Devgentic requires Python 3.8+."
//        case .homebrewNotInstalled:
//            return "Homebrew is not installed. It's needed if you want the app to attempt Python installation."
//        case .processExecutionFailed(let command, let exitCode, let stdErr):
//            return "Command '\(command)' failed with exit code \(exitCode). Error: \(stdErr.isEmpty ? "No specific error output." : stdErr)"
//        case .virtualEnvironmentCreationFailed:
//            return "Failed to create the Python virtual environment 'devgentic'."
//        case .requirementsInstallationFailed:
//            return "Failed to install Python dependencies from requirements.txt."
//        case .scriptNotFound(let scriptName):
//            return "Required script '\(scriptName)' was not found in the app bundle."
//        case .agentPackageNotFound(let packageName):
//            return "Required Python agent package '\(packageName)' not found in app bundle resources."
//        case .ollamaAppInstallFailed:
//            return "Failed to install the Ollama application."
//        case .ollamaModelDownloadFailed:
//            return "Failed to download the Ollama model."
//        case .agentLaunchFailed(let reason):
//            return "Failed to launch the Devgentic agent: \(reason)"
//        case .agentDidNotReportURL:
//            return "Agent launched but did not report its operational URL."
//        case .agentDidNotReportPID:
//            return "Agent launched but did not report its Process ID."
//        case .unexpectedOutput(let output):
//            return "Received unexpected output: \(output)"
//        case .adminPrivilegeRequiredButNotHandled:
//            return "Admin privilege was required by the script, but the command details could not be parsed or handled."
//        case .adminCommandParseFailed:
//            return "Failed to parse the admin command from the script's output."
//        case .cancelled:
//            return "The setup process was cancelled."
//        case .generic(let message):
//            return message
//        case .pythonPathError:
//            return "Could not determine a valid Python executable path."
//        case .resourcePathError:
//            return "Could not determine the application's resource path."
//        }
//    }
//}
//
//struct PythonCheckResult {
//    let isInstalled: Bool
//    let version: String?
//    let path: String?
//}
//
//struct AgentLaunchResult {
//    let url: URL
//    let pid: Int32
//    let venvPythonPathUsed: String // Also return the python path used for AgentManager
//}
//
//struct AdminCommandPayload: Decodable {
//    let command: [String]
//}
//
//private let PRIVILEGE_ESCALATION_MARKER = "###REQUIRES_ELEVATED_PRIVILEGES###"
//
//class OnboardingOrchestratorService {
//
//    private var currentProcess: Process?
//    private let venvName = "devgentic"
//    private let defaultOllamaModel = "gemma:2b"
//    private let agentPackageName = "devgentic_agent" // The Python package folder name
//
//    private func getSystemPythonPath() async throws -> String {
//        logger.info("Attempting to determine system Python 3 path...")
//        let pythonCheck = try await checkPythonInstallation()
//        guard pythonCheck.isInstalled, let path = pythonCheck.path else {
//            logger.error("System Python 3 not found or is not valid based on checkPythonInstallation.")
//            throw OrchestrationError.pythonPathError
//        }
//        logger.info("Determined system Python 3 path: \(path)")
//        return path
//    }
//
//    public func checkPythonInstallation() async throws -> PythonCheckResult {
//        logger.info("Checking Python installation...")
//        do {
//            let whichPythonPath = try await runProcess(executableURL: URL(fileURLWithPath: "/usr/bin/which"), arguments: ["python3"])
//            let pythonPath = whichPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
//
//            if pythonPath.isEmpty || pythonPath.contains("not found") {
//                logger.warning("Python 3 not found via 'which python3'.")
//                return PythonCheckResult(isInstalled: false, version: nil, path: nil)
//            }
//            logger.info("Python 3 potentially found at: \(pythonPath)")
//
//            let versionOutput = try await runProcess(executableURL: URL(fileURLWithPath: pythonPath), arguments: ["--version"])
//            let versionString = versionOutput.trimmingCharacters(in: .whitespacesAndNewlines)
//            
//            if let version = parsePythonVersion(versionString) {
//                logger.info("Python version: \(versionString)")
//                if isVersionSufficient(version) {
//                    return PythonCheckResult(isInstalled: true, version: versionString, path: pythonPath)
//                } else {
//                    logger.error("Python version \(versionString) is insufficient. Requires 3.8+.")
//                    throw OrchestrationError.pythonVersionTooLow(foundVersion: versionString)
//                }
//            } else {
//                logger.error("Could not parse Python version from output: \(versionString)")
//                throw OrchestrationError.unexpectedOutput(output: versionString)
//            }
//        } catch let error as OrchestrationError {
//            throw error
//        } catch {
//            logger.error("Failed to check Python installation due to an unexpected error: \(error.localizedDescription)")
//            throw OrchestrationError.processExecutionFailed(command: "/usr/bin/which python3", exitCode: -1, standardError: error.localizedDescription)
//        }
//    }
//
//    public func installPythonViaHomebrew(progressUpdate: @escaping (String) -> Void) async throws {
//        logger.info("Attempting to install Python via Homebrew...")
//        progressUpdate("Checking for Homebrew...")
//
//        guard let brewPath = try? await runProcess(executableURL: URL(fileURLWithPath: "/usr/bin/which"), arguments: ["brew"]).trimmingCharacters(in: .whitespacesAndNewlines),
//              !brewPath.isEmpty, !brewPath.contains("not found") else {
//            logger.error("Homebrew not found.")
//            progressUpdate("Error: Homebrew not found. Please install Homebrew first.")
//            throw OrchestrationError.homebrewNotInstalled
//        }
//        logger.info("Homebrew found at: \(brewPath)")
//        progressUpdate("Homebrew found. Starting Python installation (this may take several minutes)...")
//
//        do {
//            try await runProcessStreaming(
//                executableURL: URL(fileURLWithPath: brewPath),
//                arguments: ["install", "python"],
//                outputHandler: { line, isStdErr in
//                    progressUpdate(line)
//                    if isStdErr { logger.error("[Brew Install Python STDERR]: \(line)") }
//                    else { logger.debug("[Brew Install Python STDOUT]: \(line)") }
//                }
//            )
//            progressUpdate("Python installation via Homebrew completed. Please re-check Python status.")
//            logger.info("Python installation via Homebrew appears to have completed.")
//        } catch {
//            progressUpdate("Error during Homebrew Python installation: \(error.localizedDescription)")
//            logger.error("Failed to install Python via Homebrew: \(error.localizedDescription)")
//            if let orchError = error as? OrchestrationError { throw orchError }
//            throw OrchestrationError.generic(message: "Failed to install Python using Homebrew: \(error.localizedDescription)")
//        }
//    }
//
//    public func setupPythonVirtualEnvironment(pythonExecutablePath: String, progressUpdate: @escaping (String) -> Void) async throws -> URL {
//        logger.info("Setting up Python virtual environment '\(self.venvName)' using Python at \(pythonExecutablePath)...")
//        progressUpdate("Creating virtual environment '\(venvName)'...")
//
//        let fileManager = FileManager.default
//        guard let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
//            logger.error("Could not find Application Support directory.")
//            throw OrchestrationError.generic(message: "Could not find Application Support directory.")
//        }
//
//        let appSpecificSupportDir = appSupportDir.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.devgentic", isDirectory: true)
//        try fileManager.createDirectory(at: appSpecificSupportDir, withIntermediateDirectories: true, attributes: nil)
//        
//        let venvDir = appSpecificSupportDir.appendingPathComponent(venvName, isDirectory: true)
//        logger.info("Virtual environment will be created at: \(venvDir.path)")
//
//        if fileManager.fileExists(atPath: venvDir.path) {
//            logger.info("Removing existing virtual environment at \(venvDir.path)")
//            progressUpdate("Removing old virtual environment...")
//            try fileManager.removeItem(at: venvDir)
//        }
//
//        do {
//            try await runProcessStreaming(
//                executableURL: URL(fileURLWithPath: pythonExecutablePath),
//                arguments: ["-m", "venv", venvDir.path],
//                outputHandler: { line, isStdErr in
//                    progressUpdate(line)
//                    if isStdErr { logger.error("[Venv Create STDERR]: \(line)") }
//                }
//            )
//            progressUpdate("Virtual environment created.")
//            logger.info("Virtual environment '\(self.venvName)' created successfully.")
//        } catch {
//            progressUpdate("Error creating virtual environment: \(error.localizedDescription)")
//            logger.error("Failed to create virtual environment: \(error.localizedDescription)")
//            throw OrchestrationError.virtualEnvironmentCreationFailed
//        }
//
//        let venvPythonPath = venvDir.appendingPathComponent("bin/python").path
//        guard fileManager.fileExists(atPath: venvPythonPath) else {
//            logger.error("Python executable not found in the newly created venv: \(venvPythonPath)")
//            throw OrchestrationError.virtualEnvironmentCreationFailed
//        }
//
//        guard let requirementsPath = Bundle.main.path(forResource: "requirements", ofType: "txt") else {
//            logger.error("requirements.txt not found in app bundle.")
//            throw OrchestrationError.scriptNotFound(scriptName: "requirements.txt")
//        }
//        logger.info("Installing dependencies from: \(requirementsPath) into \(self.venvName)")
//        progressUpdate("Installing Python dependencies...")
//
//        do {
//            try await runProcessStreaming(
//                executableURL: URL(fileURLWithPath: venvPythonPath),
//                arguments: ["-m", "pip", "install", "-r", requirementsPath],
//                outputHandler: { line, isStdErr in
//                    progressUpdate(line)
//                    if isStdErr { logger.error("[Pip Install STDERR]: \(line)") }
//                }
//            )
//            progressUpdate("Dependencies installed successfully.")
//            logger.info("Successfully installed dependencies from requirements.txt into \(self.venvName).")
//            return URL(fileURLWithPath: venvPythonPath)
//        } catch {
//            progressUpdate("Error installing dependencies: \(error.localizedDescription)")
//            logger.error("Failed to install dependencies: \(error.localizedDescription)")
//            throw OrchestrationError.requirementsInstallationFailed
//        }
//    }
//
//    public func installOllamaApplication(
//        progressUpdate: @escaping (String) -> Void,
//        privilegeEscalator: PrivilegeEscalationService
//    ) async throws {
//        logger.info("Starting Ollama application installation process...")
//        progressUpdate("Checking for existing Ollama installation...")
//
//        guard let localPyPath = Bundle.main.path(forResource: "local", ofType: "py") else {
//            logger.error("local.py script not found in bundle.")
//            throw OrchestrationError.scriptNotFound(scriptName: "local.py")
//        }
//
//        let systemPythonPath = try await getSystemPythonPath()
//        
//        logger.info("Using Python at \(systemPythonPath) to run local.py (initial phase for Ollama app).")
//        progressUpdate("Running Ollama setup script (initial phase)...")
//
//        var adminCommandToExecute: AdminCommandPayload? = nil
//        var ollamaAlreadyInstalledByScript = false
//        var privilegeMarkerDetected = false
//
//        do {
//            try await runProcessStreaming(
//                executableURL: URL(fileURLWithPath: systemPythonPath),
//                arguments: [localPyPath, "--phase", "initial"],
//                outputHandler: { line, isStdErr in
//                    progressUpdate(line)
//                    if line.contains("Ollama is already installed.") {
//                        ollamaAlreadyInstalledByScript = true
//                        logger.info("local.py reported Ollama is already installed.")
//                    }
//                    if line.contains(PRIVILEGE_ESCALATION_MARKER) {
//                        privilegeMarkerDetected = true
//                        logger.info("local.py signaled for elevated privileges. Expecting JSON.")
//                    } else if privilegeMarkerDetected, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
//                        if let jsonData = line.data(using: .utf8) {
//                            do {
//                                adminCommandToExecute = try JSONDecoder().decode(AdminCommandPayload.self, from: jsonData)
//                                logger.info("Parsed admin command from local.py: \(adminCommandToExecute?.command.joined(separator: " ") ?? "nil")")
//                            } catch {
//                                logger.error("Failed to parse admin command JSON '\(line)': \(error.localizedDescription)")
//                            }
//                        }
//                        privilegeMarkerDetected = false // Reset after processing the line following the marker
//                    }
//                }
//            )
//            logger.info("local.py initial phase completed its execution.")
//            progressUpdate("Ollama setup script (initial phase) finished.")
//
//        } catch let error as OrchestrationError {
//             if ollamaAlreadyInstalledByScript {
//                logger.info("local.py indicated Ollama already installed (caught via OrchestrationError).")
//                progressUpdate("Ollama application is already installed.")
//                return
//            }
//            logger.error("local.py initial phase failed: \(error.localizedDescription)")
//            progressUpdate("Error during Ollama setup (initial phase): \(error.localizedDescription)")
//            throw OrchestrationError.ollamaAppInstallFailed
//        } catch {
//            logger.error("local.py initial phase failed with unexpected error: \(error.localizedDescription)")
//            progressUpdate("Error during Ollama setup (initial phase): \(error.localizedDescription)")
//            throw OrchestrationError.ollamaAppInstallFailed
//        }
//
//        if ollamaAlreadyInstalledByScript {
//            progressUpdate("Ollama application is already installed (as reported by script).")
//            return
//        }
//
//        if let commandPayload = adminCommandToExecute, !commandPayload.command.isEmpty {
//            let commandPath = commandPayload.command.first!
//            let arguments = Array(commandPayload.command.dropFirst())
//            progressUpdate("Ollama installer requires administrator privileges: \(commandPath)")
//            logger.info("Executing Ollama installer with admin privileges: \(commandPath) \(arguments.joined(separator: " "))")
//            
//            let success = await privilegeEscalator.executeWithAdminPrivileges(commandPath: commandPath, arguments: arguments)
//            if success {
//                progressUpdate("Ollama installer executed with admin rights.")
//                logger.info("Privileged command for Ollama installation executed successfully.")
//            } else {
//                progressUpdate("Ollama installer failed or was cancelled by user (admin rights).")
//                logger.error("Privileged command for Ollama installation failed or was cancelled.")
//                throw OrchestrationError.ollamaAppInstallFailed
//            }
//        } else if privilegeMarkerDetected && adminCommandToExecute == nil { // Marker seen, but no command parsed
//            logger.error("Privilege marker was detected from local.py, but a valid admin command was not parsed.")
//            progressUpdate("Error: Script indicated admin rights needed, but command was unclear.")
//            throw OrchestrationError.adminCommandParseFailed
//        } else if !(await isOllamaAppInstalled()) { // No admin command, and not installed
//             logger.warning("local.py finished without errors or admin command, but Ollama.app still not found. Installation might have failed silently or not attempted.")
//             // This might not be an error if local.py determined no action was needed and it wasn't installed.
//             // However, if the goal was installation, this is a failure point.
//             // For now, let's assume if it's not installed after this, it's an issue.
//             throw OrchestrationError.ollamaAppInstallFailed
//        }
//         progressUpdate("Ollama application setup process potentially complete. Verification will occur if model download is triggered.")
//    }
//    
//    public func isOllamaAppInstalled() async -> Bool {
//        let ollamaAppPath = "/Applications/Ollama.app"
//        let isInstalled = FileManager.default.fileExists(atPath: ollamaAppPath)
//        logger.info("Checked for Ollama.app at \(ollamaAppPath). Exists: \(isInstalled)")
//        return isInstalled
//    }
//
//    public func downloadOllamaModel(modelName: String?, progressUpdate: @escaping (String, Double?) -> Void) async throws {
//        let modelToDownload = modelName ?? defaultOllamaModel
//        logger.info("Starting Ollama model download for: \(modelToDownload)")
//        progressUpdate("Preparing to download Ollama model: \(modelToDownload)...", nil)
//
//        guard let localPyPath = Bundle.main.path(forResource: "local", ofType: "py") else {
//            logger.error("local.py script not found in bundle.")
//            throw OrchestrationError.scriptNotFound(scriptName: "local.py")
//        }
//
//        let systemPythonPath = try await getSystemPythonPath()
//
//        logger.info("Using Python at \(systemPythonPath) to run local.py (post-install phase for model: \(modelToDownload)).")
//        
//        let progressRegex = try! NSRegularExpression(pattern: #"\b(\d{1,3})\s*\%"#)
//
//        do {
//            try await runProcessStreaming(
//                executableURL: URL(fileURLWithPath: systemPythonPath),
//                arguments: [localPyPath, "--phase", "post-install", modelToDownload],
//                outputHandler: { line, isStdErr in
//                    var percentage: Double? = nil
//                    if let match = progressRegex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)) {
//                        if let range = Range(match.range(at: 1), in: line),
//                           let percentValue = Int(String(line[range])) {
//                            percentage = Double(percentValue) / 100.0
//                            logger.debug("Parsed Ollama pull progress: \(percentValue)% from line: \(line)")
//                        }
//                    }
//                    progressUpdate(line, percentage) // Pass line and optional percentage
//                    if isStdErr { logger.error("[Ollama Model STDERR]: \(line)")}
//                }
//            )
//            progressUpdate("Ollama model \(modelToDownload) download process finished.", 1.0)
//            logger.info("local.py post-install phase for model \(modelToDownload) completed successfully.")
//        } catch {
//            progressUpdate("Error downloading Ollama model \(modelToDownload): \(error.localizedDescription)", nil)
//            logger.error("local.py post-install phase for model \(modelToDownload) failed: \(error.localizedDescription)")
//            throw OrchestrationError.ollamaModelDownloadFailed
//        }
//    }
//
//    public func launchAgent(venvPythonURL: URL, progressUpdate: @escaping (String) -> Void) async throws -> AgentLaunchResult {
//        logger.info("Launching agent using Python from venv: \(venvPythonURL.path)")
//        progressUpdate("Starting Devgentic agent (modular)...")
//
//        // The `devgentic_agent` package (folder) should be in the app's resources.
//        guard let resourcePathURL = Bundle.main.resourceURL else {
//            logger.error("Application resource path not found. Cannot set working directory for agent.")
//            throw OrchestrationError.resourcePathError
//        }
//        
//        let agentPackageDirURL = resourcePathURL.appendingPathComponent(agentPackageName, isDirectory: true)
//        guard FileManager.default.fileExists(atPath: agentPackageDirURL.path) else {
//            logger.error("Python agent package '\(self.agentPackageName)' not found in bundle resources at \(agentPackageDirURL.path).")
//            throw OrchestrationError.agentPackageNotFound(packageName: agentPackageName)
//        }
//        
//        var agentURLString: String? = nil
//        var agentPIDString: String? = nil
//        let agentURLMarker = "Agent running on:" // This comes from Python's print statement
//        let agentPIDMarker = "Agent PID:"       // This also comes from Python's print statement
//        var agentProcess: Process?
//
//        return try await withTaskCancellationHandler {
//            try await withCheckedThrowingContinuation { continuation in
//                agentProcess = Process()
//                guard let process = agentProcess else {
//                    continuation.resume(throwing: OrchestrationError.generic(message: "Failed to initialize agent process object."))
//                    return
//                }
//                self.currentProcess = process
//
//                process.executableURL = venvPythonURL
//                process.arguments = ["-m", "\(agentPackageName).main"] // Launch as module
//                process.currentDirectoryURL = resourcePathURL // Set CWD to Resources folder
//
//                logger.info("Agent launch: \(venvPythonURL.path) \(process.arguments?.joined(separator: " ") ?? "") in CWD: \(resourcePathURL.path)")
//
//                let outputPipe = Pipe()
//                let errorPipe = Pipe()
//                process.standardOutput = outputPipe
//                process.standardError = errorPipe
//                
//                var accumulatedAgentError = ""
//                var hasResumed = false // Ensure continuation is resumed only once
//
//                outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
//                    let data = fileHandle.availableData
//                    if let lineChunk = String(data: data, encoding: .utf8) {
//                        DispatchQueue.main.async {
//                            guard !hasResumed else { return }
//                            lineChunk.split(separator: "\n").forEach { subLine in
//                                let trimmedLine = String(subLine).trimmingCharacters(in: .whitespacesAndNewlines)
//                                if !trimmedLine.isEmpty {
//                                    progressUpdate(trimmedLine)
//                                    logger.info("[Agent STDOUT]: \(trimmedLine)")
//                                    if trimmedLine.contains(agentURLMarker) {
//                                        agentURLString = trimmedLine.split(separator: agentURLMarker).last?.trimmingCharacters(in: .whitespacesAndNewlines).description
//                                        logger.info("Detected agent URL string: \(agentURLString ?? "nil")")
//                                    }
//                                    if trimmedLine.contains(agentPIDMarker) {
//                                        agentPIDString = trimmedLine.split(separator: agentPIDMarker).last?.trimmingCharacters(in: .whitespacesAndNewlines).description
//                                        logger.info("Detected agent PID string: \(agentPIDString ?? "nil")")
//                                    }
//
//                                    if let urlStr = agentURLString, let url = URL(string: urlStr),
//                                       let pidStr = agentPIDString, let pid = Int32(pidStr) {
//                                        if !hasResumed {
//                                            hasResumed = true
//                                            logger.info("Agent URL and PID successfully parsed. Resuming continuation.")
//                                            continuation.resume(returning: AgentLaunchResult(url: url, pid: pid, venvPythonPathUsed: venvPythonURL.path))
//                                        }
//                                    }
//                                }
//                            }
//                        }
//                    }
//                }
//
//                errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
//                    let data = fileHandle.availableData
//                    if let errorLineChunk = String(data: data, encoding: .utf8) {
//                         DispatchQueue.main.async {
//                            errorLineChunk.split(separator: "\n").forEach { subLine in
//                                 let trimmedLine = String(subLine).trimmingCharacters(in: .whitespacesAndNewlines)
//                                 if !trimmedLine.isEmpty {
//                                    progressUpdate("AGENT_ERROR: \(trimmedLine)")
//                                    logger.error("[Agent STDERR]: \(trimmedLine)")
//                                    accumulatedAgentError += trimmedLine + "\n"
//                                 }
//                            }
//                        }
//                    }
//                }
//
//                process.terminationHandler = { terminatedProcess in
//                    logger.info("Agent process terminated. Status: \(terminatedProcess.terminationStatus), Reason: \(terminatedProcess.terminationReason.rawValue). URL found: \(agentURLString != nil), PID found: \(agentPIDString != nil)")
//                    outputPipe.fileHandleForReading.readabilityHandler = nil
//                    errorPipe.fileHandleForReading.readabilityHandler = nil
//                    
//                    DispatchQueue.main.async { // Ensure continuation is called on main thread if needed, though it's async
//                        if !hasResumed {
//                            hasResumed = true // Mark as resumed to prevent double resume
//                            var reason = "Agent exited prematurely before reporting full details."
//                            if agentURLString == nil && agentPIDString == nil { reason = "Agent did not report URL or PID." }
//                            else if agentURLString == nil { reason = "Agent did not report its URL." }
//                            else if agentPIDString == nil { reason = "Agent did not report its PID." }
//                            
//                            let errorMsg = accumulatedAgentError.isEmpty ? reason : accumulatedAgentError.trimmingCharacters(in: .whitespacesAndNewlines)
//                            logger.error("Agent launch failed before URL/PID capture or due to premature exit: \(errorMsg)")
//                            continuation.resume(throwing: OrchestrationError.processExecutionFailed(
//                                command: "\(self.agentPackageName).main",
//                                exitCode: terminatedProcess.terminationStatus,
//                                standardError: errorMsg
//                            ))
//                        }
//                    }
//                    if self.currentProcess == terminatedProcess { self.currentProcess = nil }
//                }
//
//                do {
//                    logger.info("Attempting to run agent process: \(venvPythonURL.path) -m \(self.agentPackageName).main in CWD: \(resourcePathURL.path)")
//                    try process.run()
//                    logger.info("Agent process launched (OS PID: \(process.processIdentifier)). Waiting for script to report URL and its own PID...")
//                } catch {
//                    logger.error("Failed to run agent process: \(error.localizedDescription)")
//                    if !hasResumed {
//                        hasResumed = true
//                        continuation.resume(throwing: OrchestrationError.agentLaunchFailed(reason: error.localizedDescription))
//                    }
//                    if self.currentProcess == process { self.currentProcess = nil }
//                }
//            }
//        } onCancel: {
//            logger.info("Agent launch task was cancelled. Interrupting agent process (PID: \(agentProcess?.processIdentifier ?? -1)).")
//            agentProcess?.interrupt() // Sends SIGINT
//            // Consider a more forceful termination if interrupt doesn't work after a timeout
//            if self.currentProcess == agentProcess {
//                 self.currentProcess = nil
//            }
//        }
//    }
//
//    public func cancelCurrentTask() {
//        logger.info("Attempting to cancel current process (PID: \(self.currentProcess?.processIdentifier ?? -1)).")
//        currentProcess?.interrupt() // Sends SIGINT
//        // Note: If the process is stuck and doesn't handle SIGINT, it might not terminate.
//        // A more robust cancel might involve a timeout and then currentProcess?.terminate() (SIGTERM).
//        currentProcess = nil
//    }
//
//    private func parsePythonVersion(_ versionString: String) -> (major: Int, minor: Int, patch: Int)? {
//        let components = versionString.split(separator: " ")
//        guard components.count > 1, components[0].lowercased() == "python" else { return nil }
//        
//        let versionParts = components.last!.split(separator: ".").compactMap { Int($0) }
//        guard versionParts.count >= 2 else { return nil }
//
//        return (versionParts[0], versionParts[1], versionParts.count > 2 ? versionParts[2] : 0)
//    }
//
//    private func isVersionSufficient(_ version: (major: Int, minor: Int, patch: Int)) -> Bool {
//        return version.major == 3 && version.minor >= 8 || version.major > 3
//    }
//
//    private func runProcess(executableURL: URL, arguments: [String]) async throws -> String {
//        let process = Process()
//        process.executableURL = executableURL
//        process.arguments = arguments
//
//        let outputPipe = Pipe()
//        let errorPipe = Pipe()
//        process.standardOutput = outputPipe
//        process.standardError = errorPipe
//        
//        logger.debug("Running command: \(executableURL.path) \(arguments.joined(separator: " "))")
//
//        return try await withCheckedThrowingContinuation { continuation in
//            process.terminationHandler = { terminatedProcess in
//                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
//                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
//                let output = String(data: outputData, encoding: .utf8) ?? ""
//                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
//
//                if terminatedProcess.terminationStatus == 0 {
//                    logger.debug("Command finished successfully. Output (first 100 chars): \(output.prefix(100))")
//                    continuation.resume(returning: output)
//                } else {
//                    logger.error("Command failed with status \(terminatedProcess.terminationStatus). Stderr: \(errorOutput)")
//                    continuation.resume(throwing: OrchestrationError.processExecutionFailed(
//                        command: "\(executableURL.lastPathComponent) \(arguments.joined(separator: " "))",
//                        exitCode: terminatedProcess.terminationStatus,
//                        standardError: errorOutput.isEmpty ? "No standard error output." : errorOutput
//                    ))
//                }
//            }
//            do {
//                try process.run()
//            } catch {
//                logger.error("Failed to launch process \(executableURL.path): \(error.localizedDescription)")
//                continuation.resume(throwing: OrchestrationError.processExecutionFailed(
//                    command: "\(executableURL.lastPathComponent) \(arguments.joined(separator: " "))",
//                    exitCode: -1,
//                    standardError: error.localizedDescription
//                ))
//            }
//        }
//    }
//    
//    private func runProcessStreaming(
//        executableURL: URL,
//        arguments: [String],
//        outputHandler: @escaping (String, Bool) -> Void // line, isStdErr
//    ) async throws {
//        let process = Process()
//        self.currentProcess = process // Track the current process for cancellation
//
//        process.executableURL = executableURL
//        process.arguments = arguments
//
//        let outputPipe = Pipe()
//        let errorPipe = Pipe()
//        process.standardOutput = outputPipe
//        process.standardError = errorPipe
//
//        var accumulatedStdErr = "" // To capture stderr for error reporting
//
//        outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
//            let data = fileHandle.availableData
//            if let lineStream = String(data: data, encoding: .utf8) {
//                 DispatchQueue.main.async { // Ensure UI updates on main thread
//                    lineStream.split(separator: "\n", omittingEmptySubsequences: false).forEach { subLine in
//                        outputHandler(String(subLine), false)
//                    }
//                }
//            }
//        }
//
//        errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
//            let data = fileHandle.availableData
//            if let errorStream = String(data: data, encoding: .utf8) {
//                 DispatchQueue.main.async { // Ensure UI updates on main thread
//                    errorStream.split(separator: "\n", omittingEmptySubsequences: false).forEach { subLine in
//                        let strSubLine = String(subLine)
//                        outputHandler(strSubLine, true)
//                        accumulatedStdErr += strSubLine + "\n" // Accumulate for potential error reporting
//                    }
//                }
//            }
//        }
//        
//        logger.debug("Running streaming command: \(executableURL.path) \(arguments.joined(separator: " "))")
//
//        return try await withTaskCancellationHandler {
//            try await withCheckedThrowingContinuation { continuation in
//                process.terminationHandler = { terminatedProcess in
//                    // Ensure handlers are nilled out to stop further processing
//                    outputPipe.fileHandleForReading.readabilityHandler = nil
//                    errorPipe.fileHandleForReading.readabilityHandler = nil
//                    
//                    if terminatedProcess.terminationStatus == 0 {
//                        logger.debug("Streaming command finished successfully.")
//                        continuation.resume(returning: ())
//                    } else {
//                        // Check if cancellation was the reason for termination
//                        // This is a heuristic; `terminatedProcess.terminationReason == .exit` and `self.currentProcess == nil` (due to onCancel)
//                        // might indicate a cancellation path.
//                        let finalErrorMessage = accumulatedStdErr.isEmpty ? "Process exited non-zero with no stderr." : accumulatedStdErr.trimmingCharacters(in: .whitespacesAndNewlines)
//
//                        if self.currentProcess == nil && terminatedProcess.terminationReason == .exit && Task.isCancelled {
//                             logger.warning("Streaming command terminated with status (\(terminatedProcess.terminationStatus)) but task was cancelled. Stderr: \(finalErrorMessage.prefix(500))")
//                             continuation.resume(throwing: OrchestrationError.cancelled)
//                        } else {
//                            logger.error("Streaming command failed with status \(terminatedProcess.terminationStatus). Stderr: \(finalErrorMessage.prefix(500))")
//                            continuation.resume(throwing: OrchestrationError.processExecutionFailed(
//                                command: "\(executableURL.lastPathComponent) \(arguments.joined(separator: " "))",
//                                exitCode: terminatedProcess.terminationStatus,
//                                standardError: finalErrorMessage
//                            ))
//                        }
//                    }
//                    // Clear currentProcess if it's the one that terminated
//                    if self.currentProcess == terminatedProcess { self.currentProcess = nil }
//                }
//
//                do {
//                    try process.run()
//                } catch {
//                    logger.error("Failed to run streaming process \(executableURL.path): \(error.localizedDescription)")
//                    // Nil out handlers immediately on failure to run
//                    outputPipe.fileHandleForReading.readabilityHandler = nil
//                    errorPipe.fileHandleForReading.readabilityHandler = nil
//                    continuation.resume(throwing: OrchestrationError.processExecutionFailed(
//                        command: "\(executableURL.lastPathComponent) \(arguments.joined(separator: " "))",
//                        exitCode: -1, // Indicate launch failure
//                        standardError: error.localizedDescription
//                    ))
//                    if self.currentProcess == process { self.currentProcess = nil }
//                }
//            }
//        } onCancel: {
//             logger.info("Streaming process task was cancelled. Interrupting process (PID: \(process.processIdentifier)).")
//             process.interrupt() // Send SIGINT
//             // If self.currentProcess points to this process, clear it
//             if self.currentProcess == process { self.currentProcess = nil }
//        }
//    }
//}

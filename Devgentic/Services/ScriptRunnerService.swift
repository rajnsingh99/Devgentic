// Services/ScriptRunnerService.swift
import Foundation
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.Devgentic", category: "ScriptRunner")

/// Represents the output or event from a script execution.
enum ScriptOutputEvent: Equatable {
    case log(String)
    case requiresAdmin(commandPath: String, arguments: [String])
    case complete
}

/// Service responsible for running the Python setup script.
struct ScriptRunnerService {

    let scriptName: String = "ollama_setup.py" // Name of your python script in Resources

    /// Runs the Ollama setup script bundled with the application.
    /// - Parameters:
    ///   - models: An array of model names to pass as arguments to the script.
    /// - Returns: A publisher that emits ScriptOutputEvents (log lines, admin requests, completion) or fails with an error.
    func runOllamaSetupScript(models: [String]) -> AnyPublisher<ScriptOutputEvent, Error> {
        // Use Deferred to ensure the setup happens only upon subscription
        return Deferred {
            // Create the subject that will emit events
            let subject = PassthroughSubject<ScriptOutputEvent, Error>()

            // Attempt to setup and run the process, passing the subject
            let setupResult = setupAndRunProcess(models: models, subject: subject)

            // Check if the initial setup failed
            if case .failure(let error) = setupResult {
                // If setup failed immediately, return a publisher that just fails
                return Fail<ScriptOutputEvent, Error>(error: error)
                    .eraseToAnyPublisher()
            } else {
                // If setup succeeded, return the subject which will now receive
                // events from the running process's handlers.
                return subject.eraseToAnyPublisher()
            }
        }
        .eraseToAnyPublisher() // Erase the Deferred type
    }

    // Helper to setup and run process - returns Result to indicate immediate failure
    // It now directly configures the handlers to send events to the provided subject.
    private func setupAndRunProcess(models: [String], subject: PassthroughSubject<ScriptOutputEvent, Error>) -> Result<Void, Error> {
        guard let scriptPath = Bundle.main.path(forResource: scriptName, ofType: nil) else {
            logger.error("Script '\(self.scriptName)' not found in bundle Resources.")
            return .failure(ScriptError.scriptNotFound)
        }
        // Consider more robust python path finding if necessary
        let pythonPath = "/usr/bin/env" // Use env to find python3 in PATH

        logger.info("Running script: \(scriptPath) with models: \(models.joined(separator: ", ")) using \(pythonPath) python3")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        // Arguments for /usr/bin/env: name_of_executable script_path args...
        process.arguments = ["python3", scriptPath] + models

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Read stdout asynchronously
        outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                // Potential EOF, but rely on termination handler
                // outputPipe.fileHandleForReading.readabilityHandler = nil // Removed premature cleanup
            } else if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                 logger.debug("[SCRIPT STDOUT]: \(line)")
                 if let adminRequest = self.parseAdminSignal(line: line) {
                     subject.send(.requiresAdmin(commandPath: adminRequest.path, arguments: adminRequest.args))
                 } else {
                     subject.send(.log(line))
                     // Optional: Check for explicit completion signal from script output
                     // if line == "SETUP_COMPLETE" { subject.send(.complete) }
                 }
            }
        }

        // Read stderr asynchronously
        errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
             let data = fileHandle.availableData
             if data.isEmpty {
                 // Potential EOF
                 // errorPipe.fileHandleForReading.readabilityHandler = nil // Removed premature cleanup
             } else if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                 logger.error("[SCRIPT STDERR]: \(line)")
                 subject.send(.log("⚠️ \(line)"))
             }
        }

        // Process Termination Handler
        process.terminationHandler = { terminatedProcess in
             logger.info("Script process terminated with status: \(terminatedProcess.terminationStatus)")
             // --- CRITICAL: Ensure handlers are nilled out AFTER termination ---
             // It's possible readability handlers are called shortly after termination starts
             // DispatchQueue.main.async ? Maybe not needed. Let's nil them out here.
             outputPipe.fileHandleForReading.readabilityHandler = nil
             errorPipe.fileHandleForReading.readabilityHandler = nil

             if terminatedProcess.terminationStatus == 0 {
                  // Assuming exit code 0 means success if no explicit completion signal used
                  subject.send(.log("Script finished.")) // Log finish before completion event
                  subject.send(.complete) // Signal completion event
                  subject.send(completion: .finished) // Complete the publisher stream
             } else {
                 let reason = terminatedProcess.terminationReason
                 logger.error("Script terminated with non-zero status (\(terminatedProcess.terminationStatus)), reason: \(reason.rawValue)")
                 subject.send(completion: .failure(ScriptError.executionFailed(exitCode: Int(terminatedProcess.terminationStatus))))
             }
        }

        // Launch Process
        do {
            try process.run()
            logger.info("Script process launched successfully (PID: \(process.processIdentifier)).")
            return .success(()) // Indicate immediate launch success
        } catch {
            logger.error("Failed to launch script process: \(error.localizedDescription)")
            subject.send(completion: .failure(error)) // Ensure subject completes on launch failure too
            return .failure(error)
        }
    }


    /// Parses a line to check if it matches the admin signal format.
    /// Expected format: "NEEDS_ADMIN:<command_path> <arg1> <arg2>..."
    private func parseAdminSignal(line: String) -> (path: String, args: [String])? {
        let prefix = "NEEDS_ADMIN:"
        guard line.hasPrefix(prefix) else { return nil }

        let commandString = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        // Simple split based on space for demo. Real script should ensure args are quoted if they contain spaces.
        var components = commandString.split(separator: " ", maxSplits: 1).map(String.init)

        guard let commandPath = components.first, !commandPath.isEmpty else {
            logger.error("Could not parse command path from admin signal: \(line)")
            return nil
        }

        let argumentsString = components.count > 1 ? components[1] : ""
        // Re-splitting arguments string - assumes simple space separation from script
        let arguments = argumentsString.split(separator: " ").map(String.init)

        logger.info("Parsed admin signal: command='\(commandPath)', args=\(arguments)")
        return (commandPath, arguments)
    }

    enum ScriptError: LocalizedError {
        case scriptNotFound
        case executionFailed(exitCode: Int)

        var errorDescription: String? {
            switch self {
            case .scriptNotFound:
                return "The setup script '\(ScriptRunnerService().scriptName)' was not found in the application bundle's Resources."
            case .executionFailed(let exitCode):
                return "The setup script failed with exit code \(exitCode)."
            }
        }
    }
}
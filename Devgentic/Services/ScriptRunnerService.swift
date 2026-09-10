// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
// Services/ScriptRunnerService.swift
import Foundation
import Combine
import os

private let logger = DGLogger(category: "ScriptRunner")

/// Represents the output or event from a script execution phase.
enum ScriptOutputEvent: Equatable {
    /// A standard log line from stdout or stderr.
    case log(String)
    /// Script signaled that Ollama is already installed (during initial phase).
    case alreadyInstalled
    /// Script requires admin privilege for the command described in the JSON payload (from initial phase).
    case requiresAdmin(commandJson: String)
    /// The script process for the *current phase* completed successfully (exit code 0).
    case phaseComplete
}

/// Service responsible for running the Python setup script in phases.
struct ScriptRunnerService {

    // Assumes your script is named setup_ollama.py in Resources
    // Ensure this matches the actual filename in your project.
    let scriptName: String = "local"
    // Specific marker signaling admin rights needed (must match Python script output)
    let adminMarker = "###REQUIRES_ELEVATED_PRIVILEGES###"
    // Specific output signaling Ollama is already installed (must match Python script output)
    let alreadyInstalledMarker = "Ollama is already installed" // Adjust if script uses different text

    /// Runs the Ollama setup script bundled with the application for a specific phase.
    /// - Parameters:
    ///   - models: An array containing the single LLM name (or empty if none selected).
    ///   - phase: The phase argument ("initial" or "post-install").
    /// - Returns: A publisher that emits ScriptOutputEvents or fails with an error.
    func runOllamaSetupScript(models: [String], phase: String) -> AnyPublisher<ScriptOutputEvent, Error> {
        // Use Deferred to ensure the setup happens only upon subscription
        return Deferred {
            let subject = PassthroughSubject<ScriptOutputEvent, Error>()
            // Attempt to setup and run the process, passing the subject to emit events
            let setupResult = setupAndRunProcess(models: models, phase: phase, subject: subject)

            // Check if the initial setup (finding script, preparing Process) failed
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
    // Configures handlers to send events directly to the provided subject.
    private func setupAndRunProcess(models: [String], phase: String, subject: PassthroughSubject<ScriptOutputEvent, Error>) -> Result<Void, Error> {
        guard let scriptPath = Bundle.main.path(forResource: scriptName, ofType: "py") else { // Ensure .py extension is included if present in filename
            logger.error("Script '\(self.scriptName)' not found in bundle Resources.")
            return .failure(ScriptError.scriptNotFound)
        }
        let pythonPath = "/usr/bin/env" // Use env to find python3 in user's PATH

        // Construct arguments: python3 script_path --phase <phase> [model_name]
        var arguments = ["python3", scriptPath, "--phase", phase]
        // Append the single model name if provided (script description implies only one)
        if let modelName = models.first, !modelName.isEmpty {
            arguments.append(modelName)
        }

        logger.info("Running script phase '\(phase)' with arguments: \(arguments.dropFirst().joined(separator: " "))") // Log args excluding python3

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = arguments // Pass full list: interpreter, script, args...

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Need to track if admin signal was detected to handle subsequent JSON line
        var detectedAdminMarker = false
        // Buffer for incomplete lines between data chunks
        var stdoutBuffer = ""
        var stderrBuffer = ""

        // Read stdout asynchronously
        outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty { return } // EOF handled by termination handler

            if let incomingString = String(data: data, encoding: .utf8) {
                stdoutBuffer += incomingString
                // Process complete lines from the buffer
                while let range = stdoutBuffer.range(of: "\n") {
                    let line = String(stdoutBuffer[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    stdoutBuffer.removeSubrange(...range.lowerBound) // Keep remaining part

                    if line.isEmpty { continue } // Skip empty lines

                    logger.debug("[SCRIPT STDOUT - \(phase)]: \(line)")

                    if detectedAdminMarker {
                        // This line should be the JSON command payload
                        subject.send(.requiresAdmin(commandJson: line))
                        detectedAdminMarker = false // Reset marker
                        continue // Don't process this line further
                    }

                    if line.contains(self.adminMarker) {
                        logger.info("Detected admin marker.")
                        subject.send(.log("ℹ️ Setup requires admin privileges..."))
                        detectedAdminMarker = true // Expect next line to be JSON
                        continue // Don't send marker itself as log
                    }

                    if line.contains(self.alreadyInstalledMarker) {
                         logger.info("Detected 'already installed' marker.")
                         subject.send(.log("✅ \(line)")) // Log the message
                         subject.send(.alreadyInstalled) // Send specific event
                         continue // Script might continue or exit, let termination handle completion
                     }

                    // Otherwise, send as normal log
                    subject.send(.log(line))
                }
            }
        }

        // Read stderr asynchronously
        errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
             let data = fileHandle.availableData
             if data.isEmpty { return }

             if let incomingString = String(data: data, encoding: .utf8) {
                 stderrBuffer += incomingString
                 while let range = stderrBuffer.range(of: "\n") {
                     let line = String(stderrBuffer[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                     stderrBuffer.removeSubrange(...range.lowerBound)

                     if line.isEmpty { continue }

                     logger.error("[SCRIPT STDERR - \(phase)]: \(line)")
                     subject.send(.log("⚠️ \(line)")) // Send stderr lines as prefixed logs
                 }
             }
        }

        // Process Termination Handler
        process.terminationHandler = { terminatedProcess in
             logger.info("Script process phase '\(phase)' terminated with status: \(terminatedProcess.terminationStatus)")

             // Process any remaining buffered output/error after termination
             if !stdoutBuffer.isEmpty {
                 let line = stdoutBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                 if !line.isEmpty { subject.send(.log(line)) } // Log remaining stdout
                 stdoutBuffer = ""
             }
             if !stderrBuffer.isEmpty {
                 let line = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                 if !line.isEmpty { subject.send(.log("⚠️ \(line)")) } // Log remaining stderr
                 stderrBuffer = ""
             }

             // Nil out handlers *after* process terminates and buffers are processed
             outputPipe.fileHandleForReading.readabilityHandler = nil
             errorPipe.fileHandleForReading.readabilityHandler = nil

             if terminatedProcess.terminationStatus == 0 {
                  // Exit code 0 means this *phase* completed successfully
                  subject.send(.log("Script phase '\(phase)' finished."))
                  subject.send(.phaseComplete) // Signal phase completion event
                  subject.send(completion: .finished) // Complete the publisher stream for this phase
             } else {
                 let reason = terminatedProcess.terminationReason
                 logger.error("Script phase '\(phase)' terminated with non-zero status (\(terminatedProcess.terminationStatus)), reason: \(reason.rawValue)")
                 // Send failure completion for the publisher stream
                 subject.send(completion: .failure(ScriptError.executionFailed(exitCode: Int(terminatedProcess.terminationStatus), phase: phase)))
             }
        }

        // Launch Process
        do {
            try process.run()
            logger.info("Script process phase '\(phase)' launched successfully (PID: \(process.processIdentifier)).")
            return .success(()) // Indicate immediate launch success
        } catch {
            logger.error("Failed to launch script process phase '\(phase)': \(error.localizedDescription)")
            subject.send(completion: .failure(error)) // Ensure subject completes on launch failure
            return .failure(error)
        }
    }

    // Error enum updated for two-phase context and JSON parsing
    enum ScriptError: LocalizedError {
        case scriptNotFound
        case executionFailed(exitCode: Int, phase: String)
        case jsonParsingFailed(Error)

        var errorDescription: String? {
            switch self {
            case .scriptNotFound:
                // Accessing scriptName directly might not be ideal if service is instantiated multiple times
                // Use a static reference or pass it if needed, hardcoding for now.
                return "The setup script 'local.py' was not found."
            case .executionFailed(let exitCode, let phase):
                return "The setup script phase '\(phase)' failed with exit code \(exitCode)."
            case .jsonParsingFailed(let error):
                return "Failed to parse command from script: \(error.localizedDescription)"
            }
        }
    }
}

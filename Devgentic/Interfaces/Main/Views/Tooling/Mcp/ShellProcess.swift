//
//  ShellProcess.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//

import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic", category: "ShellProcess")

enum ShellProcessError: LocalizedError {
    case processFailedToStart(String)
    case encodingError
    case shellTermination(Int, String) // Exit code, Stderr

    var errorDescription: String? {
        switch self {
        case .processFailedToStart(let msg): return "Failed to start process: \(msg)"
        case .encodingError: return "Could not encode command string."
        case .shellTermination(let code, let msg): return "Process exited with code \(code): \(msg)"
        }
    }
}

class ShellProcess {
    
    let process: Process
    let stdInPipe = Pipe()
    let stdOutPipe = Pipe()
    let stdErrPipe = Pipe()
    
    // Internal buffer to store stderr for post-mortem analysis
    private var capturedStderr: String = ""
    private let stderrQueue = DispatchQueue(label: "com.devgentic.shellprocess.stderr")

    let commandLine: String
    
    init(command: String, arguments: [String], environment: [String: String] = [:]) throws {
        self.process = Process()
        
        // 1. Construct Safe Command
        let safeArgs = arguments.map { arg -> String in
            if arg.contains(" ") && !arg.hasPrefix("\"") && !arg.hasPrefix("'") {
                return "\"\(arg)\""
            }
            return arg
        }
        
        let fullCommandString = ([command] + safeArgs).joined(separator: " ")
        self.commandLine = fullCommandString
        
        // 2. Setup Login Shell
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", fullCommandString]
        
        // 3. Environment Setup & PATH Injection (CRITICAL FIX)
        var mergedEnv = ProcessInfo.processInfo.environment
        
        // Merge provided envs (like API Keys)
        environment.forEach { mergedEnv[$0] = $1 }
        
        if mergedEnv["TERM"] == nil {
            mergedEnv["TERM"] = "xterm-256color"
        }
        
        // FIX: Manually inject common binary locations into PATH.
        // This solves "uvx: command not found" if .zshrc doesn't load correctly in non-interactive mode.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let commonPaths = [
            "\(home)/.cargo/bin",   // Common for uv / rust tools
            "\(home)/.local/bin",   // Common for python tools
            "/opt/homebrew/bin",    // Apple Silicon Homebrew
            "/usr/local/bin",       // Intel Homebrew
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        
        // Get existing PATH, default to empty
        var currentPath = mergedEnv["PATH"] ?? ""
        
        // Prepend missing paths
        for path in commonPaths {
            // Check if path exists before adding to keep PATH clean (optional, but good practice)
            if FileManager.default.fileExists(atPath: path) {
                // Only add if not already present to avoid duplicates
                if !currentPath.contains(path) {
                    currentPath = "\(path):\(currentPath)"
                }
            }
        }
        
        mergedEnv["PATH"] = currentPath
        process.environment = mergedEnv
        
        // 4. Pipe Setup
        process.standardInput = stdInPipe
        process.standardOutput = stdOutPipe
        process.standardError = stdErrPipe
        
        // 5. CRITICAL LOGGING FIX: Real-time Stderr Monitoring
        stdErrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            
            if let str = String(data: data, encoding: .utf8) {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    // Log immediately to Console.app / Xcode
                    logger.error("[STDERR] \(trimmed, privacy: .public)")
                    
                    // Archive it safely
                    self?.stderrQueue.async {
                        self?.capturedStderr += str
                    }
                }
            }
        }
        
        logger.info("Spawning ShellProcess: /bin/zsh -l -c \(fullCommandString, privacy: .public)")
        // Log the constructed PATH for debugging verification
        logger.info("Constructed PATH: \(currentPath, privacy: .public)")
    }
    
    func run() throws {
        do {
            try process.run()
        } catch {
            logger.error("Failed to run process: \(error.localizedDescription)")
            throw ShellProcessError.processFailedToStart(error.localizedDescription)
        }
    }
    
    func terminate() {
        // Remove handler to prevent crashes accessing invalid handles
        stdErrPipe.fileHandleForReading.readabilityHandler = nil
        
        guard process.isRunning else { return }
        process.terminate()
        
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 2.0) { [weak process] in
            guard let proc = process, proc.isRunning else { return }
            logger.warning("Process stuck. Sending SIGKILL.")
            proc.terminate()
        }
    }
    
    /// Returns all standard error output collected so far.
    func readStdErr() -> String {
        return stderrQueue.sync { capturedStderr }
    }
    
    deinit {
        stdErrPipe.fileHandleForReading.readabilityHandler = nil
    }
}

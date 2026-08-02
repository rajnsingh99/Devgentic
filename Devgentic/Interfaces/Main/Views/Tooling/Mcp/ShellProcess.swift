//
//  ShellProcess.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//

import Foundation
import os.log

private let logger = DGLogger(category: "ShellProcess")

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

        // 1. Environment & augmented PATH
        //    Common binary locations are prepended so we can locate `npx`, `uvx`, etc.
        //    when the parent process inherits a minimal PATH.
        var mergedEnv = ProcessInfo.processInfo.environment
        environment.forEach { mergedEnv[$0] = $1 }

        if mergedEnv["TERM"] == nil {
            mergedEnv["TERM"] = "xterm-256color"
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let commonPaths = [
            "\(home)/.cargo/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        var pathComponents = (mergedEnv["PATH"] ?? "").split(separator: ":").map(String.init)
        for path in commonPaths where FileManager.default.fileExists(atPath: path) {
            if !pathComponents.contains(path) {
                pathComponents.insert(path, at: 0)
            }
        }
        let currentPath = pathComponents.joined(separator: ":")
        mergedEnv["PATH"] = currentPath
        process.environment = mergedEnv

        // 2. Resolve executable path WITHOUT shell interpolation.
        //    Passing user-supplied args through `zsh -c "<joined string>"` is a command-injection
        //    vector ($, backticks, ;, |, &, quotes, newlines all get interpreted). We resolve
        //    `command` to an absolute path and exec it directly with `arguments` as an array,
        //    so each element is a literal argv entry — no shell metacharacter parsing.
        let resolvedExecutable = try Self.resolveExecutable(command, augmentedPath: currentPath)

        process.executableURL = URL(fileURLWithPath: resolvedExecutable)
        process.arguments = arguments

        self.commandLine = ([resolvedExecutable] + arguments).joined(separator: " ")

        // 3. Pipe Setup
        process.standardInput = stdInPipe
        process.standardOutput = stdOutPipe
        process.standardError = stdErrPipe

        // 4. Real-time Stderr Monitoring
        stdErrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let str = String(data: data, encoding: .utf8) {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    logger.error("[STDERR] \(trimmed)")
                    self?.stderrQueue.async {
                        self?.capturedStderr += str
                    }
                }
            }
        }

        // MCP server CLIs commonly take secrets as args (`--api-key X`, `TOKEN=X`,
        // `Authorization: Bearer X`). Redact before logging — the live `process.arguments`
        // above still receives the original, unredacted values.
        let redactedArgs = MCPRedaction.redact(arguments: arguments).joined(separator: " ")
        logger.info("Spawning ShellProcess: \(resolvedExecutable) \(redactedArgs)")
        logger.info("Constructed PATH: \(currentPath)")
    }

    /// Resolves `command` to an absolute executable path without going through a shell.
    /// - Absolute paths are validated for executability and returned as-is.
    /// - Tilde paths (`~/foo`) are expanded against the user's home directory.
    /// - Bare names (`npx`, `uvx`) are searched against the augmented PATH.
    /// - Relative paths containing `/` (e.g. `./foo`) are rejected to avoid
    ///   CWD-dependent surprises.
    private static func resolveExecutable(_ command: String, augmentedPath: String) throws -> String {
        let fm = FileManager.default

        if command.hasPrefix("/") {
            guard fm.isExecutableFile(atPath: command) else {
                throw ShellProcessError.processFailedToStart(
                    "Executable not found or not executable: \(command)"
                )
            }
            return command
        }

        if command.hasPrefix("~") {
            let expanded = (command as NSString).expandingTildeInPath
            guard fm.isExecutableFile(atPath: expanded) else {
                throw ShellProcessError.processFailedToStart(
                    "Executable not found or not executable: \(expanded)"
                )
            }
            return expanded
        }

        if command.contains("/") {
            throw ShellProcessError.processFailedToStart(
                "Relative paths are not supported (got '\(command)'). Use an absolute path or a bare command name available on PATH."
            )
        }

        for dir in augmentedPath.split(separator: ":") {
            let candidate = "\(dir)/\(command)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        throw ShellProcessError.processFailedToStart(
            "Command '\(command)' not found in PATH. Ensure it is installed, or provide an absolute path."
        )
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
        process.terminate() // sends SIGTERM

        // Escalate to SIGKILL if the child hasn't exited within 2 seconds.
        // `Process.terminate()` only ever sends SIGTERM, so calling it twice is a no-op
        // — we have to invoke `kill(2)` directly with SIGKILL to guarantee teardown.
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 2.0) { [weak process] in
            guard let proc = process, proc.isRunning else { return }
            logger.warning("Process \(proc.processIdentifier) stuck after SIGTERM. Sending SIGKILL.")
            kill(proc.processIdentifier, SIGKILL)
        }
    }
    
    /// Returns all standard error output collected so far.
    func readStdErr() -> String {
        return stderrQueue.sync { capturedStderr }
    }
    
    deinit {
        stdErrPipe.fileHandleForReading.readabilityHandler = nil

        // Clearing the handler alone used to leave the child running: any ShellProcess
        // dropped without an explicit `terminate()` — an orphan from a failed or
        // superseded connect — survived as a stray npx/uvx process for the rest of the
        // login session. Kill it directly rather than calling `terminate()`, whose
        // SIGKILL escalation schedules work on a deallocated object's behalf.
        guard process.isRunning else { return }
        logger.warning("""
            [SHELL] ShellProcess for '\(commandLine)' deallocated while its child (pid \
            \(process.processIdentifier)) was still running — terminating it here to avoid \
            an orphaned server process.
            """)
        process.terminate()
    }
}

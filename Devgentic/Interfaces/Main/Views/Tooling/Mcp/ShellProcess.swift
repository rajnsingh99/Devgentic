// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ShellProcess.swift
//  Devgentic
//
//  Created by Raj Singh.
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
    
    // Bounded buffer of stderr for post-mortem analysis: a chatty server would otherwise grow it for as long as the app
    // runs. The tail is kept, since what explains a failure is what the server said last.
    private var capturedStderr: String = ""
    private var droppedStderrChars = 0
    private let stderrQueue = DispatchQueue(label: "com.devgentic.shellprocess.stderr")

    /// Ceiling on the retained stderr tail. Comfortably more than a stack trace or the last
    /// few dozen log lines, which is all any consumer of `readStdErr()` displays.
    private static let maxCapturedStderrChars = 16_384

    /// The command line in redacted form, the only form that is ever logged. The live `process.arguments` keeps the real
    /// values (`--api-key X` is a common credential form).
    let commandLine: String

    /// Test seam: when set, receives exactly the line `logStderrLine` would have logged.
    nonisolated(unsafe) static var stderrLogSinkForTesting: (@Sendable (String) -> Void)?

    /// Logs one line of child stderr, redacted via `MCPRedaction.redact(text:)`. Server CLIs echo their configuration
    /// (including a wrong key) to stderr on a failed start, and logs end up in bug-report bundles.
    private static func logStderrLine(_ line: String) {
        // One message for both destinations, so the seam cannot drift from the log.
        let message = "[STDERR] \(MCPRedaction.redact(text: line))"
        if let sink = stderrLogSinkForTesting {
            sink(message)
            return
        }
        logger.error(message)
    }
    
    init(command: String, arguments: [String], environment: [String: String] = [:]) throws {
        self.process = Process()

        // 1. Environment & augmented PATH: common binary locations are prepended so `npx`, `uvx` etc. are found when the
        // parent inherits a minimal PATH.
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

        // 2. Resolve the executable without shell interpolation: `zsh -c "<joined string>"` is a command-injection vector,
        // so exec the absolute path directly with `arguments` as an array of literal argv entries.
        let resolvedExecutable = try Self.resolveExecutable(command, augmentedPath: currentPath)

        process.executableURL = URL(fileURLWithPath: resolvedExecutable)
        process.arguments = arguments

        // Redacted once, here, and reused by the spawn log below — see `commandLine`.
        let redactedArguments = MCPRedaction.redact(arguments: arguments)
        self.commandLine = ([resolvedExecutable] + redactedArguments).joined(separator: " ")

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
                    Self.logStderrLine(trimmed)
                    self?.stderrQueue.async {
                        self?.appendStderr(str)
                    }
                }
            }
        }

        // Container runtimes (`docker`/`podman`) don't inherit this environment: a variable must also be named in the args
        // (`-e KEY`). Warn rather than rewrite the argv.
        Self.warnAboutContainerEnvironment(
            command: command, resolvedExecutable: resolvedExecutable,
            arguments: arguments, environment: environment
        )

        // Server CLIs commonly take secrets as args (`--api-key X`, `TOKEN=X`, `Authorization: Bearer X`); redacted before
        // logging while the live `process.arguments` keeps the originals.
        let redactedArgs = redactedArguments.joined(separator: " ")
        logger.info("Spawning ShellProcess: \(resolvedExecutable) \(redactedArgs)")
        logger.info("Constructed PATH: \(currentPath)")
    }

    /// Container runtimes that start the real process in their own environment namespace.
    private static let containerRuntimes: Set<String> = ["docker", "podman", "nerdctl"]

    /// Warns when an env var was configured for a container runtime but is never named in the arguments, so the value
    /// cannot reach the server inside the container. Conservative: it fires only when the key appears nowhere in the argv
    /// (`-e KEY`, `--env KEY`, `-eKEY`, `--env=KEY=value` all count).
    private static func warnAboutContainerEnvironment(
        command: String,
        resolvedExecutable: String,
        arguments: [String],
        environment: [String: String]
    ) {
        guard !environment.isEmpty else { return }

        let launcher = (resolvedExecutable as NSString).lastPathComponent.lowercased()
        let typed = (command as NSString).lastPathComponent.lowercased()
        guard containerRuntimes.contains(launcher) || containerRuntimes.contains(typed) else { return }

        let unreachable = environment.keys.filter { key in
            !arguments.contains { $0.contains(key) }
        }.sorted()

        guard !unreachable.isEmpty else { return }

        logger.warning("""
            [SHELL] ⚠️ \(unreachable.count) environment variable(s) configured for the container \
            runtime '\(launcher)' are NOT named in its arguments \
            (\(unreachable.joined(separator: ", "))). A container does not inherit this process's \
            environment, so those values will NOT reach the server and it will behave as though \
            they were never set — typically an authentication failure with nothing indicating \
            the cause. Add each one to the arguments as `-e <NAME>` before the image name, \
            which is what published mcpServers blocks do.
            """)
    }

    /// Resolves `command` to an absolute executable path without going through a shell.
    /// Absolute paths are validated for executability; `~` paths expand against home; bare names search the augmented PATH.
    /// Relative paths containing `/` (e.g. `./foo`) are rejected to avoid CWD-dependent surprises.
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

        // Escalate to SIGKILL if the child hasn't exited within 2 seconds: `Process.terminate()` only sends SIGTERM, so
        // calling it twice is a no-op and `kill(2)` must be invoked directly.
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 2.0) { [weak process] in
            guard let proc = process, proc.isRunning else { return }
            logger.warning("Process \(proc.processIdentifier) stuck after SIGTERM. Sending SIGKILL.")
            kill(proc.processIdentifier, SIGKILL)
        }
    }
    
    /// Appends to the bounded stderr tail. Must be called on `stderrQueue`.
    private func appendStderr(_ chunk: String) {
        capturedStderr += chunk
        guard capturedStderr.count > Self.maxCapturedStderrChars else { return }

        let overflow = capturedStderr.count - Self.maxCapturedStderrChars
        capturedStderr = String(capturedStderr.suffix(Self.maxCapturedStderrChars))
        let wasAlreadyTrimming = droppedStderrChars > 0
        droppedStderrChars += overflow

        // Say it once, not on every chunk: the fact worth recording is that trimming started, and `readStdErr` names the
        // running total.
        if !wasAlreadyTrimming {
            logger.warning("""
                [SHELL] stderr from '\(commandLine)' passed \(Self.maxCapturedStderrChars) chars \
                and is now retained as a rolling TAIL. Earlier output is dropped from the buffer \
                — it is still in the log above, but a connect failure will quote only the most \
                recent \(Self.maxCapturedStderrChars) chars.
                """)
        }
    }

    /// Returns the retained standard-error tail, prefixed with a marker when earlier output
    /// was dropped — so a caller quoting this can never present a partial buffer as complete.
    func readStdErr() -> String {
        return stderrQueue.sync {
            guard droppedStderrChars > 0 else { return capturedStderr }
            return "… [\(droppedStderrChars) earlier characters of server output dropped]\n" + capturedStderr
        }
    }
    
    deinit {
        stdErrPipe.fileHandleForReading.readabilityHandler = nil

        // Kill the child directly rather than calling `terminate()`, whose SIGKILL escalation schedules work on a
        // deallocated object's behalf; clearing the handler alone would leave an orphaned npx/uvx process.
        guard process.isRunning else { return }
        logger.warning("""
            [SHELL] ShellProcess for '\(commandLine)' deallocated while its child (pid \
            \(process.processIdentifier)) was still running — terminating it here to avoid \
            an orphaned server process.
            """)
        process.terminate()
    }
}

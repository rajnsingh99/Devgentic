// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
    
    // Internal buffer to store stderr for post-mortem analysis.
    //
    // BOUNDED, and it has to be: this only ever grew. stderr is the only channel a stdio MCP
    // server may use for human output, so a server that logs normally — the reference server
    // logs on every request — accumulated here for as long as the app ran, with nothing
    // reading it unless a failure happened to occur. A server left connected all day was a
    // slow leak nobody would attribute to logging.
    //
    // The TAIL is kept rather than the head: this buffer exists for post-mortem, and what
    // explains a failure is what the server said last, not what it said at startup.
    private var capturedStderr: String = ""
    private var droppedStderrChars = 0
    private let stderrQueue = DispatchQueue(label: "com.devgentic.shellprocess.stderr")

    /// Ceiling on the retained stderr tail. Comfortably more than a stack trace or the last
    /// few dozen log lines, which is all any consumer of `readStdErr()` displays.
    private static let maxCapturedStderrChars = 16_384

    /// The command line in REDACTED form — the only form that is ever logged. Register KC-16.
    ///
    /// This string exists to be quoted in log lines (the stderr-trim warning, the deinit warning),
    /// and it used to hold the raw argv while the spawn line 130 lines below it was carefully
    /// redacted. `--api-key X` is the common published form for a local MCP server's credential, so
    /// the key travelled into the unified log and from there into every bug-report bundle. The live
    /// `process.arguments` keeps the real values; nothing else does.
    let commandLine: String

    /// ⚠️ TEST SEAM. When set, receives exactly the line `logStderrLine` would have logged, so a
    /// test can drive a real child process and assert on the text as it would appear in the log.
    nonisolated(unsafe) static var stderrLogSinkForTesting: (@Sendable (String) -> Void)?

    /// Logs one line of child stderr, REDACTED. Register KC-17.
    ///
    /// Server CLIs echo their effective configuration to stderr on a failed start — including the
    /// key that was wrong — and this was the one consumer of those bytes that did not run
    /// `MCPRedaction.redact(text:)` first: `MCPClientService` redacts the same buffer at all three
    /// places it quotes `readStdErr()`. The log is what a bug-report bundle carries, and a bug
    /// report is what gets pasted into a public issue.
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

        // ⚠️ A CONTAINER runtime does not inherit this process's environment.
        //
        // For `npx`/`uvx` the child inherits `mergedEnv` and an env var configured by the
        // user simply arrives. For `docker`/`podman` the env is set on the CLI, which then
        // starts a container in its own namespace — the variable reaches the client and stops
        // there. The convention every published `mcpServers` block uses is to name it in the
        // args as well (`"args": [… "-e", "GITHUB_TOKEN", "mcp/github"]`), which tells docker
        // to forward the value it can see.
        //
        // Without that the credential vanishes between the form and the server, and the
        // failure is a bare authentication error inside a container with nothing pointing at
        // the cause. Same class as the pasted-`env` bug: a secret silently discarded in
        // transit. Warn rather than rewrite the argv — guessing where `-e` belongs in someone
        // else's command line is how you break a working configuration.
        Self.warnAboutContainerEnvironment(
            command: command, resolvedExecutable: resolvedExecutable,
            arguments: arguments, environment: environment
        )

        // MCP server CLIs commonly take secrets as args (`--api-key X`, `TOKEN=X`,
        // `Authorization: Bearer X`). Redacted before logging — the live `process.arguments`
        // above still receives the original, unredacted values.
        let redactedArgs = redactedArguments.joined(separator: " ")
        logger.info("Spawning ShellProcess: \(resolvedExecutable) \(redactedArgs)")
        logger.info("Constructed PATH: \(currentPath)")
    }

    /// Container runtimes that start the real process in their own environment namespace.
    private static let containerRuntimes: Set<String> = ["docker", "podman", "nerdctl"]

    /// Warns when an env var was configured for a CONTAINER runtime but is never named in the
    /// arguments, so the value cannot reach the server inside the container.
    ///
    /// Deliberately conservative: it only fires when the key appears NOWHERE in the argv, so
    /// `-e KEY`, `--env KEY`, `-eKEY` and `--env=KEY=value` all count as named. A false
    /// warning about a working configuration would be worse than none.
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
    
    /// Appends to the bounded stderr tail. Must be called on `stderrQueue`.
    private func appendStderr(_ chunk: String) {
        capturedStderr += chunk
        guard capturedStderr.count > Self.maxCapturedStderrChars else { return }

        let overflow = capturedStderr.count - Self.maxCapturedStderrChars
        capturedStderr = String(capturedStderr.suffix(Self.maxCapturedStderrChars))
        let wasAlreadyTrimming = droppedStderrChars > 0
        droppedStderrChars += overflow

        // Say it once, not on every chunk: past the cap this fires continuously for a chatty
        // server, and the fact worth recording is that trimming STARTED. `readStdErr` names
        // the running total, so nothing is lost by staying quiet afterwards.
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

//
//  ShellSessionManager.swift
//  Devgentic
//
//  Created by Raj Singh on 10/02/26.
//  PATCHED: Updated output footer to clearly distinguish Shell PWD from Command Output.
//

import Foundation
import os

/// Manages "Virtual" Shell Sessions by tracking the Current Working Directory (CWD)
/// for each conversation. This avoids the memory overhead and complexity of maintaining
/// live 'zsh' process handles while still allowing agents to 'cd' around.
actor ShellSessionManager {

    static let shared = ShellSessionManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ShellSessionManager")

    // Maps ConversationID -> Current Directory Path
    private var sessionCWDs: [UUID: String] = [:]

    // Safety: Track running processes to kill them on app termination
    private var activeProcesses: [Process] = []

    private init() {}
    
    /// Executes a command within the context of the conversation's current directory.
    /// Safely handles directory changes ('cd') by persisting the new path.
    func execute(command: String, conversationID: UUID) async throws -> String {
        
        // 1. Resolve Context
        // FIX: Default to User Home (~/) instead of App Bundle/Root.
        var cwd = FileManager.default.homeDirectoryForCurrentUser.path
        
        if let savedCWD = sessionCWDs[conversationID] {
            cwd = savedCWD
        }
        
        // 2. Safety & Timeout Setup
        // Phase 10: Token-aware blocking to prevent false positives on non-interactive invocations
        // (e.g. `python3 script.py`, `node index.js`, `topology` containing "top").
        let trimmedCmd = command.trimmingCharacters(in: .whitespaces)
        let firstToken = trimmedCmd.components(separatedBy: .whitespaces).first ?? ""
        let hasArgs = trimmedCmd.components(separatedBy: .whitespaces).count > 1

        // Always-interactive: block regardless of arguments
        let alwaysInteractive: Set<String> = ["nano", "vim", "vi", "emacs", "top", "htop", "less", "more"]
        if alwaysInteractive.contains(firstToken) {
            return "Error: Interactive command '\(firstToken)' is blocked. Use non-interactive alternatives (e.g., 'cat' instead of 'less')."
        }

        // REPL commands: only block when invoked without arguments (interactive REPL mode)
        let replCommands: Set<String> = ["python", "python3", "node", "irb", "ruby", "swift"]
        if replCommands.contains(firstToken) && !hasArgs {
            return "Error: Running '\(firstToken)' in REPL mode is blocked. Pass a script file or use the -c flag (e.g., 'python3 -c \"print(1)\"')."
        }

        // Exact pattern blocks for interactive sudo sessions
        let blockedPatterns = ["sudo -s", "sudo su", "sudo -i"]
        if blockedPatterns.contains(where: { trimmedCmd.hasPrefix($0) }) {
            return "Error: Interactive sudo sessions are blocked."
        }
        
        // 3. Construct "Stateful" Command
        let pwdMarker = "---CWD_MARKER---"
        let chainedCommand = "cd \"\(cwd)\" && \(command) && echo '\(pwdMarker)' && pwd"
        
        // 4. Execution
        let output = try await runZshProcess(chainedCommand)
        
        // 5. Parse New State (CWD)
        var cleanOutput = output
        
        if output.contains(pwdMarker) {
            let components = output.components(separatedBy: pwdMarker)
            if components.count >= 2 {
                cleanOutput = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let newCWD = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !newCWD.isEmpty && FileManager.default.fileExists(atPath: newCWD) {
                    sessionCWDs[conversationID] = newCWD
                }
            }
        }
        
        // 6. Format Output
        let finalCWD = self.getCWD(for: conversationID)
        let displayOutput = cleanOutput.isEmpty ? "(Success)" : cleanOutput
        
        // FIX: Renamed footer to 'Shell PWD' to prevent Agent hallucinating that this path is the result of the tool action
        return "\(displayOutput)\n\n[Shell PWD: \(finalCWD)]"
    }
    
    /// Called by AppDelegate when the application terminates.
    func cleanup() {
        logger.info("Cleaning up ShellSessionManager...")
        
        // Terminate any commands currently running (e.g., long greps)
        let count = activeProcesses.count
        for process in activeProcesses {
            if process.isRunning {
                process.terminate()
            }
        }
        activeProcesses.removeAll()
        
        // Clear state
        sessionCWDs.removeAll()
        logger.info("Shell cleanup complete. Terminated \(count) active processes.")
    }
    
    private func getCWD(for id: UUID) -> String {
        return sessionCWDs[id] ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
    
    private func trackProcess(_ process: Process) {
        activeProcesses.append(process)
    }

    private func untrackProcess(_ process: Process) {
        if let index = activeProcesses.firstIndex(of: process) {
            activeProcesses.remove(at: index)
        }
    }

    private func runZshProcess(_ command: String) async throws -> String {
        // We capture 'self' strongly here, which is fine because ShellSessionManager is a singleton.
        let process = Process()
        let pipe = Pipe()

        process.standardOutput = pipe
        process.standardError = pipe
        process.arguments = ["-c", command]
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

        // Environment setup
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        process.environment = env

        // TRACK PROCESS (actor-isolated)
        trackProcess(process)

        // Run the blocking process work on a detached task
        nonisolated(unsafe) let detachedProcess = process
        nonisolated(unsafe) let detachedPipe = pipe
        let result: String = try await Task.detached(priority: .userInitiated) {
            try detachedProcess.run()

            // Phase 10: Removed the 30s hard kill. Shell commands (git clone, find,
            // large builds, etc.) can legitimately exceed 30s. The cognitive loop's
            // task cancellation and maxIterations cap are the real safety nets.
            // Process cleanup on app termination is handled by cleanup().
            detachedProcess.waitUntilExit()

            let data = detachedPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.value

        // UNTRACK PROCESS ON EXIT (actor-isolated)
        untrackProcess(process)

        return result
    }
}

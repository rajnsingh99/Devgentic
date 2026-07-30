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
/// Tool-level shell failures. These THROW rather than returning a string because
/// `TerminalTool` sets `outputMayContainErrorText`, which switches off
/// `ToolExecutionMediator`'s output sniffing entirely — so for this tool a returned string can
/// NEVER be classified as a failure, whatever it says. Throwing is the only channel left.
///
/// Classifies as `.executionThrew`: a soft failure, so the model sees the error and may retry
/// and the tool is not banned by Ghost Protocol.
enum ShellSessionError: Error, LocalizedError {
    /// The command was refused before any process ran — interactive programs, bare REPLs,
    /// interactive sudo. A refusal is a TOOL failure, not a command result.
    case blocked(reason: String)

    var errorDescription: String? {
        switch self {
        case .blocked(let reason): return reason
        }
    }
}

actor ShellSessionManager {

    static let shared = ShellSessionManager()
    private let logger = DGLogger(category: "ShellSessionManager")

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
            throw ShellSessionError.blocked(reason: "Error: Interactive command '\(firstToken)' is blocked. Use non-interactive alternatives (e.g., 'cat' instead of 'less').")
        }

        // REPL commands: only block when invoked without arguments (interactive REPL mode)
        let replCommands: Set<String> = ["python", "python3", "node", "irb", "ruby", "swift"]
        if replCommands.contains(firstToken) && !hasArgs {
            throw ShellSessionError.blocked(reason: "Error: Running '\(firstToken)' in REPL mode is blocked. Pass a script file or use the -c flag (e.g., 'python3 -c \"print(1)\"').")
        }

        // Exact pattern blocks for interactive sudo sessions
        let blockedPatterns = ["sudo -s", "sudo su", "sudo -i"]
        if blockedPatterns.contains(where: { trimmedCmd.hasPrefix($0) }) {
            throw ShellSessionError.blocked(reason: "Error: Interactive sudo sessions are blocked.")
        }
        
        // 3. Construct "Stateful" Command
        //
        // This is the ONE place a shell command string is still built by interpolation, and it
        // is deliberate: `execute_shell` exists to run the caller's shell command, so `command`
        // reaching a shell IS the feature, not an injection. Every other tool that did this
        // (`glob_files`, `git_tool`, `get_file_hash`, `xcode_orchestrator`) was interpolating
        // model-supplied values into a shell it never meant to expose, and moved to argv.
        //
        // `cwd` is this session's own tracked directory, read back from a previous `pwd`, and
        // `pwdMarker` is a constant — neither is caller-controlled. A sweep for interpolated
        // command strings will land here; that is expected, and converting it to argv would
        // remove the tool's purpose.
        let pwdMarker = "---CWD_MARKER---"
        let chainedCommand = "cd \"\(cwd)\" && \(command) && echo '\(pwdMarker)' && pwd"
        
        // 4. Execution
        let (output, exitCode) = try await runZshProcess(chainedCommand)
        
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
        let displayOutput = cleanOutput.isEmpty
            ? (exitCode == 0 ? "(Success)" : "(no output)")
            : cleanOutput

        // FIX: Renamed footer to 'Shell PWD' to prevent Agent hallucinating that this path is the result of the tool action
        guard exitCode != 0 else {
            return "\(displayOutput)\n\n[Shell PWD: \(finalCWD)]"
        }

        // The chained command is `cd … && <cmd> && echo MARKER && pwd`, so `&&` short-circuits
        // on failure and the process status IS the command's own exit code. Surfaced the same
        // way `batch_command` surfaces it, because until now nothing read it at all: a build
        // that failed and a build that passed produced identical, indistinguishable results.
        //
        // Deliberately NOT thrown. A non-zero exit is frequently a RESULT, not a failure —
        // `grep` exits 1 for "no match", `diff` for "files differ" — and throwing would count
        // those against the circuit breaker. See the architecture reference for the remaining
        // gap this leaves.
        logger.info("[SHELL] Command exited \(exitCode) — annotated onto the output by ShellExitStatus, so the model reads 'Exit code:' in this turn's observation, ActiveStreamManager parses it into ToolExecutionData.exitCode, and EpisodicHistoryFormatter re-emits it as exit=\"N\" on later turns. The tool call itself still classifies as SUCCESS (a non-zero exit is often a result, not a failure), but the verdict now survives the turn.")
        return ShellExitStatus.annotate("\(displayOutput)\n\n[Shell PWD: \(finalCWD)]", exitCode: exitCode)
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

    private func runZshProcess(_ command: String) async throws -> (output: String, exitCode: Int32) {
        // We capture 'self' strongly here, which is fine because ShellSessionManager is a singleton.
        let process = Process()
        // No pipes assigned here: `ProcessRunner` installs and owns its own pair, so anything
        // set now is replaced and only misleads the next reader.
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
        let result: (output: String, exitCode: Int32) = try await Task.detached(priority: .userInitiated) {
            // This was the last hand-rolled subprocess read in the app. It drained before
            // waiting, so it was safe from the 64 KB buffer deadlock — but it still finished on
            // EOF, and EOF waits for every holder of the write end. `execute_shell` runs
            // arbitrary agent-authored commands, so `npm run dev &` or any backgrounded
            // daemon wedged this call for the descendant's entire lifetime, with NO timeout
            // to break it (Phase 10 removed the 30s kill deliberately, and correctly — a git
            // clone legitimately exceeds it). `ProcessRunner` finishes when the CHILD is
            // reaped instead, which bounds the call without bounding the command.
            //
            // Still unbounded on purpose: no `timeout:` here. Cancellation and the loop's
            // iteration cap remain the safety nets for a genuinely long command.
            let run = try ProcessRunner.run(detachedProcess)

            // `combinedOutput` rather than one shared pipe. The old single-pipe setup
            // interleaved the streams and left the model unable to tell which was which; this
            // labels the stderr section. Interleaving cannot be preserved with two pipes, and
            // labelling is the more useful of the two — the whole exit-code effort was about
            // making failure legible.
            var text = run.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !run.outputComplete {
                text += "\n\n[note] This command left a background process holding its output stream. "
                    + "Reading stopped when the command itself finished, so anything written after that is NOT shown above, "
                    + "and the background process loses its output stream. Redirect it to keep its output: `cmd > log 2>&1 &`."
            }
            return (text, run.exitCode)
        }.value

        // UNTRACK PROCESS ON EXIT (actor-isolated)
        untrackProcess(process)

        return result
    }
}

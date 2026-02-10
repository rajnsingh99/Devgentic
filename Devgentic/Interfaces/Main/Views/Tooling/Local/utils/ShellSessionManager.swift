//
//  ShellSessionManager.swift
//  Devgentic
//
//  Created by Raj Singh on 10/02/26.
//

import Foundation
import os

/// Manages "Virtual" Shell Sessions by tracking the Current Working Directory (CWD)
/// for each conversation. This avoids the memory overhead and complexity of maintaining
/// live 'zsh' process handles while still allowing agents to 'cd' around.
final class ShellSessionManager: @unchecked Sendable {
    
    static let shared = ShellSessionManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ShellSessionManager")
    
    // Maps ConversationID -> Current Directory Path
    private var sessionCWDs: [UUID: String] = [:]
    
    // Safety: Track running processes to kill them on app termination
    private var activeProcesses: [Process] = []
    
    private let lock = NSLock()
    
    private init() {}
    
    /// Executes a command within the context of the conversation's current directory.
    /// Safely handles directory changes ('cd') by persisting the new path.
    func execute(command: String, conversationID: UUID) async throws -> String {
        
        // 1. Resolve Context
        // FIX: Default to User Home (~/) instead of App Bundle/Root.
        var cwd = FileManager.default.homeDirectoryForCurrentUser.path
        
        lock.lock()
        if let savedCWD = sessionCWDs[conversationID] {
            cwd = savedCWD
        }
        lock.unlock()
        
        // 2. Safety & Timeout Setup
        let blockedCommands = ["nano", "vim", "emacs", "top", "htop", "sudo -s", "python", "node", "less", "more"]
        if blockedCommands.contains(where: { command.contains($0) }) {
             return "Error: Interactive commands are blocked. Use non-interactive alternatives."
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
                    lock.lock()
                    sessionCWDs[conversationID] = newCWD
                    lock.unlock()
                }
            }
        }
        
        // 6. Format Output
        let finalCWD = self.getCWD(for: conversationID)
        let displayOutput = cleanOutput.isEmpty ? "(Success)" : cleanOutput
        
        return "\(displayOutput)\n\n[Current Directory: \(finalCWD)]"
    }
    
    /// Called by AppDelegate when the application terminates.
    func cleanup() {
        lock.lock()
        defer { lock.unlock() }
        
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
        lock.lock()
        defer { lock.unlock() }
        return sessionCWDs[id] ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
    
    private func runZshProcess(_ command: String) async throws -> String {
        // We capture 'self' strongly here, which is fine because ShellSessionManager is a singleton.
        return try await Task.detached(priority: .userInitiated) {
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
            
            // TRACK PROCESS
            self.lock.lock()
            self.activeProcesses.append(process)
            self.lock.unlock()
            
            defer {
                // UNTRACK PROCESS ON EXIT
                self.lock.lock()
                if let index = self.activeProcesses.firstIndex(of: process) {
                    self.activeProcesses.remove(at: index)
                }
                self.lock.unlock()
            }
            
            try process.run()
            
            // Timeout (30s)
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                if process.isRunning { process.terminate() }
            }
            
            process.waitUntilExit()
            timeoutTask.cancel()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.value
    }
}

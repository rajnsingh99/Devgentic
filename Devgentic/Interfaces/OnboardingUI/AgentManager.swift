//
//  AgentManager.swift
//  Devgentic
//
//  Created by Raj Singh on 19/05/25.
//

import Foundation
import AppKit // For NSApplicationDelegate notifications like willTerminate
import Combine
import os

@MainActor
class AgentManager: ObservableObject {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic", category: "AgentManager")

    @Published var agentStatus: AgentStatus = .stopped
    @Published var agentLog: [String] = [] // For displaying agent's runtime logs if needed

    enum AgentStatus: String {
        case starting = "Starting..."
        case running = "Running"
        case stopping = "Stopping..."
        case stopped = "Not Running"
        case failed = "Failed/Crashed"
        case unknown = "Unknown" // e.g., PID exists but health check fails
    }

    private var agentProcess: Process?
    private var agentPID: Int32? {
        didSet {
            UserDefaults.standard.set(agentPID, forKey: SettingsKeys.agentPID) // Save PID
        }
    }
    private var agentURL: URL?
    private var venvPythonPath: String?

    private var healthCheckTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        loadAgentDetails()
        // Listen for app termination to stop the agent
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.stopAgent(reason: "Application will terminate")
            }
            .store(in: &cancellables)
    }

    private func loadAgentDetails() {
        self.agentPID = UserDefaults.standard.object(forKey: SettingsKeys.agentPID) as? Int32
        if let urlString = UserDefaults.standard.string(forKey: SettingsKeys.agentBaseURL) {
            self.agentURL = URL(string: urlString)
        }
        // Path to venv python is needed to restart the agent.
        // This should be saved during onboarding.
        // For now, let's assume it's derivable or saved.
        // A robust way is to save it in UserDefaults during onboarding.
        // Example: self.venvPythonPath = UserDefaults.standard.string(forKey: SettingsKeys.venvPythonPath)
        
        // For demonstration, let's construct a potential path. This needs to be reliable.
        if let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let venvDir = appSupportDir.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.devgentic", isDirectory: true).appendingPathComponent("devgentic", isDirectory: true)
            self.venvPythonPath = venvDir.appendingPathComponent("bin/python").path
        }


        Self.logger.info("Loaded agent details - PID: \(self.agentPID ?? -1), URL: \(self.agentURL?.absoluteString ?? "nil")")
        
        // Initial status check
        if let pid = self.agentPID, isProcessRunning(pid: pid) {
            // PID exists and process is running, but is it our agent?
            // Perform a health check to confirm.
            Task { await performHealthCheck(showInitialStatus: true) }
        } else if self.agentPID != nil && self.agentPID != 0 {
            // PID was saved, but process is not running.
            Self.logger.info("Agent PID \(self.agentPID!) was found in UserDefaults, but process is not running. Marking as stopped/failed.")
            self.agentStatus = .failed // Or .stopped, depending on desired UX
            self.agentPID = nil // Clear invalid PID
        } else {
            self.agentStatus = .stopped
        }
    }

    func startAgentIfNeeded() {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.isOnboardingComplete) else {
            Self.logger.info("Onboarding not complete, not starting agent.")
            agentStatus = .stopped
            return
        }

        if let pid = agentPID, isProcessRunning(pid: pid) {
            Self.logger.info("Agent process (PID: \(pid)) is already believed to be running. Verifying with health check.")
            Task { await performHealthCheck() }
            return
        }
        
        // If PID is nil or process not running, try to start.
        Self.logger.info("Attempting to start agent.")
        guard let pythonPath = venvPythonPath, FileManager.default.fileExists(atPath: pythonPath) else {
            Self.logger.error("Virtual environment Python path not found or not set: \(self.venvPythonPath ?? "nil"). Cannot start agent.")
            agentStatus = .failed
            appendLog("Error: Python environment not found. Agent cannot start.")
            return
        }
        guard let agentScriptPath = Bundle.main.path(forResource: "agent_launcher", ofType: "py") else {
            Self.logger.error("agent_launcher.py script not found in bundle. Cannot start agent.")
            agentStatus = .failed
            appendLog("Error: Agent script not found. Agent cannot start.")
            return
        }

        agentStatus = .starting
        appendLog("Starting Devgentic agent...")

        agentProcess = Process()
        agentProcess?.executableURL = URL(fileURLWithPath: pythonPath)
        agentProcess?.arguments = [agentScriptPath]

        // Setup pipes to capture output if desired for live logging
        let outputPipe = Pipe()
        agentProcess?.standardOutput = outputPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                DispatchQueue.main.async {
                    self?.appendLog("[AGENT]: \(line)")
                    // Check for URL and PID from output if this is the first launch after an app restart
                    // and we didn't have them (though PID is usually enough to monitor)
                }
            }
        }
        // Similarly for standardError

        do {
            try agentProcess?.run()
            self.agentPID = agentProcess?.processIdentifier // Store the new PID
            Self.logger.info("Agent process started with PID: \(self.agentPID ?? -1). Will verify with health check.")
            appendLog("Agent process initiated (PID: \(self.agentPID ?? -1)). Waiting for it to become healthy...")
            // Start health checks
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { // Give agent time to start
                self.performHealthCheck()
                self.startHealthCheckTimer()
            }
        } catch {
            Self.logger.error("Failed to start agent process: \(error.localizedDescription)")
            agentStatus = .failed
            appendLog("Error starting agent: \(error.localizedDescription)")
            agentProcess = nil
            agentPID = nil
        }
    }

    func stopAgent(reason: String = "User request") {
        Self.logger.info("Attempting to stop agent (PID: \(self.agentPID ?? -1)). Reason: \(reason)")
        appendLog("Stopping agent (PID: \(self.agentPID ?? -1))... Reason: \(reason)")
        
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil

        guard let pid = agentPID, pid != 0 else {
            Self.logger.info("Agent PID not found or is 0. Agent likely not running.")
            agentStatus = .stopped
            return
        }

        if isProcessRunning(pid: pid) {
            agentStatus = .stopping
            // Send SIGINT (Ctrl+C) first for graceful shutdown
            let killResult = kill(pid, SIGINT)
            if killResult == 0 {
                Self.logger.info("Sent SIGINT to agent process \(pid). Waiting for termination...")
                // Give it a moment to shut down gracefully
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.isProcessRunning(pid: pid) {
                        Self.logger.warning("Agent process \(pid) did not terminate after SIGINT. Sending SIGTERM.")
                        kill(pid, SIGTERM) // Force terminate
                         DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { // Check after SIGTERM
                            if self.isProcessRunning(pid: pid) {
                                Self.logger.error("Agent process \(pid) could not be terminated even with SIGTERM.")
                                self.agentStatus = .unknown // Or .failedToStop
                            } else {
                                Self.logger.info("Agent process \(pid) terminated after SIGTERM.")
                                self.agentStatus = .stopped
                            }
                         }
                    } else {
                        Self.logger.info("Agent process \(pid) terminated gracefully after SIGINT.")
                        self.agentStatus = .stopped
                    }
                    if self.agentStatus == .stopped { self.agentPID = nil } // Clear PID if stopped
                }
            } else {
                Self.logger.error("Failed to send SIGINT to agent process \(pid). Error: \(String(cString: strerror(errno)))")
                // If kill fails, the process might not exist or we don't have permission (unlikely for own child)
                if !isProcessRunning(pid: pid) { // Check if it's already gone
                    self.agentStatus = .stopped
                    self.agentPID = nil
                } else {
                    self.agentStatus = .unknown // Or .failedToStop
                }
            }
        } else {
            Self.logger.info("Agent process \(pid) was not running when stop was requested.")
            agentStatus = .stopped
            self.agentPID = nil // Clear PID if not running
        }
        agentProcess = nil // Clear Process object
    }

    func performHealthCheck(showInitialStatus: Bool = false) {
        guard let url = agentURL?.appendingPathComponent("health") else {
            if showInitialStatus && agentPID != nil && !isProcessRunning(pid: agentPID!) {
                 // If PID was known but process is gone, it failed
                agentStatus = .failed
                Self.logger.warning("Agent URL not set for health check, and process for PID \(self.agentPID!) is gone.")
                self.agentPID = nil // Clear invalid PID
            } else if showInitialStatus {
                agentStatus = .stopped // Or unknown if URL is missing but PID might be valid
                 Self.logger.warning("Agent URL not set for health check.")
            }
            return
        }
        
        // If we have a PID, first check if the process is actually running
        if let pid = agentPID, !isProcessRunning(pid: pid) {
            Self.logger.info("Health check: Process for PID \(pid) is not running. Marking agent as failed/stopped.")
            agentStatus = .failed // Or .stopped
            self.agentPID = nil // Clear invalid PID
            healthCheckTimer?.invalidate() // Stop further checks if process is gone
            return
        }


        Self.logger.debug("Performing health check on: \(url.absoluteString)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5 // Short timeout for health check

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    Self.logger.warning("Health check failed (network error): \(error.localizedDescription)")
                    if self.agentStatus != .starting && self.agentStatus != .stopping { // Don't override transient states
                        // If we thought it was running, but health check fails, it's problematic
                        if self.isProcessRunning(pid: self.agentPID ?? 0) {
                             self.agentStatus = .unknown // Process running, but not responding
                        } else {
                             self.agentStatus = .failed // Process likely crashed
                             self.agentPID = nil
                        }
                    }
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    Self.logger.warning("Health check failed (status code: \((response as? HTTPURLResponse)?.statusCode ?? -1)).")
                     if self.agentStatus != .starting && self.agentStatus != .stopping {
                        if self.isProcessRunning(pid: self.agentPID ?? 0) {
                             self.agentStatus = .unknown
                        } else {
                             self.agentStatus = .failed
                             self.agentPID = nil
                        }
                    }
                    return
                }

                // Optional: Parse response data for more detailed status
                if let data = data, let jsonData = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                     Self.logger.info("Health check successful. Response: \(jsonData)")
                     if let statusString = jsonData["status"] as? String, statusString == "ok" {
                        self.agentStatus = .running
                     } else {
                        self.agentStatus = .unknown // Healthy response but unexpected content
                     }
                } else {
                    self.agentStatus = .running // Got 200 OK, assume running
                }
                
                // If health check is good, ensure PID matches if possible (more advanced)
                // For now, 200 OK means running.
            }
        }.resume()
    }

    private func startHealthCheckTimer() {
        healthCheckTimer?.invalidate() // Invalidate existing timer
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Self.logger.debug("Periodic health check triggered.")
            self?.performHealthCheck()
        }
        // Perform one immediately too
        performHealthCheck()
    }
    
    private func isProcessRunning(pid: Int32) -> Bool {
        guard pid != 0 else { return false }
        // Using `kill -0 pid` checks if a process with that PID exists and we have permission to signal it.
        // It doesn't actually send a signal if signal number is 0.
        return kill(pid, 0) == 0 || errno != ESRCH // ESRCH means no such process
    }

    private func appendLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(timestamp)] \(message)"
        if agentLog.count > 100 { agentLog.removeFirst(50) } // Keep log size manageable
        agentLog.append(logEntry)
        Self.logger.info("\(message)")
    }

    // Call this if onboarding completes and provides new agent details
    func onboardingDidComplete(agentURL: URL, agentPID: Int32) {
        Self.logger.info("AgentManager notified of onboarding completion. New PID: \(agentPID), URL: \(agentURL.absoluteString)")
        self.agentURL = agentURL
        self.agentPID = agentPID // This will also save to UserDefaults via didSet
        UserDefaults.standard.set(agentURL.absoluteString, forKey: SettingsKeys.agentBaseURL)
        // Assuming venvPythonPath is already set or known by now
        
        // Perform an initial health check and start timer
        performHealthCheck(showInitialStatus: true)
        startHealthCheckTimer()
    }
}

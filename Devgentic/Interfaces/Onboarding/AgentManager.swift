////
////  AgentManager.swift
////  Devgentic
////
////  Created by Raj Singh on 19/05/25.
////
//
//
//import Foundation
//import AppKit
//import Combine
//import os
//
//@MainActor
//class AgentManager: ObservableObject {
//    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic", category: "AgentManager")
//
//    @Published var agentStatus: AgentStatus = .stopped
//    @Published var agentLog: [String] = [] // For displaying agent's runtime logs if needed
//
//    enum AgentStatus: String {
//        case starting = "Starting..."
//        case running = "Running"
//        case stopping = "Stopping..."
//        case stopped = "Not Running"
//        case failed = "Failed/Crashed"
//        case unknown = "Unknown"
//    }
//
//    private var agentProcess: Process?
//    private var agentPID: Int32? {
//        didSet {
//            UserDefaults.standard.set(agentPID, forKey: GlobalConstants.agentPID) // Save PID
//        }
//    }
//    private var agentURL: URL? 
//    private var venvPythonPath: String?
//
//    private var healthCheckTimer: Timer?
//    private var cancellables = Set<AnyCancellable>()
//
//    init() {
//        loadAgentDetails()
//        // Listen for app termination to stop the agent
//        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
//            .sink { [weak self] _ in
//                self?.stopAgent(reason: "Application will terminate")
//            }
//            .store(in: &cancellables)
//    }
//
//    private func loadAgentDetails() {
//        self.agentPID = UserDefaults.standard.object(forKey: GlobalConstants.agentPID) as? Int32
//        if let urlString = UserDefaults.standard.string(forKey: GlobalConstants.agentBaseURL) {
//            self.agentURL = URL(string: urlString)
//        }
//        
//        // Path to venv python is needed to restart the agent.
//        // This should be saved during onboarding.
//        if let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
//            let venvDir = appSupportDir.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.devgentic", isDirectory: true).appendingPathComponent("devgentic", isDirectory: true) // Assuming venv is named "devgentic"
//            self.venvPythonPath = venvDir.appendingPathComponent("bin/python").path
//            // Also save this to UserDefaults if it's reliably determined here or during onboarding
//            // UserDefaults.standard.set(self.venvPythonPath, forKey: GlobalConstants.venvPythonPath)
//        }
//
//
//        Self.logger.info("Loaded agent details - PID: \(self.agentPID ?? -1), URL: \(self.agentURL?.absoluteString ?? "nil"), VenvPython: \(self.venvPythonPath ?? "nil")")
//        
//        // Initial status check
//        if let pid = self.agentPID, isProcessRunning(pid: pid) {
//            Task { await performHealthCheck(showInitialStatus: true) }
//        } else if self.agentPID != nil && self.agentPID != 0 {
//            Self.logger.info("Agent PID \(self.agentPID!) was found in UserDefaults, but process is not running. Marking as stopped/failed.")
//            self.agentStatus = .failed
//            self.agentPID = nil
//        } else {
//            self.agentStatus = .stopped
//        }
//    }
//
//    func startAgentIfNeeded() {
//        guard UserDefaults.standard.bool(forKey: GlobalConstants.isOnboardingComplete) else {
//            Self.logger.info("Onboarding not complete, not starting agent.")
//            agentStatus = .stopped
//            return
//        }
//
//        if let pid = agentPID, isProcessRunning(pid: pid) {
//            Self.logger.info("Agent process (PID: \(pid)) is already believed to be running. Verifying with health check.")
//            Task { await performHealthCheck() }
//            return
//        }
//        
//        Self.logger.info("Attempting to start agent.")
//        guard let pythonPath = venvPythonPath, FileManager.default.fileExists(atPath: pythonPath) else {
//            Self.logger.error("Virtual environment Python path not found or not set: \(self.venvPythonPath ?? "nil"). Cannot start agent.")
//            agentStatus = .failed
//            appendLog("Error: Python environment not found. Agent cannot start.")
//            return
//        }
//        
//        // The `devgentic_agent` package (folder) should be in the app's resources.
//        guard let resourcePath = Bundle.main.resourceURL else {
//            Self.logger.error("Application resource path not found. Cannot set working directory for agent.")
//            agentStatus = .failed
//            appendLog("Error: Application resource path not found.")
//            return
//        }
//        
//        // Check if the devgentic_agent package directory exists in resources
//        let agentPackageDir = resourcePath.appendingPathComponent("devgentic_agent", isDirectory: true)
//        guard FileManager.default.fileExists(atPath: agentPackageDir.path) else {
//            Self.logger.error("Python agent package 'devgentic_agent' not found in bundle resources at \(agentPackageDir.path).")
//            agentStatus = .failed
//            appendLog("Error: Agent package 'devgentic_agent' not found in app resources.")
//            return
//        }
//
//
//        agentStatus = .starting
//        appendLog("Starting Devgentic agent (modular)...")
//
//        agentProcess = Process()
//        agentProcess?.executableURL = URL(fileURLWithPath: pythonPath)
//        // Launch the agent as a module
//        agentProcess?.arguments = ["-m", "devgentic_agent.main"]
//        // Set the working directory to where `devgentic_agent` package can be found by Python's module system
//        agentProcess?.currentDirectoryURL = resourcePath
//
//        Self.logger.info("Agent launch configuration: Python: \(pythonPath), Args: \(self.agentProcess?.arguments?.joined(separator: " ") ?? ""), CWD: \(self.agentProcess?.currentDirectoryURL?.path ?? "nil")")
//
//        let outputPipe = Pipe()
//        agentProcess?.standardOutput = outputPipe
//        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
//            let data = fileHandle.availableData
//            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
//                DispatchQueue.main.async {
//                    self?.appendLog("[AGENT]: \(line)")
//                }
//            }
//        }
//        
//        let errorPipe = Pipe()
//        agentProcess?.standardError = errorPipe
//        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
//            let data = fileHandle.availableData
//            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
//                DispatchQueue.main.async {
//                    self?.appendLog("[AGENT ERR]: \(line)")
//                }
//            }
//        }
//
//
//        do {
//            try agentProcess?.run()
//            self.agentPID = agentProcess?.processIdentifier
//            Self.logger.info("Agent process started with PID: \(self.agentPID ?? -1). Will verify with health check.")
//            appendLog("Agent process initiated (PID: \(self.agentPID ?? -1)). Waiting for it to become healthy...")
//            
//            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { // Increased delay slightly for module loading
//                self.performHealthCheck()
//                self.startHealthCheckTimer()
//            }
//        } catch {
//            Self.logger.error("Failed to start agent process: \(error.localizedDescription)")
//            agentStatus = .failed
//            appendLog("Error starting agent: \(error.localizedDescription)")
//            agentProcess = nil
//            agentPID = nil
//        }
//    }
//
//    func stopAgent(reason: String = "User request") {
//        Self.logger.info("Attempting to stop agent (PID: \(self.agentPID ?? -1)). Reason: \(reason)")
//        appendLog("Stopping agent (PID: \(self.agentPID ?? -1))... Reason: \(reason)")
//        
//        healthCheckTimer?.invalidate()
//        healthCheckTimer = nil
//
//        guard let pid = agentPID, pid != 0 else {
//            Self.logger.info("Agent PID not found or is 0. Agent likely not running.")
//            agentStatus = .stopped
//            return
//        }
//
//        if isProcessRunning(pid: pid) {
//            agentStatus = .stopping
//            let killResult = kill(pid, SIGINT) // SIGINT for graceful shutdown
//            if killResult == 0 {
//                Self.logger.info("Sent SIGINT to agent process \(pid). Waiting for termination...")
//                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
//                    if self.isProcessRunning(pid: pid) {
//                        Self.logger.warning("Agent process \(pid) did not terminate after SIGINT. Sending SIGTERM.")
//                        kill(pid, SIGTERM)
//                         DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
//                            if self.isProcessRunning(pid: pid) {
//                                Self.logger.error("Agent process \(pid) could not be terminated even with SIGTERM.")
//                                self.agentStatus = .unknown
//                            } else {
//                                Self.logger.info("Agent process \(pid) terminated after SIGTERM.")
//                                self.agentStatus = .stopped
//                            }
//                         }
//                    } else {
//                        Self.logger.info("Agent process \(pid) terminated gracefully after SIGINT.")
//                        self.agentStatus = .stopped
//                    }
//                    if self.agentStatus == .stopped { self.agentPID = nil }
//                }
//            } else {
//                Self.logger.error("Failed to send SIGINT to agent process \(pid). Error: \(String(cString: strerror(errno)))")
//                if !isProcessRunning(pid: pid) {
//                    self.agentStatus = .stopped
//                    self.agentPID = nil
//                } else {
//                    self.agentStatus = .unknown
//                }
//            }
//        } else {
//            Self.logger.info("Agent process \(pid) was not running when stop was requested.")
//            agentStatus = .stopped
//            self.agentPID = nil
//        }
//        agentProcess = nil
//    }
//
//    func performHealthCheck(showInitialStatus: Bool = false) {
//        // The agentURL is the base (e.g., http://127.0.0.1:8000)
//        // The health endpoint is now /agent/health
//        guard let baseAgentURL = agentURL else {
//            if showInitialStatus && agentPID != nil && !isProcessRunning(pid: agentPID!) {
//                agentStatus = .failed
//                Self.logger.warning("Agent URL not set for health check, and process for PID \(self.agentPID!) is gone.")
//                self.agentPID = nil
//            } else if showInitialStatus {
//                agentStatus = .stopped
//                 Self.logger.warning("Agent URL not set for health check.")
//            }
//            return
//        }
//        let healthCheckURL = baseAgentURL.appendingPathComponent("agent/health") // Updated path
//        
//        if let pid = agentPID, !isProcessRunning(pid: pid) {
//            Self.logger.info("Health check: Process for PID \(pid) is not running. Marking agent as failed/stopped.")
//            agentStatus = .failed
//            self.agentPID = nil
//            healthCheckTimer?.invalidate()
//            return
//        }
//
//        Self.logger.debug("Performing health check on: \(healthCheckURL.absoluteString)")
//        var request = URLRequest(url: healthCheckURL)
//        request.httpMethod = "GET"
//        request.timeoutInterval = 5
//
//        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
//            DispatchQueue.main.async {
//                guard let self = self else { return }
//
//                if let error = error {
//                    Self.logger.warning("Health check failed (network error): \(error.localizedDescription) for URL: \(healthCheckURL.absoluteString)")
//                    if self.agentStatus != .starting && self.agentStatus != .stopping {
//                        if self.isProcessRunning(pid: self.agentPID ?? 0) {
//                             self.agentStatus = .unknown
//                        } else {
//                             self.agentStatus = .failed
//                             self.agentPID = nil
//                        }
//                    }
//                    return
//                }
//
//                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
//                    Self.logger.warning("Health check failed (status code: \((response as? HTTPURLResponse)?.statusCode ?? -1)) for URL: \(healthCheckURL.absoluteString).")
//                     if self.agentStatus != .starting && self.agentStatus != .stopping {
//                        if self.isProcessRunning(pid: self.agentPID ?? 0) {
//                             self.agentStatus = .unknown
//                        } else {
//                             self.agentStatus = .failed
//                             self.agentPID = nil
//                        }
//                    }
//                    return
//                }
//
//                if let data = data, let jsonData = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
//                     Self.logger.info("Health check successful. Response: \(jsonData)")
//                     // The new health check returns "overall_status"
//                     if let overallStatus = jsonData["overall_status"] as? String, overallStatus == "ok" {
//                        self.agentStatus = .running
//                     } else if let overallStatus = jsonData["overall_status"] as? String, overallStatus == "degraded" {
//                        self.agentStatus = .unknown // Or a new .degraded status
//                        Self.logger.warning("Agent health check reported 'degraded': \(jsonData)")
//                     }
//                     else {
//                        self.agentStatus = .unknown // Healthy response but unexpected content
//                        Self.logger.warning("Agent health check reported unexpected overall_status: \(jsonData)")
//                     }
//                } else {
//                    Self.logger.warning("Health check response was 200 OK, but no parsable JSON data.")
//                    self.agentStatus = .running // Assuming 200 OK means it's at least responsive
//                }
//            }
//        }.resume()
//    }
//
//    private func startHealthCheckTimer() {
//        healthCheckTimer?.invalidate()
//        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
//            Self.logger.debug("Periodic health check triggered.")
//            self?.performHealthCheck()
//        }
//        performHealthCheck()
//    }
//    
//    private func isProcessRunning(pid: Int32) -> Bool {
//        guard pid != 0 else { return false }
//        return kill(pid, 0) == 0 || errno != ESRCH
//    }
//
//    private func appendLog(_ message: String) {
//        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
//        let logEntry = "[\(timestamp)] \(message)"
//        if agentLog.count > 200 { agentLog.removeFirst(100) }
//        agentLog.append(logEntry)
//        Self.logger.info("\(message)")
//    }
//
//    func onboardingDidComplete(agentURL: URL, agentPID: Int32, venvPythonPath: String) {
//        Self.logger.info("AgentManager notified of onboarding completion. New PID: \(agentPID), URL: \(agentURL.absoluteString), VenvPython: \(venvPythonPath)")
//        self.agentURL = agentURL
//        self.agentPID = agentPID
//        self.venvPythonPath = venvPythonPath
//        
//        UserDefaults.standard.set(agentURL.absoluteString, forKey: GlobalConstants.agentBaseURL)
//        UserDefaults.standard.set(venvPythonPath, forKey: GlobalConstants.venvPythonPath)
//        
//        performHealthCheck(showInitialStatus: true)
//        startHealthCheckTimer()
//    }
//}
//

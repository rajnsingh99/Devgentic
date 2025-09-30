import Foundation
import os

class BackendServerManager {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic", category: "BackendServerManager")
    private var serverProcess: Process?

    func start() async {
        // 1. Start the Swift ToolServer first.
        do {
            Self.logger.info("Attempting to start ToolServer...")
            try await ToolServer.shared.start()
            let port = await ToolServer.shared.currentPort()
            Self.logger.info("✅ ToolServer started successfully on port \(port).")
        } catch {
            Self.logger.error("❌ Failed to start ToolServer: \(error.localizedDescription)")
            // If the essential ToolServer fails, we should not proceed.
            return
        }

        // 2. Now that the ToolServer is confirmed running, start the Python backend process.
        Self.logger.info("Proceeding to start the backend server process...")
        
        guard serverProcess == nil else {
            Self.logger.warning("Backend server process is already running or initialized.")
            return
        }

        guard let executableURL = Bundle.main.url(forResource: "DevgenticCore", withExtension: nil) else {
            Self.logger.error("❌ DevgenticCore executable not found in the app bundle.")
            return
        }

        do {
            serverProcess = Process()
            serverProcess?.executableURL = executableURL
            try serverProcess?.run()
            Self.logger.info("✅ Successfully launched DevgenticCore server process.")
            
            // After launching, start checking its health.
            checkHealth()

        } catch {
            Self.logger.error("❌ Failed to run DevgenticCore server process: \(error.localizedDescription)")
            serverProcess = nil
        }
    }

    func stop() async {
        // 1. Stop the Python server process first.
        if let process = serverProcess, process.isRunning {
            Self.logger.info("Shutting down DevgenticCore server process...")
            process.terminate()
            serverProcess = nil
        } else {
            Self.logger.info("Python server process is not running or was already terminated.")
        }
        
        // 2. Trigger a graceful shutdown of the ToolServer.
        Self.logger.info("Shutting down ToolServer gracefully...")
        await ToolServer.shared.stop()
        Self.logger.info("All server processes have been instructed to shut down.")
    }

    private func checkHealth() {
        // Run this check in a background task to avoid blocking the main thread.
        Task {
            // Add an initial delay to give the server process time to launch.
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            let maxRetries = 10 // Increased from 5 to be more patient
            var attempt = 0
            let retryDelay = TimeInterval(2) // 2 seconds

            while attempt < maxRetries {
                attempt += 1
                Self.logger.debug("Attempting health check (\(attempt)/\(maxRetries))...")
                
                guard let url = URL(string: "http://127.0.0.1:8000/") else { return }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 1.0 // Use a short timeout for each attempt

                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                        Self.logger.info("✅ Backend server is up and healthy.")
                        return // Exit the loop on success
                    }
                } catch {
                    Self.logger.warning("Health check failed on attempt \(attempt): \(error.localizedDescription)")
                }

                // Wait before the next retry, but not after the last attempt.
                if attempt < maxRetries {
                    try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                }
            }
             Self.logger.error("❌ Backend server failed to become healthy after \(maxRetries) attempts.")
        }
    }
}


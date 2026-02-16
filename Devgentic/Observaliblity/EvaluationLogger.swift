import Foundation

class EvaluationLogger {
    static let shared = EvaluationLogger()
    
    private var activeSessions: [UUID: AgentSessionMetrics] = [:]
    private let queue = DispatchQueue(label: "com.devgentic.evals")
    
    // MARK: - Time Formatting Helper
    
    /// Converts a time interval into a human-readable string (e.g., "2m 15.5s" or "0.45s").
    private func formatDuration(_ interval: TimeInterval) -> String {
        if interval >= 60 {
            let minutes = Int(interval) / 60
            let seconds = interval.truncatingRemainder(dividingBy: 60)
            return String(format: "%dm %.2fs", minutes, seconds)
        } else {
            return String(format: "%.3fs", interval)
        }
    }
    
    // MARK: - Agent Session Management
    
    func startSession(id: UUID, availableTools: [AgentTool]) {
        queue.async {
            let names = Set(availableTools.map { $0.name })
            // startTime is initialized to Date() by default in the struct
            self.activeSessions[id] = AgentSessionMetrics(sessionID: id, validToolNames: names)
        }
    }
    
    func logStep(id: UUID, log: AgentTraceLog) {
        queue.async {
            guard var metrics = self.activeSessions[id] else { return }
            
            metrics.totalSteps += 1
            
            switch log.state {
            case .acting:
                metrics.toolCalls += 1
                // Check for hallucination or parse error in log.content
                if log.content.contains("Error: Tool") && log.content.contains("not found") {
                    metrics.hallucinatedTools += 1
                }
                if log.content.contains("Error: Invalid JSON format") {
                    metrics.parseErrors += 1
                }
                
            case .observing:
                // Extract tool details from metadata injected by ReActAgentExecutor
                if let toolName = log.metadata?["tool_name"],
                   let successStr = log.metadata?["tool_success"],
                   let success = Bool(successStr) {
                    metrics.executedTools.append((name: toolName, success: success))
                }
                
            case .finalizing:
                metrics.didFinishSuccessfully = true
                
            case .errorRecovery:
                if log.content.contains("Max iterations reached") {
                    metrics.didHitMaxIterations = true
                }
                
            default: break
            }
            
            self.activeSessions[id] = metrics
        }
    }
    
    func endSession(id: UUID) -> AgentSessionMetrics? {
        // Return metrics for analysis/upload
        return queue.sync {
            guard var metrics = activeSessions[id] else { return nil }
            
            // Capture end time
            metrics.endTime = Date()
            
            // Remove from active sessions
            activeSessions.removeValue(forKey: id)
            
            let durationStr = self.formatDuration(metrics.duration)
            
            print("\n========== 🤖 EXECUTOR SPAN [\(metrics.sessionID)] ==========")
            print("Latency:     \(durationStr)")
            print("Steps Taken: \(metrics.totalSteps)")
            print("Tool Calls:  \(metrics.toolCalls)")
            
            // Print Tool Details
            if !metrics.executedTools.isEmpty {
                print("Tools Executed:")
                for (name, success) in metrics.executedTools {
                    print("  - \(name): \(success ? "SUCCESS" : "FAILED")")
                }
            }
            
            if metrics.parseErrors > 0 || metrics.hallucinatedTools > 0 {
                print("Errors:      JSON Parse (\(metrics.parseErrors)) | Hallucinations (\(metrics.hallucinatedTools))")
            }
            
            print("Outcome:     \(metrics.didFinishSuccessfully ? "SUCCESS ✅" : "FAIL ❌")")
            print("========================================================\n")
            
            return metrics
        }
    }
}

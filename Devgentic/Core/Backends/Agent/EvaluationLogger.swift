import Foundation

struct AgentSessionMetrics {
    let sessionID: UUID
    var totalSteps: Int = 0
    var toolCalls: Int = 0
    var parseErrors: Int = 0
    var didFinishSuccessfully: Bool = false
    var didHitMaxIterations: Bool = false
    var hallucinatedTools: Int = 0
    
    // Tools available to the agent (for checking hallucinations)
    let validToolNames: Set<String>
    
    // Time tracking
    let startTime: Date = Date()
    var endTime: Date?
    
    var duration: TimeInterval {
        guard let end = endTime else { return 0 }
        return end.timeIntervalSince(startTime)
    }
}

class EvaluationLogger {
    static let shared = EvaluationLogger()
    
    private var activeSessions: [UUID: AgentSessionMetrics] = [:]
    private let queue = DispatchQueue(label: "com.devgentic.evals")
    
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
            
            let durationStr = String(format: "%.2fs", metrics.duration)
            
            print("--- EVAL REPORT [\(metrics.sessionID)] ---")
            print("Time Taken: \(durationStr)")
            print("Steps: \(metrics.totalSteps) | Tools: \(metrics.toolCalls)")
            print("Parse Errors: \(metrics.parseErrors) | Hallucinations: \(metrics.hallucinatedTools)")
            print("Result: \(metrics.didFinishSuccessfully ? "SUCCESS" : "FAIL")")
            print("-----------------------------------------")
            
            return metrics
        }
    }
}

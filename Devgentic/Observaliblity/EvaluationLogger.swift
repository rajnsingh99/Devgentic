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
        
        Task {
            let eventType: SpanEventType
            var severity: SpanEventSeverity = .info
            
            switch log.state {
            case .thinking: eventType = .thought
            case .acting: eventType = .toolCall
            case .interaction: eventType = .userInteraction
            case .completed: eventType = .stateChange
            case .error: 
                eventType = .error
                severity = .error
            case .idle: eventType = .stateChange
            }
            
            var detailJSON: String? = nil
            if let metadata = log.metadata,
               let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                detailJSON = json
            }
            
            await TraceRecorder.shared.emit(SpanEvent(
                spanID: log.spanID,
                traceID: log.traceID,
                timestamp: log.timestamp,
                eventType: eventType,
                content: TelemetrySanitizer.sanitize(log.content),
                detailJSON: detailJSON.map { TelemetrySanitizer.sanitize($0) },
                severity: severity
            ))
        }
        
        queue.async {
            guard var metrics = self.activeSessions[id] else { return }
            
            metrics.totalSteps += 1
            
            switch log.state {
            case .thinking(let detail):
                if detail == .reasoning || detail == .planning {
                    metrics.totalIterations += 1
                }
                if detail == .finalizing {
                    // The executor reports its honest terminal outcome as metadata.
                    // A bare finalizing event no longer implies success — the old
                    // unconditional `didFinishSuccessfully = true` printed SUCCESS ✅
                    // even when the event's own content said "Task failed".
                    if let outcome = log.metadata?["outcome"] {
                        metrics.reportedOutcome = outcome
                        metrics.didFinishSuccessfully =
                            outcome == ExecutionOutcome.completed.rawValue ||
                            outcome == ExecutionOutcome.completedWithWarnings.rawValue
                    } else {
                        // Legacy behavior for executors that don't report an outcome.
                        metrics.didFinishSuccessfully = true
                    }
                    // Prefer the authoritative loop counter the executor reports on its
                    // terminal finalizing event. The event-derived count drifts: prose
                    // exits emit no .reasoning row (undercount) and throttle-preflight
                    // notices emit an extra one (overcount). The incremental count
                    // remains as fallback for executors that don't report.
                    if let reported = log.metadata?["iterations"], let count = Int(reported), count > 0 {
                        metrics.totalIterations = count
                    } else if metrics.totalIterations == 0 {
                        // Ensure at least 1 iteration is counted when the loop ran
                        // but no .reasoning trace was emitted (e.g., null-termination
                        // on first iteration where the model returned no tool calls).
                        metrics.totalIterations = 1
                    }
                }
                if detail == .errorRecovery {
                    if log.content.contains("Max iterations reached") {
                        metrics.didHitMaxIterations = true
                    }
                }
                // Handle reflecting as the old 'observing' for tool metrics
                if detail == .reflecting {
                    if let toolName = log.metadata?["tool_name"],
                       let successStr = log.metadata?["is_success"], // Corrected from tool_success
                       let success = Bool(successStr) {
                        metrics.executedTools.append((name: toolName, success: success))
                    }
                }
                
            case .acting:
                metrics.toolCalls += 1
                // Check for hallucination or parse error in log.content
                if log.content.contains("Error: Tool") && log.content.contains("not found") {
                    metrics.hallucinatedTools += 1
                }
                if log.content.contains("Error: Invalid JSON format") {
                    metrics.parseErrors += 1
                }
                
            case .interaction:
                // Interactions are new, handle if needed for metrics
                break
                
            case .completed:
                metrics.didFinishSuccessfully = true
                
            case .error:
                break
                
            case .idle:
                break
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
            print("Latency:      \(durationStr)")
            print("Iterations:   \(metrics.totalIterations)")
            print("Trace Events: \(metrics.totalSteps)")
            print("Tool Calls:   \(metrics.toolCalls)")
            
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
            
            let outcomeLabel: String
            if let reported = metrics.reportedOutcome {
                switch reported {
                case ExecutionOutcome.completedWithWarnings.rawValue:
                    outcomeLabel = "PARTIAL ⚠️"  // Completed with tool failures / best-effort
                case ExecutionOutcome.failed.rawValue:
                    outcomeLabel = "FAIL ❌"
                case ExecutionOutcome.cancelled.rawValue:
                    outcomeLabel = "CANCELLED 🚫"
                default:
                    // .completed — keep the zero-tool nuance: a completion that never
                    // executed a tool is worth a second look during testing.
                    outcomeLabel = metrics.toolCalls == 0 ? "PARTIAL ⚠️" : "SUCCESS ✅"
                }
            } else if metrics.didFinishSuccessfully && metrics.toolCalls == 0 {
                outcomeLabel = "PARTIAL ⚠️"  // Completed but no tools executed
            } else if metrics.didFinishSuccessfully {
                outcomeLabel = "SUCCESS ✅"
            } else {
                outcomeLabel = "FAIL ❌"
            }
            print("Outcome:     \(outcomeLabel)")
            print("========================================================\n")
            
            return metrics
        }
    }
}

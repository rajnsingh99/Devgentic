//
//  SupervisorMemoryStrategy.swift
//  Devgentic
//
//  Working memory that tracks worker dispatches, results, and supervisor aggregation state.
//

import Foundation

struct SupervisorMemoryStrategy: WorkingMemoryStrategy {

    // MARK: - State

    private var workerResults: [(role: String, output: String, isSuccess: Bool)] = []
    private var currentPhase: String = "routing"
    private var observations: [String] = []
    private var systemAlerts: [String] = []

    // MARK: - Supervisor Management

    mutating func setPhase(_ phase: String) {
        currentPhase = phase
    }

    mutating func recordWorkerResult(role: String, output: String, isSuccess: Bool) {
        workerResults.append((role: role, output: output, isSuccess: isSuccess))
    }

    // MARK: - WorkingMemoryStrategy Conformance

    mutating func recordObservation(stepId: Int, toolName: String, result: String, artifacts: [MediaArtifact] = []) {
        let truncated = result.count > 500 ? String(result.prefix(500)) + "..." : result
        observations.append("- [Step \(stepId)] \(toolName): \(truncated)")
    }

    mutating func recordSystemAlert(msg: String) {
        systemAlerts.append("- [SYSTEM ALERT] \(msg)")
    }

    func compileForPrompt() -> String {
        var lines: [String] = ["## Supervisor Status: \(currentPhase.capitalized)"]

        if !workerResults.isEmpty {
            for (i, worker) in workerResults.enumerated() {
                let status = worker.isSuccess ? "COMPLETED" : "FAILED"
                let truncated = worker.output.count > 300 ? String(worker.output.prefix(300)) + "..." : worker.output
                lines.append("### Worker \(i + 1) (\(worker.role)) - \(status)")
                lines.append("Output: \(truncated)")
                lines.append("")
            }
        }

        if !observations.isEmpty {
            lines.append("## Active Worker Observations")
            lines.append(contentsOf: observations)
        }

        if !systemAlerts.isEmpty {
            lines.append(contentsOf: systemAlerts)
        }

        return lines.joined(separator: "\n")
    }

    mutating func clear() {
        workerResults.removeAll()
        observations.removeAll()
        systemAlerts.removeAll()
        currentPhase = "routing"
    }
}

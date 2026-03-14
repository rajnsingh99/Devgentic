//
//  PlanMemoryStrategy.swift
//  Devgentic
//
//  Working memory that tracks plan execution state: pending, active, and completed subtasks.
//

import Foundation

struct PlanMemoryStrategy: WorkingMemoryStrategy {

    // MARK: - State

    private(set) var subtasks: [SubTask] = []
    private var currentStepObservations: [String] = []
    private var systemAlerts: [String] = []

    // MARK: - Plan Management

    mutating func loadPlan(_ tasks: [SubTask]) {
        subtasks = tasks
    }

    mutating func markSubtask(at index: Int, status: SubTaskStatus, result: String? = nil) {
        guard subtasks.indices.contains(index) else { return }
        subtasks[index].status = status
        if let result = result {
            subtasks[index].result = result
        }
    }

    // MARK: - WorkingMemoryStrategy Conformance

    mutating func recordObservation(stepId: Int, toolName: String, result: String) {
        let truncated = result.count > 500 ? String(result.prefix(500)) + "..." : result
        currentStepObservations.append("- [Step \(stepId)] \(toolName): \(truncated)")
    }

    mutating func recordSystemAlert(msg: String) {
        systemAlerts.append("- [SYSTEM ALERT] \(msg)")
    }

    func compileForPrompt() -> String {
        var lines: [String] = ["## Execution Plan Progress"]

        for (i, task) in subtasks.enumerated() {
            let status: String
            switch task.status {
            case .completed:
                let summary = task.result.map { " → \(String($0.prefix(200)))" } ?? ""
                status = "[COMPLETED] Step \(i + 1): \(task.description)\(summary)"
            case .inProgress:
                status = "[IN PROGRESS] Step \(i + 1): \(task.description)"
            case .failed:
                let reason = task.result.map { " → \($0)" } ?? ""
                status = "[FAILED] Step \(i + 1): \(task.description)\(reason)"
            case .skipped:
                status = "[SKIPPED] Step \(i + 1): \(task.description)"
            case .pending:
                status = "[PENDING] Step \(i + 1): \(task.description)"
            }
            lines.append("- \(status)")
        }

        if !currentStepObservations.isEmpty {
            lines.append("")
            lines.append("## Current Step Working Memory")
            lines.append(contentsOf: currentStepObservations)
        }

        if !systemAlerts.isEmpty {
            lines.append("")
            lines.append(contentsOf: systemAlerts)
        }

        return lines.joined(separator: "\n")
    }

    mutating func clear() {
        subtasks.removeAll()
        currentStepObservations.removeAll()
        systemAlerts.removeAll()
    }

    mutating func clearCurrentStepObservations() {
        currentStepObservations.removeAll()
        systemAlerts.removeAll()
    }
}

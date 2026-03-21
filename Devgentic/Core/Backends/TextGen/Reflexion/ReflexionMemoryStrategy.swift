//
//  ReflexionMemoryStrategy.swift
//  Devgentic
//
//  Working memory that tracks trial history and self-reflections across retries.
//

import Foundation

struct ReflexionMemoryStrategy: WorkingMemoryStrategy {

    // MARK: - State

    private var trials: [(trialNumber: Int, critique: String, suggestedRevisions: String?)] = []
    private var currentTrialObservations: [String] = []
    private var systemAlerts: [String] = []
    private(set) var currentTrial: Int = 1

    // MARK: - Trial Management

    mutating func addReflection(trial: Int, critique: String, suggestedRevisions: String?) {
        trials.append((trialNumber: trial, critique: critique, suggestedRevisions: suggestedRevisions))
    }

    mutating func startNewTrial() {
        currentTrial += 1
        currentTrialObservations.removeAll()
        systemAlerts.removeAll()
    }

    // MARK: - WorkingMemoryStrategy Conformance

    mutating func recordObservation(stepId: Int, toolCallId: String, toolName: String, result: String, artifacts: [MediaArtifact] = []) {
        let truncated = result.count > 500 ? String(result.prefix(500)) + "..." : result
        currentTrialObservations.append("- [Step \(stepId)] \(toolName) (id: \(toolCallId)): \(truncated)")
    }

    mutating func recordSystemAlert(msg: String) {
        systemAlerts.append("- [SYSTEM ALERT] \(msg)")
    }

    func compileForPrompt() -> String {
        var lines: [String] = []

        if !trials.isEmpty {
            lines.append("## Previous Trial Reflections")
            for trial in trials {
                lines.append("### Trial \(trial.trialNumber) (REFLECTED)")
                lines.append("Critique: \(trial.critique)")
                if let revisions = trial.suggestedRevisions {
                    lines.append("Suggested: \(revisions)")
                }
                lines.append("")
            }
        }

        lines.append("### Trial \(currentTrial) (CURRENT)")
        if currentTrialObservations.isEmpty {
            lines.append("No actions taken yet.")
        } else {
            lines.append("Observations:")
            lines.append(contentsOf: currentTrialObservations)
        }

        if !systemAlerts.isEmpty {
            lines.append(contentsOf: systemAlerts)
        }

        return lines.joined(separator: "\n")
    }

    mutating func clear() {
        trials.removeAll()
        currentTrialObservations.removeAll()
        systemAlerts.removeAll()
        currentTrial = 1
    }
}

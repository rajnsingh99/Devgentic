//
//  TrialStateMutator.swift
//  Devgentic
//
//  Created for Reflexion Architecture.
//  Manages persistent trial state via ContextMemoryManager.
//

import Foundation
import OSLog

private let logState = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "TrialState")

/// Concrete implementation of `TrialStateMutating` using value semantics.
/// Encapsulates all persistent state updates for the Reflexion architecture.
struct TrialStateMutator: TrialStateMutating {

    let conversationID: UUID
    private(set) var currentGraph: ReflexionGraph
    private(set) var currentConstraints: Set<String>

    init(conversationID: UUID, sessionID: String? = nil) {
        self.conversationID = conversationID
        let sid = sessionID ?? conversationID.uuidString
        self.currentGraph = ReflexionGraph(sessionID: sid)
        self.currentConstraints = []
    }

    // MARK: - Trial Lifecycle

    mutating func startNewTrial(goal: String) {
        let trialNumber = currentGraph.trials.count + 1
        logState.info("Starting Reflexion Trial #\(trialNumber) for goal: \(goal)")

        if currentGraph.goal.isEmpty {
            currentGraph.goal = goal
        }

        let newTrial = TrialRecord(trialNumber: trialNumber)
        currentGraph.trials.append(newTrial)
        currentGraph.workingMemory["current_trial"] = "\(trialNumber)"
        currentGraph.workingMemory["phase"] = "EXECUTING"
        saveState()
    }

    mutating func closeTrial(outcome: String, reflection: String, verdict: ReflectionVerdict) {
        guard let idx = currentGraph.trials.indices.last else { return }

        currentGraph.trials[idx].outcome = outcome
        currentGraph.trials[idx].reflection = reflection
        currentGraph.trials[idx].verdict = verdict
        currentGraph.workingMemory["phase"] = verdict == .pass ? "COMPLETED" : "REFLECTING"

        let trialNum = currentGraph.trials[idx].trialNumber
        logState.info("Trial #\(trialNum) closed with verdict: \(verdict.rawValue)")
        saveState()
    }

    // MARK: - Constraints

    mutating func addNegativeConstraint(_ path: String) {
        currentConstraints.insert(path)
        currentGraph.negativeConstraints = Array(currentConstraints)
        saveState()
    }

    // MARK: - Cancellation

    mutating func markAsCancelled() {
        currentGraph.workingMemory["phase"] = "CANCELLED"
        saveState()
    }

    // MARK: - Private Persistence

    private func saveState() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(currentGraph),
           let jsonString = String(data: data, encoding: .utf8) {
            var sessionGraph = ContextMemoryManager.shared.getActiveState(for: conversationID)
            sessionGraph.workingMemory["reflexion_state"] = jsonString
            sessionGraph.negativeConstraints = Array(currentConstraints)
            ContextMemoryManager.shared.updateActiveState(conversationID: conversationID, state: sessionGraph)
        }
    }
}

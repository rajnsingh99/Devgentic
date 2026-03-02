//
//  PlanStateMutator.swift
//  Devgentic
//
//  Created for Plan & Execute Architecture.
//  Manages persistent plan state via ContextMemoryManager.
//

import Foundation
import OSLog

private let logState = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "PlanState")

/// Concrete implementation of `PlanStateMutating` using value semantics.
/// Encapsulates all persistent state updates for the Plan & Execute architecture.
struct PlanStateMutator: PlanStateMutating {

    let conversationID: UUID
    private(set) var currentPlan: PlanGraph
    private(set) var currentConstraints: Set<String>

    init(conversationID: UUID, sessionID: String? = nil) {
        self.conversationID = conversationID
        let sid = sessionID ?? conversationID.uuidString
        self.currentPlan = PlanGraph(sessionID: sid)
        self.currentConstraints = []
    }

    // MARK: - Plan Lifecycle

    mutating func initializePlan(goal: String, steps: [PlanStep]) {
        logState.info("Plan initialized with \(steps.count) steps for goal: \(goal)")
        currentPlan.goal = goal
        currentPlan.steps = steps
        currentPlan.workingMemory["phase"] = "EXECUTING"
        saveState()
    }

    mutating func markStepInProgress(_ index: Int) {
        guard index < currentPlan.steps.count else { return }
        currentPlan.steps[index].status = .inProgress
        currentPlan.workingMemory["current_step"] = "\(index)"
        saveState()
    }

    mutating func markStepCompleted(_ index: Int, outcome: String) {
        guard index < currentPlan.steps.count else { return }
        currentPlan.steps[index].status = .completed
        currentPlan.steps[index].outcome = outcome
        logState.info("Step \(index) completed: \(outcome.prefix(100))")
        saveState()
    }

    mutating func markStepFailed(_ index: Int, reason: String) {
        guard index < currentPlan.steps.count else { return }
        currentPlan.steps[index].status = .failed
        currentPlan.steps[index].outcome = reason
        logState.warning("Step \(index) failed: \(reason)")
        saveState()
    }

    mutating func replacePlan(newSteps: [PlanStep]) {
        currentPlan.replanCount += 1
        // Mark remaining pending steps as skipped
        for i in currentPlan.steps.indices where currentPlan.steps[i].status == .pending {
            currentPlan.steps[i].status = .skipped
        }
        // Append new steps
        currentPlan.steps.append(contentsOf: newSteps)
        let replanNum = currentPlan.replanCount
        logState.info("Plan revised (replan #\(replanNum)). Added \(newSteps.count) new steps.")
        saveState()
    }

    // MARK: - Constraints

    mutating func addNegativeConstraint(_ path: String) {
        currentConstraints.insert(path)
        currentPlan.negativeConstraints = Array(currentConstraints)
        saveState()
    }

    // MARK: - Cancellation

    mutating func markAsCancelled() {
        currentPlan.workingMemory["phase"] = "CANCELLED"
        for i in currentPlan.steps.indices where currentPlan.steps[i].status == .inProgress || currentPlan.steps[i].status == .pending {
            currentPlan.steps[i].status = .skipped
        }
        saveState()
    }

    // MARK: - Private Persistence

    private func saveState() {
        // Serialize PlanGraph and persist via the existing ContextMemoryManager as a SessionGraph-compatible format.
        // We store the plan state in workingMemory for cross-turn persistence.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(currentPlan),
           let jsonString = String(data: data, encoding: .utf8) {
            var sessionGraph = ContextMemoryManager.shared.getActiveState(for: conversationID)
            sessionGraph.workingMemory["plan_state"] = jsonString
            sessionGraph.negativeConstraints = Array(currentConstraints)
            ContextMemoryManager.shared.updateActiveState(conversationID: conversationID, state: sessionGraph)
        }
    }
}

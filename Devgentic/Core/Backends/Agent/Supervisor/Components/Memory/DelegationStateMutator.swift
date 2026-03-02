//
//  DelegationStateMutator.swift
//  Devgentic
//
//  Created for Supervisor Architecture.
//  Manages persistent delegation state via ContextMemoryManager.
//

import Foundation
import OSLog

private let logState = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "DelegationState")

/// Concrete implementation of `DelegationStateMutating` using value semantics.
/// Encapsulates all persistent state updates for the Supervisor architecture.
struct DelegationStateMutator: DelegationStateMutating {

    let conversationID: UUID
    private(set) var currentGraph: SupervisorGraph
    private(set) var currentConstraints: Set<String>

    init(conversationID: UUID, sessionID: String? = nil) {
        self.conversationID = conversationID
        let sid = sessionID ?? conversationID.uuidString
        self.currentGraph = SupervisorGraph(sessionID: sid)
        self.currentConstraints = []
    }

    // MARK: - Delegation Lifecycle

    mutating func initializeDelegation(goal: String, workers: [WorkerAssignment]) {
        logState.info("Delegation initialized with \(workers.count) workers for goal: \(goal)")
        currentGraph.goal = goal
        currentGraph.workers = workers
        currentGraph.workingMemory["phase"] = "DELEGATING"
        saveState()
    }

    mutating func markWorkerRunning(_ index: Int) {
        guard index < currentGraph.workers.count else { return }
        currentGraph.workers[index].status = .running
        currentGraph.workingMemory["active_worker"] = "\(index)"
        saveState()
    }

    mutating func markWorkerCompleted(_ index: Int, result: String) {
        guard index < currentGraph.workers.count else { return }
        currentGraph.workers[index].status = .completed
        currentGraph.workers[index].result = result
        logState.info("Worker \(index) completed: \(result.prefix(100))")
        saveState()
    }

    mutating func markWorkerFailed(_ index: Int, reason: String) {
        guard index < currentGraph.workers.count else { return }
        currentGraph.workers[index].status = .failed
        currentGraph.workers[index].result = reason
        logState.warning("Worker \(index) failed: \(reason)")
        saveState()
    }

    mutating func addSupervisorNote(_ note: String) {
        currentGraph.supervisorNotes.append(note)
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
        for i in currentGraph.workers.indices where currentGraph.workers[i].status == .running || currentGraph.workers[i].status == .pending {
            currentGraph.workers[i].status = .failed
        }
        saveState()
    }

    // MARK: - Private Persistence

    private func saveState() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(currentGraph),
           let jsonString = String(data: data, encoding: .utf8) {
            var sessionGraph = ContextMemoryManager.shared.getActiveState(for: conversationID)
            sessionGraph.workingMemory["supervisor_state"] = jsonString
            sessionGraph.negativeConstraints = Array(currentConstraints)
            ContextMemoryManager.shared.updateActiveState(conversationID: conversationID, state: sessionGraph)
        }
    }
}

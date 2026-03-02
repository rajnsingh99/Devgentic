//
//  SupervisorProtocols.swift
//  Devgentic
//
//  Created for Supervisor Architecture.
//  Defines the protocol contracts for delegation-based multi-worker components.
//

import Foundation

// MARK: - Phase 1: Memory & State Protocols

/// Manages the persistent delegation state, tracking worker assignments and progress.
protocol DelegationStateMutating: Sendable {
    var currentGraph: SupervisorGraph { get }
    var currentConstraints: Set<String> { get }

    /// Initialize the delegation with a set of worker assignments.
    mutating func initializeDelegation(goal: String, workers: [WorkerAssignment])

    /// Mark a worker as currently running.
    mutating func markWorkerRunning(_ index: Int)

    /// Mark a worker as successfully completed with its result.
    mutating func markWorkerCompleted(_ index: Int, result: String)

    /// Mark a worker as failed with the reason.
    mutating func markWorkerFailed(_ index: Int, reason: String)

    /// Add a supervisor reasoning note.
    mutating func addSupervisorNote(_ note: String)

    /// Record a failed path to prevent retrying.
    mutating func addNegativeConstraint(_ path: String)

    /// Mark the entire delegation as cancelled.
    mutating func markAsCancelled()
}

/// Manages the collected results from all workers for aggregation.
protocol WorkerResultManaging: Sendable {
    var workerResults: [WorkerResult] { get }

    /// Record a worker's execution result.
    mutating func recordResult(workerIndex: Int, taskDescription: String, result: String, isSuccess: Bool)

    /// Clear all results.
    mutating func clearResults()
}

// MARK: - Phase 2: Evaluation Protocols

/// Defines the supervisor's decision about what to do next.
enum SupervisorDecision: Sendable, Equatable {
    /// Delegate to the next pending worker.
    case delegateNext(workerIndex: Int)

    /// All workers have completed successfully.
    case allComplete

    /// A worker failed and should be reassigned.
    case reassign(workerIndex: Int, reason: String)

    /// Abort the entire delegation.
    case abort(reason: String)
}

/// Evaluates the delegation progress and decides the next action.
protocol SupervisorEvaluating: Sendable {
    func evaluateProgress(
        graph: SupervisorGraph,
        completedCount: Int,
        totalCount: Int
    ) -> SupervisorDecision
}

//
//  SupervisorGraph.swift
//  Devgentic
//
//  Created for Supervisor Architecture.
//  State models for the delegation-based multi-worker paradigm.
//

import Foundation

// MARK: - Worker Status

/// The lifecycle state of an individual worker.
enum WorkerStatus: String, Sendable, Codable {
    case pending    // Not yet started
    case running    // Currently executing
    case completed  // Successfully finished
    case failed     // Execution failed
}

// MARK: - Worker Assignment

/// Represents a single worker's task assignment.
/// Each worker handles a specific subtask using a subset of available tools.
struct WorkerAssignment: Sendable, Codable, Identifiable {
    let id: UUID
    let workerIndex: Int            // Execution order
    let taskDescription: String     // What this worker should accomplish
    var assignedTools: [String]     // Subset of tools available to this worker
    var status: WorkerStatus        // Current lifecycle state
    var result: String?             // Execution result
    var observations: [CognitiveObservation] // Observations accumulated during worker execution

    init(
        id: UUID = UUID(),
        workerIndex: Int,
        taskDescription: String,
        assignedTools: [String] = [],
        status: WorkerStatus = .pending,
        result: String? = nil,
        observations: [CognitiveObservation] = []
    ) {
        self.id = id
        self.workerIndex = workerIndex
        self.taskDescription = taskDescription
        self.assignedTools = assignedTools
        self.status = status
        self.result = result
        self.observations = observations
    }
}

// MARK: - Worker Result

/// A clean record of a worker's execution outcome for aggregation.
struct WorkerResult: Sendable, Codable {
    let workerIndex: Int
    let taskDescription: String
    let result: String
    let isSuccess: Bool
}

// MARK: - Supervisor Graph

/// The root state object for the Supervisor architecture.
/// Tracks worker assignments, delegation notes, and aggregated results.
struct SupervisorGraph: Sendable, Codable {
    let sessionID: String
    var goal: String
    var workers: [WorkerAssignment]
    var supervisorNotes: [String]       // Supervisor's reasoning about delegation
    var negativeConstraints: [String]   // Failed paths (Ghost Protocol)
    var workingMemory: [String: String] // Transient key-value state

    init(
        sessionID: String,
        goal: String = "",
        workers: [WorkerAssignment] = [],
        supervisorNotes: [String] = [],
        negativeConstraints: [String] = [],
        workingMemory: [String: String] = [:]
    ) {
        self.sessionID = sessionID
        self.goal = goal
        self.workers = workers
        self.supervisorNotes = supervisorNotes
        self.negativeConstraints = negativeConstraints
        self.workingMemory = workingMemory
    }

    // MARK: - Semantic Compression

    /// Token-efficient representation for the LLM prompt.
    /// Strips detailed observations from completed workers.
    func compressForPrompt() -> String {
        var compressedGraph = self

        for i in compressedGraph.workers.indices {
            if compressedGraph.workers[i].status == .completed {
                compressedGraph.workers[i].observations = []
                // Truncate long results
                if let result = compressedGraph.workers[i].result, result.count > 200 {
                    compressedGraph.workers[i].result = String(result.prefix(200)) + "..."
                }
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(compressedGraph),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    // MARK: - Convenience

    /// Returns the next pending worker assignment, if any.
    var nextPendingWorker: WorkerAssignment? {
        return workers.first(where: { $0.status == .pending })
    }

    /// Returns the count of completed workers.
    var completedCount: Int {
        return workers.filter { $0.status == .completed }.count
    }

    /// Returns the count of failed workers.
    var failedCount: Int {
        return workers.filter { $0.status == .failed }.count
    }

    /// Whether all workers have finished (completed or failed).
    var allWorkersFinished: Bool {
        return workers.allSatisfy { $0.status == .completed || $0.status == .failed }
    }

    /// Checks if a path is forbidden by negative constraints.
    func isPathForbidden(_ path: String) -> Bool {
        return negativeConstraints.contains { path.contains($0) }
    }
}

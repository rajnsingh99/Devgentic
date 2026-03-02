//
//  WorkerResultStore.swift
//  Devgentic
//
//  Created for Supervisor Architecture.
//  Collects and manages worker execution results for aggregation.
//

import Foundation
import OSLog

private let logState = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "WorkerResults")

/// Concrete implementation of `WorkerResultManaging`.
/// Collects results from all worker executions for the supervisor's aggregation phase.
struct WorkerResultStore: WorkerResultManaging {

    private(set) var workerResults: [WorkerResult] = []

    // MARK: - Result Management

    mutating func recordResult(workerIndex: Int, taskDescription: String, result: String, isSuccess: Bool) {
        let workerResult = WorkerResult(
            workerIndex: workerIndex,
            taskDescription: taskDescription,
            result: result,
            isSuccess: isSuccess
        )
        workerResults.append(workerResult)
        logState.debug("Worker \(workerIndex) result recorded. Success: \(isSuccess)")
    }

    mutating func clearResults() {
        let count = workerResults.count
        logState.debug("Clearing \(count) worker results.")
        workerResults.removeAll()
    }
}

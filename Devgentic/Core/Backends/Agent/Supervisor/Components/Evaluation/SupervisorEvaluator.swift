//
//  SupervisorEvaluator.swift
//  Devgentic
//
//  Created for Supervisor Architecture.
//  Evaluates delegation progress and determines the next supervisory action.
//

import Foundation

/// Concrete implementation of `SupervisorEvaluating`.
/// Analyzes the current delegation state to decide what the supervisor should do next.
struct SupervisorEvaluator: SupervisorEvaluating {

    func evaluateProgress(
        graph: SupervisorGraph,
        completedCount: Int,
        totalCount: Int
    ) -> SupervisorDecision {

        // All workers completed
        if graph.allWorkersFinished {
            if graph.failedCount == totalCount {
                return .abort(reason: "All workers failed.")
            }
            return .allComplete
        }

        // Find next pending worker
        if let nextWorker = graph.nextPendingWorker {
            return .delegateNext(workerIndex: nextWorker.workerIndex)
        }

        // No pending workers but not all finished — something is stuck
        return .abort(reason: "No pending workers available but delegation is incomplete.")
    }
}

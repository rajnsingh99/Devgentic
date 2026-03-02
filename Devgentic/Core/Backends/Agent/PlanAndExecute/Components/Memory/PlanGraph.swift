//
//  PlanGraph.swift
//  Devgentic
//
//  Created for Plan & Execute Architecture.
//  State models for the two-phase planning + execution paradigm.
//

import Foundation

// MARK: - Plan Step Status

/// The lifecycle state of an individual plan step.
enum PlanStepStatus: String, Sendable, Codable {
    case pending      // Not yet started
    case inProgress   // Currently executing
    case completed    // Successfully finished
    case failed       // Execution failed
    case skipped      // Skipped due to re-planning
}

// MARK: - Plan Step

/// Represents a single step in the agent's plan.
/// Each step maps to a discrete subtask that may involve one or more tool calls.
struct PlanStep: Sendable, Codable, Identifiable {
    let id: UUID
    let index: Int                      // Execution order (0-based)
    let description: String             // What this step should accomplish
    var status: PlanStepStatus          // Current lifecycle state
    var toolsUsed: [String]             // Tools invoked during execution of this step
    var outcome: String?                // Result summary after completion

    init(
        id: UUID = UUID(),
        index: Int,
        description: String,
        status: PlanStepStatus = .pending,
        toolsUsed: [String] = [],
        outcome: String? = nil
    ) {
        self.id = id
        self.index = index
        self.description = description
        self.status = status
        self.toolsUsed = toolsUsed
        self.outcome = outcome
    }
}

// MARK: - Plan Graph

/// The root state object for the Plan & Execute architecture.
/// Tracks the overall plan, step progress, and re-planning history.
struct PlanGraph: Sendable, Codable {
    let sessionID: String
    var goal: String
    var steps: [PlanStep]
    var replanCount: Int                // How many times the plan has been revised
    var negativeConstraints: [String]   // Failed paths (Ghost Protocol)
    var workingMemory: [String: String] // Transient key-value state

    init(
        sessionID: String,
        goal: String = "",
        steps: [PlanStep] = [],
        replanCount: Int = 0,
        negativeConstraints: [String] = [],
        workingMemory: [String: String] = [:]
    ) {
        self.sessionID = sessionID
        self.goal = goal
        self.steps = steps
        self.replanCount = replanCount
        self.negativeConstraints = negativeConstraints
        self.workingMemory = workingMemory
    }

    // MARK: - Semantic Compression

    /// Generates a token-efficient representation for the LLM prompt.
    /// Strips outcome details from completed steps to save context window,
    /// while preserving full details for the active and pending steps.
    func compressForPrompt() -> String {
        var compressedGraph = self

        for i in compressedGraph.steps.indices {
            if compressedGraph.steps[i].status == .completed {
                // Keep only a short summary for completed steps
                if let outcome = compressedGraph.steps[i].outcome, outcome.count > 200 {
                    compressedGraph.steps[i].outcome = String(outcome.prefix(200)) + "..."
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

    /// Returns the next pending step, if any.
    var nextPendingStep: PlanStep? {
        return steps.first(where: { $0.status == .pending })
    }

    /// Returns the currently active step, if any.
    var activeStep: PlanStep? {
        return steps.first(where: { $0.status == .inProgress })
    }

    /// Returns the count of completed steps.
    var completedCount: Int {
        return steps.filter { $0.status == .completed }.count
    }

    /// Checks if a path is forbidden by negative constraints.
    func isPathForbidden(_ path: String) -> Bool {
        return negativeConstraints.contains { path.contains($0) }
    }
}

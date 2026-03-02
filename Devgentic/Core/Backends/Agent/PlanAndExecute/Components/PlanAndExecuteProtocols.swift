//
//  PlanAndExecuteProtocols.swift
//  Devgentic
//
//  Created for Plan & Execute Architecture.
//  Defines the protocol contracts for all pluggable components.
//

import Foundation

// MARK: - Phase 1: Memory & State Protocols

/// Manages the persistent plan state, tracking step progress and re-planning history.
/// Decouples the executor from storage implementation details.
protocol PlanStateMutating: Sendable {
    var currentPlan: PlanGraph { get }
    var currentConstraints: Set<String> { get }

    /// Initialize the plan with a decomposed set of steps.
    mutating func initializePlan(goal: String, steps: [PlanStep])

    /// Mark a step as currently in progress.
    mutating func markStepInProgress(_ index: Int)

    /// Mark a step as successfully completed with its outcome.
    mutating func markStepCompleted(_ index: Int, outcome: String)

    /// Mark a step as failed with the reason.
    mutating func markStepFailed(_ index: Int, reason: String)

    /// Replace the remaining plan steps after a re-plan.
    mutating func replacePlan(newSteps: [PlanStep])

    /// Record a failed path to prevent retrying.
    mutating func addNegativeConstraint(_ path: String)

    /// Mark the entire plan as cancelled.
    mutating func markAsCancelled()
}

/// Manages the volatile observation memory scoped to the currently executing step.
/// Observations are cleared between steps to keep context focused.
protocol StepObservationManaging: Sendable {
    var activeObservations: [CognitiveObservation] { get }

    /// Add a tool execution observation.
    mutating func addObservation(toolName: String, shortObservation: String, heavyContent: String?, isRequired: Bool)

    /// Add a system alert for the current step.
    mutating func addSystemAlert(_ msg: String, stepIndex: Int)

    /// Clear all observations to prepare for the next step.
    mutating func clearForNextStep()

    /// Evict older observations, keeping only the most recent required one.
    mutating func resetObservationFlags()
}

// MARK: - Phase 2: Evaluation Protocols

/// Defines the outcome of evaluating an LLM step within the execution phase.
enum PlanTerminationStatus: Sendable, Equatable {
    /// The step execution should continue (tool call pending).
    case proceed

    /// The current step is complete.
    case stepCompleted(outcome: String)

    /// All plan steps have been completed.
    case allStepsCompleted

    /// The current step failed and re-planning may be needed.
    case replanRequired(failedStep: Int, reason: String)

    /// The re-planning budget is exhausted.
    case budgetExhausted
}

/// Analyzes cognitive steps to determine if the current plan step has reached completion.
protocol PlanTerminationEvaluating: Sendable {
    func evaluateStep(
        step: LeanCognitiveStep,
        currentStepIndex: Int,
        totalSteps: Int,
        iterationInStep: Int,
        maxIterationsPerStep: Int
    ) -> PlanTerminationStatus
}

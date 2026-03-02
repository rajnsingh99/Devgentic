//
//  ReflexionProtocols.swift
//  Devgentic
//
//  Created for Reflexion Architecture.
//  Defines the protocol contracts for Execute-Reflect-Retry components.
//

import Foundation

// MARK: - Phase 1: Memory & State Protocols

/// Manages the persistent trial state for the Reflexion architecture.
/// Tracks trial history, reflections, and negative constraints.
protocol TrialStateMutating: Sendable {
    var currentGraph: ReflexionGraph { get }
    var currentConstraints: Set<String> { get }

    /// Begin a new execution trial.
    mutating func startNewTrial(goal: String)

    /// Close the current trial with its outcome, reflection, and verdict.
    mutating func closeTrial(outcome: String, reflection: String, verdict: ReflectionVerdict)

    /// Record a failed path to prevent retrying.
    mutating func addNegativeConstraint(_ path: String)

    /// Mark the entire execution as cancelled.
    mutating func markAsCancelled()
}

/// Manages the volatile observation memory for the Reflexion architecture.
/// Extends the basic observation pattern with reflection tracking and per-trial reset.
protocol ReflectionMemoryManaging: Sendable {
    var activeObservations: [CognitiveObservation] { get }
    var reflections: [String] { get }

    /// Add a tool execution observation.
    mutating func addObservation(toolName: String, shortObservation: String, heavyContent: String?, isRequired: Bool)

    /// Add a system alert.
    mutating func addSystemAlert(_ msg: String, currentIteration: Int)

    /// Evict older observations, keeping only the most recent.
    mutating func resetObservationFlags()

    /// Record a reflection from a completed trial.
    mutating func addReflection(_ reflection: String)

    /// Clear observations for a new trial while preserving reflections.
    mutating func clearObservationsForNewTrial()
}

// MARK: - Phase 2: Evaluation Protocols

/// The outcome of the reflection evaluation phase.
enum ReflectionOutcome: Sendable {
    /// The trial result is satisfactory — use this as the final answer.
    case approved(finalAnswer: String)

    /// The trial result is unsatisfactory — retry with reflection insights.
    case retry(reflection: String)

    /// The trial budget is exhausted — use the best available answer.
    case budgetExhausted(bestAnswer: String)
}

// Equatable conformance for ReflectionOutcome
extension ReflectionOutcome: Equatable {
    static func == (lhs: ReflectionOutcome, rhs: ReflectionOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.approved(let a), .approved(let b)): return a == b
        case (.retry(let a), .retry(let b)): return a == b
        case (.budgetExhausted(let a), .budgetExhausted(let b)): return a == b
        default: return false
        }
    }
}

/// Evaluates the quality of a trial's result by calling the LLM for reflection.
protocol ReflectionEvaluating: Sendable {
    func evaluate(
        goal: String,
        trialOutcome: String,
        observations: [CognitiveObservation],
        trialNumber: Int,
        maxTrials: Int,
        model: any LLMProvider,
        rateLimitCategory: RateLimitCategory
    ) async throws -> ReflectionOutcome
}

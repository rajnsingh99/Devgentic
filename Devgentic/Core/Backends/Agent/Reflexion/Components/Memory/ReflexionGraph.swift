//
//  ReflexionGraph.swift
//  Devgentic
//
//  Created for Reflexion Architecture.
//  State models for the Execute-Reflect-Retry paradigm.
//

import Foundation

// MARK: - Reflection Verdict

/// The LLM's assessment of a trial's quality.
enum ReflectionVerdict: String, Sendable, Codable {
    case pass       // Result is satisfactory — no retry needed
    case fail       // Result is unsatisfactory — retry with reflection insights
    case partial    // Partially good — retry with adjustments
}

// MARK: - Trial Record

/// Records the complete history of a single execution trial.
/// Each trial captures its observations, outcome, and the LLM's reflection on quality.
struct TrialRecord: Sendable, Codable, Identifiable {
    let id: UUID
    let trialNumber: Int
    var observations: [CognitiveObservation]
    var outcome: String?            // The agent's final answer for this trial
    var reflection: String?         // The LLM's reflection on what went wrong/right
    var verdict: ReflectionVerdict  // Quality assessment

    init(
        id: UUID = UUID(),
        trialNumber: Int,
        observations: [CognitiveObservation] = [],
        outcome: String? = nil,
        reflection: String? = nil,
        verdict: ReflectionVerdict = .fail
    ) {
        self.id = id
        self.trialNumber = trialNumber
        self.observations = observations
        self.outcome = outcome
        self.reflection = reflection
        self.verdict = verdict
    }
}

// MARK: - Reflexion Graph

/// The root state object for the Reflexion architecture.
/// Tracks trial history, accumulated reflections, and negative constraints.
struct ReflexionGraph: Sendable, Codable {
    let sessionID: String
    var goal: String
    var trials: [TrialRecord]
    var negativeConstraints: [String]
    var workingMemory: [String: String]

    init(
        sessionID: String,
        goal: String = "",
        trials: [TrialRecord] = [],
        negativeConstraints: [String] = [],
        workingMemory: [String: String] = [:]
    ) {
        self.sessionID = sessionID
        self.goal = goal
        self.trials = trials
        self.negativeConstraints = negativeConstraints
        self.workingMemory = workingMemory
    }

    // MARK: - Reflection Journal

    /// Accumulated reflections from all past trials.
    /// Injected into the LLM context to prevent repeating mistakes.
    var reflectionJournal: String {
        let entries = trials.compactMap { trial -> String? in
            guard let reflection = trial.reflection else { return nil }
            return "Trial \(trial.trialNumber) (\(trial.verdict.rawValue)): \(reflection)"
        }
        return entries.isEmpty ? "" : entries.joined(separator: "\n\n")
    }

    // MARK: - Semantic Compression

    /// Token-efficient representation for the LLM prompt.
    /// Strips heavy observation data from past trials, keeping only reflections.
    func compressForPrompt() -> String {
        var compressedGraph = self

        for i in compressedGraph.trials.indices {
            // Only keep outcome and reflection, strip detailed observations
            compressedGraph.trials[i].observations = []
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

    /// The latest trial, if any.
    var currentTrial: TrialRecord? {
        return trials.last
    }

    /// Whether any trial has passed reflection.
    var hasPassingTrial: Bool {
        return trials.contains { $0.verdict == .pass }
    }

    /// The best trial result (prefer .pass, then .partial, then .fail).
    var bestTrial: TrialRecord? {
        return trials.first(where: { $0.verdict == .pass })
            ?? trials.first(where: { $0.verdict == .partial })
            ?? trials.last
    }

    /// Checks if a path is forbidden by negative constraints.
    func isPathForbidden(_ path: String) -> Bool {
        return negativeConstraints.contains { path.contains($0) }
    }
}

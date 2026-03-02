//
//  ReflectionEvaluator.swift
//  Devgentic
//
//  Created for Reflexion Architecture.
//  Evaluates trial quality by calling the LLM for self-reflection.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ReflectionEval")

/// Concrete implementation of `ReflectionEvaluating`.
/// Calls the LLM to reflect on a completed trial and determine if the result is satisfactory.
struct ReflectionEvaluator: ReflectionEvaluating {

    func evaluate(
        goal: String,
        trialOutcome: String,
        observations: [CognitiveObservation],
        trialNumber: Int,
        maxTrials: Int,
        model: any LLMProvider,
        rateLimitCategory: RateLimitCategory
    ) async throws -> ReflectionOutcome {

        // If this is the last trial, return budget exhausted
        if trialNumber >= maxTrials {
            logger.info("Trial budget exhausted (\(trialNumber)/\(maxTrials)). Using best available result.")
            return .budgetExhausted(bestAnswer: trialOutcome)
        }

        await GlobalRateLimiter.shared.wait(for: rateLimitCategory)

        let observationSummary = observations
            .filter { $0.isRequired && $0.toolName != "system" }
            .map { "- \($0.toolName): \($0.shortObservation)" }
            .joined(separator: "\n")

        let reflectionPrompt = """
        You are a quality evaluator reflecting on an agent's execution.

        GOAL: "\(goal)"

        TRIAL \(trialNumber) RESULT:
        \(trialOutcome)

        ACTIONS TAKEN:
        \(observationSummary.isEmpty ? "No tool actions recorded." : observationSummary)

        Evaluate the result quality:
        1. Did the agent fully accomplish the goal?
        2. Were there any errors or missed steps?
        3. Could the approach be improved?

        Respond with a JSON object:
        {
            "verdict": "pass" or "fail" or "partial",
            "reflection": "Brief analysis of what went well and what could be improved"
        }

        Output ONLY the JSON object.
        """

        let messages: [[String: String]] = [
            ["role": "system", "content": "You are a self-reflection evaluator. Assess execution quality and output only JSON."],
            ["role": "user", "content": reflectionPrompt]
        ]

        let response = try await model.generate(messages: messages, tools: nil, responseSchema: nil)

        // Parse the reflection response
        let (verdict, reflection) = parseReflection(from: response)

        logger.info("Reflection verdict for trial \(trialNumber): \(verdict.rawValue)")

        switch verdict {
        case .pass:
            return .approved(finalAnswer: trialOutcome)
        case .fail, .partial:
            return .retry(reflection: reflection)
        }
    }

    // MARK: - Parsing

    /// Parses the LLM's reflection response into a verdict and reflection string.
    private func parseReflection(from response: String) -> (ReflectionVerdict, String) {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Fallback: if we can't parse, assume fail with the raw response as reflection
            return (.fail, response)
        }

        let verdictStr = (json["verdict"] as? String ?? "fail").lowercased()
        let reflection = json["reflection"] as? String ?? "Unable to parse reflection."

        let verdict: ReflectionVerdict
        switch verdictStr {
        case "pass": verdict = .pass
        case "partial": verdict = .partial
        default: verdict = .fail
        }

        return (verdict, reflection)
    }
}

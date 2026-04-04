//
//  ReflectionEvaluator.swift
//  Devgentic
//
//  Issues a single LLM call to evaluate whether an execution trial achieved the user's goal.
//  Returns a ReflectionResult indicating acceptance or critique with revision suggestions.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ReflectionEvaluator")

struct ReflectionEvaluator: Sendable {

    func evaluate(
        summary: ExecutionSummary,
        originalGoal: String,
        model: any LLMProvider,
        trial: Int
    ) async throws -> ReflectionResult {

        let toolResultsSummary: String
        if summary.toolResults.isEmpty {
            toolResultsSummary = "No tools were executed."
        } else {
            toolResultsSummary = summary.toolResults.map { result in
                let status = result.isSuccess ? "Success" : "Failed"
                let truncated = result.output.count > 400
                    ? String(result.output.prefix(400)) + "... [truncated]"
                    : result.output
                return "- \(result.toolName) [\(status)]: \(truncated)"
            }.joined(separator: "\n")
        }

        let systemPrompt = """
        You are a self-reflection evaluator for an AI agent. Your job is to analyze whether the agent's execution achieved the user's stated goal.

        Respond with ONLY a JSON object (no markdown fences):
        {
            "isAcceptable": true/false,
            "critique": "Brief explanation of what went well or wrong",
            "suggestedRevisions": "Specific guidance for improvement (null if acceptable)"
        }

        Be strict: only mark as acceptable if the goal was meaningfully achieved.
        Be constructive: if not acceptable, provide actionable suggestions for the next attempt.
        """

        let userPrompt = """
        ORIGINAL GOAL: \(originalGoal)

        TRIAL \(trial) RESULTS:
        Status: \(summary.completionStatus)
        \(summary.failureReason.map { "Failure Reason: \($0)\n" } ?? "")
        Tool Results:
        \(toolResultsSummary)

        Was the goal achieved? Evaluate and respond with JSON.
        """

        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]

        do {
            let response = try await model.generate(messages: messages, tools: nil, responseSchema: nil)
            return parseReflection(from: response, trial: trial)
        } catch {
            logger.warning("Reflection LLM call failed: \(error.localizedDescription). Defaulting to not acceptable.")
            return ReflectionResult(
                isAcceptable: false,
                critique: "Reflection evaluation failed due to LLM error: \(error.localizedDescription)",
                suggestedRevisions: "Retry the same approach with more careful tool usage.",
                trial: trial
            )
        }
    }

    // MARK: - Parsing

    private func parseReflection(from response: String, trial: Int) -> ReflectionResult {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try direct JSON parse
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return extractResult(from: json, trial: trial)
        }

        // Try extracting JSON from markdown code blocks
        let cleaned = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = cleaned.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return extractResult(from: json, trial: trial)
        }

        // Fallback: assume not acceptable
        logger.warning("Failed to parse reflection JSON. Defaulting to not acceptable.")
        return ReflectionResult(
            isAcceptable: false,
            critique: "Unable to parse reflection output. Raw response may indicate issues.",
            suggestedRevisions: "Try a different approach to the task.",
            trial: trial
        )
    }

    private func extractResult(from json: [String: Any], trial: Int) -> ReflectionResult {
        let isAcceptable = json["isAcceptable"] as? Bool ?? false
        let critique = json["critique"] as? String ?? "No critique provided."
        let suggestedRevisions = json["suggestedRevisions"] as? String

        return ReflectionResult(
            isAcceptable: isAcceptable,
            critique: critique,
            suggestedRevisions: suggestedRevisions,
            trial: trial
        )
    }
}

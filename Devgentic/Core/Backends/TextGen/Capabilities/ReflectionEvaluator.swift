// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ReflectionEvaluator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "ReflectionEvaluator")

// Why: an LLM-error catch must not fabricate a verdict: that forced a whole extra agent trial off an
// infrastructure fault.
/// What one evaluation call produced: a real verdict, or nothing (`.inconclusive`).
/// With no evaluation there is no honest verdict, so the caller keeps the trial it already has.
/// An infrastructure fault is never reported as a content fault.
enum ReflectionEvaluation: Sendable {
    case verdict(ReflectionResult)
    /// The evaluation CALL failed (provider/transport/model-slot) — not the trial being judged.
    case inconclusive(reason: String)
}

struct ReflectionEvaluator: Sendable {

    func evaluate(
        summary: ExecutionSummary,
        originalGoal: String,
        model: any LLMProvider,
        trial: Int
    ) async throws -> (result: ReflectionEvaluation, usage: TokenUsage) {

        // Compute context-aware tool result budget
        let contextWindow = KnownModelContextWindows.lookup(model.modelName) ?? 8192
        let toolResultBudget = Self.computeToolBudget(contextWindow: contextWindow)

        let toolResultsSummary = Self.budgetToolResults(
            results: summary.toolResults,
            budget: toolResultBudget
        )

        // Build failure reason line (only if present)
        let failureLine = summary.failureReason.map { "Failure: \($0)\n" } ?? ""

        // Single user message — no system message.
        // Attention-optimized: goal (primacy) → trial data (middle) → format contract (recency).
        let prompt = """
        <goal>
        \(originalGoal)
        </goal>

        <trial status="\(summary.completionStatus)" number="\(trial)">
        \(failureLine)\(toolResultsSummary)
        </trial>

        Did the agent achieve the goal?
        Respond with EXACTLY this format:
        VERDICT: PASS or RETRY
        CRITIQUE: One sentence on what went well or wrong.
        REVISION: Specific guidance for next attempt (omit this line if PASS).
        """

        let messages: [[String: String]] = [
            ["role": "user", "content": prompt]
        ]

        do {
            let (response, reportedUsage) = try await model.generateWithUsage(messages: messages, tools: nil, responseSchema: nil)
            // Prefer the provider's real token counts; fall back to a chars÷4 estimate only when
            // the provider didn't report usage (e.g. MLX), so the eval call is still counted (#10b).
            let usage = reportedUsage ?? .estimated(inputChars: prompt.count, outputChars: response.count)
            return (.verdict(parseReflection(from: response, trial: trial)), usage)
        } catch is CancellationError {
            // Cancellation must propagate, not be swallowed: folding it into a "not acceptable" verdict would record a bogus
            // critique into reflexion memory and delay the user's Stop by a trial boundary.
            throw CancellationError()
        } catch {
            // Infrastructure fault, not a verdict: return `.inconclusive` (see `ReflectionEvaluation.inconclusive`), not a
            // fabricated rejection.
            logger.warning("[REFLECTION] Evaluation LLM call for trial \(trial) failed: \(error.localizedDescription). CONSEQUENCE: the verdict is INCONCLUSIVE — the caller keeps the trial's answer as-is; no extra trial runs and no fabricated critique enters the next prompt.")
            return (.inconclusive(reason: error.localizedDescription), TokenUsage())
        }
    }

    // MARK: - Context-Aware Tool Result Budgeting

    /// Computes the character budget for tool results based on the model context window.
    /// Formula: `min(contextChars - fixedOverhead - responseReserve, 6000)`, floored at 800.
    /// - Parameter contextWindow: model context window in tokens. Returns the budget in characters.
    static func computeToolBudget(contextWindow: Int) -> Int {
        let contextChars = contextWindow * 3  // ~3 chars per token approximation
        let fixedOverhead = 500               // prompt template + goal + format instructions
        let responseReserve = 200             // model's response
        let raw = contextChars - fixedOverhead - responseReserve
        return min(max(raw, 800), 6000)
    }

    /// Builds a budgeted tool results summary with failed-first priority: failed results get up to 60% of the budget
    /// since they carry more diagnostic value; the rest is split evenly among successful results.
    /// - Parameters: `results` from the trial; `budget` is the total character budget. Returns the formatted string.
    static func budgetToolResults(results: [SynthesizedToolResult], budget: Int) -> String {
        guard !results.isEmpty else { return "No tools were executed." }

        let failed = results.filter { !$0.isSuccess }
        let succeeded = results.filter { $0.isSuccess }

        var remaining = budget
        var lines: [String] = []

        // Failed results get priority (up to 60% of budget).
        let failedBudget = Int(Double(budget) * 0.6)
        if !failed.isEmpty {
            let perFailedBudget = failedBudget / failed.count
            for result in failed {
                let truncated = truncateResult(result.output, to: perFailedBudget)
                let line = "- \(result.toolName) [Failed]: \(truncated)"
                lines.append(line)
                remaining -= line.count
            }
        }

        // Successful results share the rest.
        if !succeeded.isEmpty && remaining > 0 {
            let perSuccessBudget = max(remaining / succeeded.count, 50)
            for result in succeeded {
                let truncated = truncateResult(result.output, to: perSuccessBudget)
                let line = "- \(result.toolName) [Success]: \(truncated)"
                lines.append(line)
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Truncates a result string to the given character budget.
    private static func truncateResult(_ output: String, to budget: Int) -> String {
        guard output.count > budget else { return output }
        return String(output.prefix(budget)) + "... [truncated]"
    }

    // MARK: - Key-Value Parser

    /// Parses a key-value formatted LLM response into a ReflectionResult (never throws).
    /// Stages: sanitize, VERDICT match (PASS/RETRY), CRITIQUE and optional REVISION text, keyword fallback.
    /// - Parameters: `response` is the raw output; `trial` is the number recorded on the result.
    func parseReflection(from response: String, trial: Int) -> ReflectionResult {

        // Stage 1: Sanitize — strip think blocks, fences, special tokens
        let sanitized = OutputSanitizer.sanitize(response)
        let cleaned = sanitized.cleaned

        guard !cleaned.isEmpty else {
            logger.warning("Reflection output is empty after sanitization. Defaulting to not acceptable.")
            return ReflectionResult(
                isAcceptable: false,
                critique: "Empty reflection output.",
                suggestedRevisions: "Try a different approach to the task.",
                trial: trial
            )
        }

        // Stage 2: Extract VERDICT
        let verdictValue = extractField("VERDICT", from: cleaned)

        // Stage 3: Extract CRITIQUE
        let critiqueValue = extractField("CRITIQUE", from: cleaned)

        // Stage 4: Extract REVISION (optional)
        let revisionValue = extractField("REVISION", from: cleaned)

        // If we found a VERDICT line, parse it
        if let verdict = verdictValue {
            let isAcceptable = Self.isPassVerdict(verdict)
            return ReflectionResult(
                isAcceptable: isAcceptable,
                critique: critiqueValue ?? "No critique provided.",
                suggestedRevisions: isAcceptable ? nil : revisionValue,
                trial: trial
            )
        }

        // Keyword fallback when no VERDICT line was found: scan for positive/negative signals rather than pessimistically
        // defaulting to false.
        logger.info("No VERDICT line found in reflection output. Attempting keyword fallback.")

        let isAcceptable = Self.keywordFallback(cleaned)

        return ReflectionResult(
            isAcceptable: isAcceptable,
            critique: critiqueValue ?? cleaned.prefix(200).trimmingCharacters(in: .whitespacesAndNewlines),
            suggestedRevisions: isAcceptable ? nil : (revisionValue ?? "Try a different approach."),
            trial: trial
        )
    }

    // MARK: - Private Helpers

    /// Extracts the value after a `LABEL:` line in the response (case-insensitive).
    private func extractField(_ label: String, from text: String) -> String? {
        let pattern = "(?i)\\b\(label)\\s*:\\s*(.+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }

        let value = String(text[valueRange]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Determines if a verdict string indicates acceptance.
    private static func isPassVerdict(_ verdict: String) -> Bool {
        let lower = verdict.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let passSignals: Set<String> = ["pass", "accept", "accepted", "yes", "done", "achieved"]
        // Check if the verdict starts with any pass signal
        return passSignals.contains(where: { lower.hasPrefix($0) })
    }

    /// Keyword-based fallback when no VERDICT line is found.
    /// Scans for positive signals that indicate the model accepted the trial.
    private static func keywordFallback(_ text: String) -> Bool {
        let lower = text.lowercased()
        let positiveSignals = ["achieved", "success", "successful", "complete", "completed",
                               "goal met", "goal was met", "pass", "acceptable", "accepted"]
        let negativeSignals = ["fail", "not achieved", "incomplete", "retry", "not acceptable",
                               "missing", "did not", "didn't", "unable"]

        let positiveCount = positiveSignals.filter { lower.contains($0) }.count
        let negativeCount = negativeSignals.filter { lower.contains($0) }.count

        // Positive wins ties — avoid pessimistic default
        return positiveCount >= negativeCount && positiveCount > 0
    }
}

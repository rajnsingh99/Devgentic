//
//  ReflectionEvaluator.swift
//  Devgentic
//
//  Issues a single LLM call to evaluate whether an execution trial achieved the user's goal.
//  Returns a ReflectionResult indicating acceptance or critique with revision suggestions.
//
//  Output format: Key-value lines (VERDICT / CRITIQUE / REVISION) — universal across model sizes.
//  Tool results: Context-aware budgeting with failed-first priority.
//
//  Migrated from JSON output during the Reflection Resilience Migration.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "ReflectionEvaluator")

struct ReflectionEvaluator: Sendable {

    func evaluate(
        summary: ExecutionSummary,
        originalGoal: String,
        model: any LLMProvider,
        trial: Int
    ) async throws -> (result: ReflectionResult, usage: TokenUsage) {

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
            return (parseReflection(from: response, trial: trial), usage)
        } catch is CancellationError {
            // #18 (B): cancellation must propagate, not be swallowed. Folding it into a
            // "not acceptable" verdict would record a bogus "evaluation failed" critique
            // into reflexion memory and delay the user's Stop by a trial boundary. Mirrors
            // the trial-stream catch in SelfReflectionCapability.
            throw CancellationError()
        } catch {
            logger.warning("Reflection LLM call failed: \(error.localizedDescription). Defaulting to not acceptable.")
            return (ReflectionResult(
                isAcceptable: false,
                critique: "Reflection evaluation failed due to LLM error: \(error.localizedDescription)",
                suggestedRevisions: "Retry the same approach with more careful tool usage.",
                trial: trial
            ), TokenUsage())
        }
    }

    // MARK: - Context-Aware Tool Result Budgeting

    /// Computes the character budget for tool results based on model context window.
    ///
    /// Formula: `min(contextChars - fixedOverhead - responseReserve, 6000)`, floored at 800.
    /// - Parameter contextWindow: Model context window in tokens.
    /// - Returns: Budget in characters.
    static func computeToolBudget(contextWindow: Int) -> Int {
        let contextChars = contextWindow * 3  // ~3 chars per token approximation
        let fixedOverhead = 500               // prompt template + goal + format instructions
        let responseReserve = 200             // model's response
        let raw = contextChars - fixedOverhead - responseReserve
        return min(max(raw, 800), 6000)
    }

    /// Builds a budgeted tool results summary with failed-first priority.
    ///
    /// Failed results are allocated first (up to 60% of budget) since they carry
    /// more diagnostic value for the evaluator. Remaining budget is split evenly
    /// among successful results.
    ///
    /// - Parameters:
    ///   - results: Tool results from the execution trial.
    ///   - budget: Total character budget for all tool results combined.
    /// - Returns: Formatted tool results string within the budget.
    static func budgetToolResults(results: [SynthesizedToolResult], budget: Int) -> String {
        guard !results.isEmpty else { return "No tools were executed." }

        let failed = results.filter { !$0.isSuccess }
        let succeeded = results.filter { $0.isSuccess }

        var remaining = budget
        var lines: [String] = []

        // Phase 1: Failed results get priority (up to 60% of budget)
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

        // Phase 2: Successful results share the rest
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

    /// Parses a key-value formatted LLM response into a ReflectionResult.
    ///
    /// Parse stages:
    ///   1. OutputSanitizer — strip think blocks, fences, special tokens
    ///   2. VERDICT extraction — regex match for PASS/RETRY variants
    ///   3. CRITIQUE extraction — text after "CRITIQUE:" label
    ///   4. REVISION extraction — text after "REVISION:" label (optional)
    ///   5. Keyword fallback — positive/negative signal scan when no VERDICT found
    ///
    /// - Parameters:
    ///   - response: Raw LLM output text.
    ///   - trial: Current trial number for the result.
    /// - Returns: Parsed ReflectionResult (never throws).
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

        // Stage 5: Keyword fallback — no VERDICT line found
        // The model expressed a judgment but not in the expected format.
        // Scan for positive/negative signals instead of pessimistically defaulting to false.
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

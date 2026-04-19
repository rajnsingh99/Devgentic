//
//  CognitiveParsePipeline.swift
//  Devgentic
//
//  The Dialect-Anchored Cascade pipeline orchestrator.
//  Runs a 5-stage parse sequence for LOCAL model responses:
//
//    Stage 0: OutputSanitizer (always)
//    Stage 1: Primary Parser (expected dialect from CognitiveProfile)
//    Stage 2: FormatDriftDetector (only if Stage 1 is degraded)
//    Stage 3: Fallback Parser (routes on DetectedFormat)
//    Stage 4: HeuristicRecovery (final catch-all)
//
//  Cloud providers (Anthropic, Google, OpenAI) never enter this pipeline.
//
//  Created by Raj Singh on 10/03/26.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "CognitiveParsePipeline")

/// A stateless value type that orchestrates the Dialect-Anchored Cascade.
/// Instantiate per-call with the expected dialect and optional telemetry metadata.
///
/// The public API returns `ModernCognitiveStep` (never throws), keeping the
/// external contract identical to direct parser calls.
struct CognitiveParsePipeline: Sendable {

    /// The dialect we EXPECT this model to produce (from CognitiveProfile).
    let expectedDialect: ModelDialect

    /// Optional model identifier for drift telemetry.
    let modelId: String

    /// Optional iteration number for drift telemetry.
    let iteration: Int

    /// Known tool names from the current tool registry.
    /// Passed to `FormatDriftDetector` for precise dynamic-tag detection (Phase B).
    let knownToolNames: Set<String>

    init(expectedDialect: ModelDialect, modelId: String = "unknown", iteration: Int = 0, knownToolNames: Set<String> = []) {
        self.expectedDialect = expectedDialect
        self.modelId = modelId
        self.iteration = iteration
        self.knownToolNames = knownToolNames
    }

    // MARK: - Public API

    /// Parses raw LLM output through the 5-stage cascade.
    /// Never throws — degrades gracefully to a no-tool step on total failure.
    ///
    /// - Parameter raw: The unmodified text string returned by the model.
    /// - Returns: A `ModernCognitiveStep` with zero or more pending tool calls.
    func parse(raw: String) -> ModernCognitiveStep {

        // === STAGE 0: Pre-Sanitization ===
        let sanitized = OutputSanitizer.sanitize(raw)

        guard !sanitized.cleaned.isEmpty else {
            logger.warning("Pipeline: Sanitized output is empty. Returning no-op step.")
            return ModernCognitiveStep(reasoning: raw, thought: sanitized.thought, toolCalls: [])
        }

        // === STAGE 1: Primary Parser (expected dialect) ===
        let primaryParser = ParserFactory.createParser(for: expectedDialect)
        let primaryResult = primaryParser.parse(rawResponse: sanitized.cleaned)
        
        // Propagate extracted thought
        let primaryStepWithThought = ModernCognitiveStep(
            reasoning: primaryResult.reasoning,
            thought: primaryResult.thought ?? sanitized.thought,
            toolCalls: primaryResult.toolCalls
        )
        
        let primaryOutcome = classifyOutcome(primaryStepWithThought, sanitizedText: sanitized.cleaned)

        if primaryOutcome.isConfident {
            logger.info("Pipeline: Stage 1 confident. dialect=\(expectedDialect.rawValue) tools=\(primaryResult.toolCalls.count)")
            return primaryStepWithThought
        }

        // === STAGE 2: Format Drift Detection ===
        let detector = FormatDriftDetector(excludedDialect: expectedDialect, knownToolNames: knownToolNames)

        guard let detectedFormat = detector.detect(in: sanitized.cleaned) else {
            // No drift pattern found.
            // If primary returned zero tools, give heuristic one shot before giving up.
            if primaryResult.toolCalls.isEmpty {
                return runHeuristicRecovery(sanitized: sanitized, primaryResult: primaryStepWithThought)
            }
            logger.info("Pipeline: Stage 2 found no drift. Returning primary result.")
            return primaryStepWithThought
        }

        logger.notice("Pipeline: DRIFT detected. expected=\(expectedDialect.rawValue) actual=\(detectedFormat.rawValue)")

        // === STAGE 3: Fallback Parser ===
        let fallbackParser = ParserFactory.createFallbackParser(for: detectedFormat)
        let fallbackResult = fallbackParser.parse(rawResponse: sanitized.cleaned)

        if !fallbackResult.toolCalls.isEmpty {
            logger.info("Pipeline: Stage 3 succeeded. tools=\(fallbackResult.toolCalls.count) via=\(detectedFormat.rawValue)")
            logDriftEvent(detectedFormat: detectedFormat, toolCount: fallbackResult.toolCalls.count)
            return ModernCognitiveStep(
                reasoning: fallbackResult.reasoning,
                thought: fallbackResult.thought ?? sanitized.thought,
                toolCalls: fallbackResult.toolCalls
            )
        }

        // === STAGE 4: Heuristic Recovery ===
        return runHeuristicRecovery(sanitized: sanitized, primaryResult: primaryStepWithThought)
    }

    // MARK: - Private Helpers

    /// Classifies a parse result as confident or degraded.
    ///
    /// A result is "degraded" if `toolCalls` is empty AND the sanitized text
    /// contains signals that suggest tool calls were present but unparsed.
    /// A result with zero tools AND no drift signals is genuinely a text-only
    /// response (task termination) and is classified as "confident".
    private func classifyOutcome(
        _ result: ModernCognitiveStep,
        sanitizedText: String
    ) -> ParseOutcome {
        // Non-empty tool calls → confident
        if !result.toolCalls.isEmpty {
            return .confident(result)
        }

        // Explicit empty tool_calls array (e.g., `"tool_calls": []`) is a genuine
        // completion signal — the model intentionally returned no tools. Don't let
        // the drift detector classify this as "degraded" just because it finds the
        // substring `"tool_calls"` in the text. Without this check, Stage 4 sets
        // `parseExhausted = true` on valid completions, causing the executor to
        // inject a corrective alert and retry when the model was genuinely done.
        if containsExplicitEmptyToolCalls(in: sanitizedText) {
            return .confident(result)
        }

        // Zero tool calls → check if we might be missing something
        let detector = FormatDriftDetector(excludedDialect: expectedDialect, knownToolNames: knownToolNames)
        if detector.containsAnySignal(in: sanitizedText) {
            return .degraded(result)
        }

        // No tool signals at all → genuinely a text-only response
        return .confident(result)
    }

    /// Detects an explicit empty `tool_calls` array in the text, distinguishing
    /// a genuine completion (`"tool_calls": []`) from a missed tool call signal.
    private func containsExplicitEmptyToolCalls(in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #""tool_calls"\s*:\s*\[\s*\]"#
        ) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Stage 4: Falls through to the battle-tested `HeuristicCognitiveParser`.
    private func runHeuristicRecovery(
        sanitized: SanitizedOutput,
        primaryResult: ModernCognitiveStep
    ) -> ModernCognitiveStep {
        logger.info("Pipeline: Stage 4 (heuristic recovery).")
        let heuristicResult = HeuristicCognitiveParser.parseLegacyResponse(sanitized.cleaned)

        if !heuristicResult.toolCalls.isEmpty {
            logger.info("Pipeline: Heuristic recovery found \(heuristicResult.toolCalls.count) tool(s).")
            return ModernCognitiveStep(
                reasoning: heuristicResult.reasoning,
                thought: heuristicResult.thought ?? sanitized.thought,
                toolCalls: heuristicResult.toolCalls
            )
        }

        // Nothing worked. Return the primary result (which has reasoning at least).
        // Mark `parseExhausted` so the termination evaluator can distinguish this
        // from a genuine agent completion (where the model intentionally returned
        // empty tool calls). Without this flag, the evaluator treats both cases as
        // `.completed` — which silently terminates the loop on a parse failure.
        logger.info("Pipeline: All stages exhausted. Returning primary result (likely termination).")
        return ModernCognitiveStep(
            reasoning: primaryResult.reasoning,
            thought: primaryResult.thought ?? sanitized.thought,
            toolCalls: primaryResult.toolCalls,
            parseExhausted: true
        )
    }

    /// Logs a `FormatDriftEvent` for observability.
    private func logDriftEvent(detectedFormat: DetectedFormat, toolCount: Int) {
        let event = FormatDriftEvent(
            expectedDialect: expectedDialect,
            detectedFormat: detectedFormat,
            modelId: modelId,
            toolCount: toolCount,
            iteration: iteration,
            timestamp: Date()
        )
        logger.notice("""
            DRIFT_TELEMETRY: expected=\(event.expectedDialect.rawValue) \
            detected=\(event.detectedFormat.rawValue) \
            model=\(event.modelId) tools=\(event.toolCount) \
            iteration=\(event.iteration)
            """)
    }
}

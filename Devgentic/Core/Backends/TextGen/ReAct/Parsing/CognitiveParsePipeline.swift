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

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "CognitiveParsePipeline")

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

    init(expectedDialect: ModelDialect, modelId: String = "unknown", iteration: Int = 0) {
        self.expectedDialect = expectedDialect
        self.modelId = modelId
        self.iteration = iteration
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
        let detector = FormatDriftDetector(excludedDialect: expectedDialect)

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

        // Zero tool calls → check if we might be missing something
        let detector = FormatDriftDetector(excludedDialect: expectedDialect)
        if detector.containsAnySignal(in: sanitizedText) {
            return .degraded(result)
        }

        // No tool signals at all → genuinely a text-only response
        return .confident(result)
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
        logger.info("Pipeline: All stages exhausted. Returning primary result (likely termination).")
        return ModernCognitiveStep(
            reasoning: primaryResult.reasoning,
            thought: primaryResult.thought ?? sanitized.thought,
            toolCalls: primaryResult.toolCalls
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

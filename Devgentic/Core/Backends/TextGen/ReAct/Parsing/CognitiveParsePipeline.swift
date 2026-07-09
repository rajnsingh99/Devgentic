//
//  CognitiveParsePipeline.swift
//  Devgentic
//
//  The Dialect-Anchored Cascade orchestrator for prompt-generated text flows
//  (MLX native-JSON, Ollama content-fallback, legacy JSON-mode, XML/markdown dialects).
//
//  Runs a 5-stage parse sequence:
//
//    Stage 0: OutputSanitizer (always)
//    Stage 1: Primary Parser (expected dialect from CognitiveProfile)
//    Stage 2: FormatDriftDetector (only if Stage 1 is degraded)
//    Stage 3: Fallback Parser (routes on DetectedFormat)
//    Stage 4: HeuristicRecovery (final catch-all)
//    Stage 5: Tool-Name Resolver (validates extracted calls against registry)
//
//  Transport-native flows (Claude/OpenAI/Gemini/Ollama-native) do NOT use this
//  pipeline — they use `NativeParsePipeline` which skips text parsing entirely
//  and runs only the tool-name resolver step.
//
//  Created by Raj Singh on 10/03/26.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "CognitiveParsePipeline")

/// A stateless value type that orchestrates the Dialect-Anchored Cascade.
/// Instantiate per-call with the expected dialect and optional telemetry metadata.
///
/// The public API returns `ModernCognitiveStep` (never throws), with `parseOutcome`
/// set to reflect what happened in the cascade:
///   - `.success`           — at least one validated tool call extracted
///   - `.genuineCompletion` — no tools AND no drift signals AND no error
///   - `.failed(reason)`    — cascade exhausted OR validation rejected the extracted name
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

    /// Registered tools for tool-name resolution at the end of the cascade.
    /// When empty, Stage-5 ToolNameResolver is SKIPPED — extracted tool names
    /// pass through unvalidated as `.success` and a misspelled name only fails
    /// later at dispatch (as a tool failure feeding the circuit breaker, instead
    /// of a typed parse failure with a "did you mean" corrective retry).
    ///
    /// Deliberately NO default value: every call site must decide. Empty is
    /// correct ONLY where validation is layered above (provider content-fallback
    /// parses re-validated by `NativeParsePipeline` one level up) or where no
    /// dispatch follows (pure-parse tests). Six call sites silently opted out
    /// of validation for months because this parameter used to default to `[]`.
    let registeredTools: [AgentTool]

    init(
        expectedDialect: ModelDialect,
        modelId: String = "unknown",
        iteration: Int = 0,
        knownToolNames: Set<String> = [],
        registeredTools: [AgentTool]
    ) {
        self.expectedDialect = expectedDialect
        self.modelId = modelId
        self.iteration = iteration
        self.knownToolNames = knownToolNames
        self.registeredTools = registeredTools
    }

    // MARK: - Public API

    /// Parses raw LLM output through the cascade.
    /// Never throws — degrades gracefully to a typed `.failed` outcome on total failure.
    ///
    /// - Parameter raw: The unmodified text string returned by the model.
    /// - Returns: A `ModernCognitiveStep` with zero or more validated tool calls
    ///            and a `parseOutcome` describing what happened.
    func parse(raw: String) -> ModernCognitiveStep {

        // Raw-input trace so cascade failures can be diagnosed from logs alone.
        let rawPreview = raw.count > 800 ? String(raw.prefix(800)) + "…[+\(raw.count - 800) chars]" : raw
        logger.debug("Pipeline: parse(raw=\(raw.count)B, dialect=\(expectedDialect.rawValue)) — input: \(rawPreview)")

        // === STAGE 0: Pre-Sanitization ===
        let sanitized = OutputSanitizer.sanitize(raw)

        guard !sanitized.cleaned.isEmpty else {
            logger.warning("Pipeline: Sanitized output is empty (raw was \(raw.count)B). Returning .emptyOutput failure.")
            return ModernCognitiveStep(
                reasoning: raw,
                thought: sanitized.thought,
                toolCalls: [],
                parseOutcome: .failed(.emptyOutput)
            )
        }

        if sanitized.cleaned.count != raw.count {
            logger.debug("Pipeline: sanitized=\(sanitized.cleaned.count)B (from raw=\(raw.count)B)")
        }

        // === STAGE 1: Primary Parser (expected dialect) ===
        let primaryParser = ParserFactory.createParser(for: expectedDialect)
        let primaryResult = primaryParser.parse(rawResponse: sanitized.cleaned)

        // Propagate extracted thought from sanitizer if parser didn't find one,
        // and forward any typed parseOutcome the primary parser may have set
        // (e.g. HeuristicCognitiveParser flags `.schemaKeyMismatch` when all its
        // internal schemas reject a well-formed JSON object).
        let primaryStepWithThought = ModernCognitiveStep(
            reasoning: primaryResult.reasoning,
            thought: primaryResult.thought ?? sanitized.thought,
            toolCalls: primaryResult.toolCalls,
            tokenUsage: primaryResult.tokenUsage,
            parseOutcome: primaryResult.parseOutcome
        )

        // Short-circuit: primary parser explicitly flagged a typed failure.
        // Skip drift + heuristic recovery (the parser already tried its full
        // cascade) and return the failure. Preserves the typed reason so the
        // terminator routes to `.suspectedFormatFailure` with specific context.
        if case .failed = primaryStepWithThought.parseOutcome {
            logger.info("Pipeline: Stage 1 flagged typed failure — short-circuiting cascade.")
            return primaryStepWithThought
        }

        let primaryConfidence = classifyConfidence(primaryStepWithThought, sanitizedText: sanitized.cleaned)

        if primaryConfidence.isConfident {
            logger.info("Pipeline: Stage 1 confident. dialect=\(expectedDialect.rawValue) tools=\(primaryResult.toolCalls.count)")
            return resolveAndFinalize(
                step: primaryStepWithThought,
                sanitizedText: sanitized.cleaned,
                rawText: raw,
                stageTag: "stage1-primary"
            )
        }

        // === STAGE 2: Format Drift Detection ===
        let detector = FormatDriftDetector(excludedDialect: expectedDialect, knownToolNames: knownToolNames)

        guard let detectedFormat = detector.detect(in: sanitized.cleaned) else {
            // No drift pattern found.
            // If primary returned zero tools, give heuristic one shot before giving up.
            if primaryResult.toolCalls.isEmpty {
                return runHeuristicRecovery(
                    sanitized: sanitized,
                    primaryResult: primaryStepWithThought,
                    rawText: raw
                )
            }
            logger.info("Pipeline: Stage 2 found no drift. Returning primary result.")
            return resolveAndFinalize(
                step: primaryStepWithThought,
                sanitizedText: sanitized.cleaned,
                rawText: raw,
                stageTag: "stage2-no-drift"
            )
        }

        logger.notice("Pipeline: DRIFT detected. expected=\(expectedDialect.rawValue) actual=\(detectedFormat.rawValue)")

        // === STAGE 3: Fallback Parser ===
        let fallbackParser = ParserFactory.createFallbackParser(for: detectedFormat)
        let fallbackResult = fallbackParser.parse(rawResponse: sanitized.cleaned)

        if !fallbackResult.toolCalls.isEmpty {
            logger.info("Pipeline: Stage 3 succeeded. tools=\(fallbackResult.toolCalls.count) via=\(detectedFormat.rawValue)")
            logDriftEvent(detectedFormat: detectedFormat, toolCount: fallbackResult.toolCalls.count)
            let stepWithThought = ModernCognitiveStep(
                reasoning: fallbackResult.reasoning,
                thought: fallbackResult.thought ?? sanitized.thought,
                toolCalls: fallbackResult.toolCalls
            )
            return resolveAndFinalize(
                step: stepWithThought,
                sanitizedText: sanitized.cleaned,
                rawText: raw,
                stageTag: "stage3-drift-\(detectedFormat.rawValue)"
            )
        }

        // === STAGE 4: Heuristic Recovery ===
        return runHeuristicRecovery(sanitized: sanitized, primaryResult: primaryStepWithThought, rawText: raw)
    }

    // MARK: - Stage 5: Resolver + Finalize

    /// Runs the tool-name resolver on any extracted tool calls and returns the final step.
    /// Empty `toolCalls` at this point (after a successful confident path) means the model
    /// intentionally produced no calls — that's `.genuineCompletion`.
    private func resolveAndFinalize(
        step: ModernCognitiveStep,
        sanitizedText: String,
        rawText: String,
        stageTag: String
    ) -> ModernCognitiveStep {

        if step.toolCalls.isEmpty {
            // Reached here only on a confident path with zero tools — pure text completion.
            return ModernCognitiveStep(
                reasoning: step.reasoning,
                thought: step.thought,
                toolCalls: [],
                tokenUsage: step.tokenUsage,
                parseOutcome: .genuineCompletion
            )
        }

        // With no registry, nothing to validate against — pass through as success.
        guard !registeredTools.isEmpty else {
            return ModernCognitiveStep(
                reasoning: step.reasoning,
                thought: step.thought,
                toolCalls: step.toolCalls,
                tokenUsage: step.tokenUsage,
                parseOutcome: .success
            )
        }

        let resolver = ToolNameResolver(registeredTools: registeredTools)
        var validated: [PendingToolCall] = []
        var firstFailure: ParseFailureReason?

        for call in step.toolCalls {
            switch resolver.resolve(emittedName: call.name, arguments: call.arguments) {
            case .exact(let name, let args):
                validated.append(PendingToolCall(id: call.id, name: name, arguments: args))
            case .remapped(_, let canonicalName, let args, _):
                validated.append(PendingToolCall(id: call.id, name: canonicalName, arguments: args))
            case .argSchemaMismatch(let attempted, let resolvedTo, let missing, let unexpected):
                if firstFailure == nil {
                    firstFailure = .argSchemaMismatch(
                        attempted: attempted,
                        resolvedTo: resolvedTo,
                        missingArgs: missing,
                        unexpectedArgs: unexpected
                    )
                }
            case .unknown(let attempted, let suggestions):
                if firstFailure == nil {
                    firstFailure = .unknownToolName(
                        attempted: attempted,
                        suggestions: suggestions
                    )
                }
            }
        }

        let outcome: ParseOutcome
        if !validated.isEmpty {
            outcome = .success
        } else if let reason = firstFailure {
            logger.warning("Pipeline (\(stageTag)): all extracted calls failed validation — \(String(describing: reason))")
            outcome = .failed(reason)
        } else {
            outcome = .genuineCompletion
        }

        return ModernCognitiveStep(
            reasoning: step.reasoning,
            thought: step.thought,
            toolCalls: validated,
            tokenUsage: step.tokenUsage,
            parseOutcome: outcome
        )
    }

    // MARK: - Private Helpers

    /// Classifies a parse result as confident or degraded.
    ///
    /// A result is "degraded" if `toolCalls` is empty AND the sanitized text
    /// contains signals that suggest tool calls were present but unparsed.
    /// A result with zero tools AND no drift signals is genuinely a text-only
    /// response (task termination) and is classified as "confident".
    private func classifyConfidence(
        _ result: ModernCognitiveStep,
        sanitizedText: String
    ) -> ParseConfidence {
        // Non-empty tool calls → confident
        if !result.toolCalls.isEmpty {
            return .confident(result)
        }

        // Explicit empty tool_calls array (e.g., `"tool_calls": []`) is a genuine
        // completion signal — the model intentionally returned no tools. Don't let
        // the drift detector classify this as "degraded" just because it finds the
        // substring `"tool_calls"` in the text.
        if containsExplicitEmptyToolCalls(in: sanitizedText) {
            return .confident(result)
        }

        // When primary returned 0 tools AND the sanitized text clearly contains a
        // JSON object (and we're on a JSON dialect), route to .degraded so Stage 4
        // heuristic recovery gets a shot at bare shapes like `{"name": "...", "arguments": {...}}`
        // that the strict NativeJSONParser misses.
        // Previously this case was only rescued by `NativeJSONParser` internally
        // delegating to the heuristic — we killed that internal delegation, so the
        // pipeline layer has to own the route now.
        if isJsonDialect(expectedDialect) && containsJSONObjectShape(in: sanitizedText) {
            return .degraded(result)
        }

        // Zero tool calls → check if we might be missing something via drift probes
        let detector = FormatDriftDetector(excludedDialect: expectedDialect, knownToolNames: knownToolNames)
        if detector.containsAnySignal(in: sanitizedText) {
            return .degraded(result)
        }

        // Last-ditch signal: short output that mentions a registered tool name.
        // Catches function-call-like prose that no drift probe recognizes — e.g.
        // `codebase_map path: "/..."` from qwen2.5-coder:32b. If the model named
        // a tool but didn't wrap it in any recognized structure, that's almost
        // certainly a broken tool-call attempt, not a genuine text completion.
        // Length gate avoids flagging long prose answers that happen to mention
        // a tool name (e.g. "I used `codebase_map` to map the project, then...").
        if firstMentionedToolName(in: sanitizedText) != nil {
            return .degraded(result)
        }

        // No tool signals at all → genuinely a text-only response
        return .confident(result)
    }

    /// Whether the expected dialect is one whose payload is a JSON object.
    /// Controls whether "primary returned empty but text has braces" should route
    /// through heuristic recovery.
    private func isJsonDialect(_ dialect: ModelDialect) -> Bool {
        switch dialect {
        case .nativeJSON, .heuristicJson, .qwenHermesToolCall, .llama3JsonSingle,
             .mistralV3Array, .phiFunctoolsBracket, .deepseekV3JsonFence,
             .graniteLegacyArray, .granite4ToolCall, .commandRAction, .commandR7BAction,
             .deepseekV31Flat:
            // All have JSON object/array at the core; heuristic recovery is a useful fallback.
            return true
        case .mistralXML, .reactMarkdown, .mistralV11Flat, .pythonicBracketList,
             .qwen3CoderDeepXml, .deepseekV32Dsml:
            // Marker-delimited / structural XML / Python syntax — no pure JSON at core.
            // Heuristic JSON recovery won't help — drift detector handles degraded states.
            return false
        }
    }

    /// Cheap scan for a top-level JSON object or array shape.
    /// Avoids matching stray `{` in prose by requiring both an opener and a closer.
    private func containsJSONObjectShape(in text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Must contain both an opener and a closer to look like an object.
        let hasObject = trimmed.contains("{") && trimmed.contains("}")
        let hasArray  = trimmed.contains("[") && trimmed.contains("]")
        return hasObject || hasArray
    }

    /// Returns the first registered tool name that appears in `text`, or nil.
    ///
    /// Intentional length gate: only scans short outputs (< 300 chars). Long prose
    /// answers legitimately reference tools by name ("I used `codebase_map` to
    /// understand the structure, then..."), and we don't want to misclassify those
    /// as format failures. The failure pattern we're catching is *short*
    /// function-call-shaped emissions that no parser recognizes — e.g.
    /// `codebase_map path: "/..."` from qwen2.5-coder:32b — where the short length
    /// + tool name presence together are high-signal for "broken tool call".
    private func firstMentionedToolName(in text: String) -> String? {
        guard !registeredTools.isEmpty else { return nil }
        guard text.count < 300 else { return nil }
        let lower = text.lowercased()
        return registeredTools
            .first { lower.contains($0.name.lowercased()) }?
            .name
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
    /// If heuristic finds tools → resolve + finalize normally.
    /// If heuristic also fails → return `.failed` with a typed reason reflecting
    /// what we could infer about why parsing died.
    private func runHeuristicRecovery(
        sanitized: SanitizedOutput,
        primaryResult: ModernCognitiveStep,
        rawText: String
    ) -> ModernCognitiveStep {
        logger.info("Pipeline: Stage 4 (heuristic recovery).")
        let heuristicResult = HeuristicCognitiveParser.parseLegacyResponse(sanitized.cleaned)

        if !heuristicResult.toolCalls.isEmpty {
            logger.info("Pipeline: Heuristic recovery found \(heuristicResult.toolCalls.count) tool(s).")
            let step = ModernCognitiveStep(
                reasoning: heuristicResult.reasoning,
                thought: heuristicResult.thought ?? sanitized.thought,
                toolCalls: heuristicResult.toolCalls
            )
            return resolveAndFinalize(
                step: step,
                sanitizedText: sanitized.cleaned,
                rawText: rawText,
                stageTag: "stage4-heuristic"
            )
        }

        // Nothing worked. Classify WHY it didn't work from what's in the sanitized text.
        let reason = inferFailureReason(
            sanitizedText: sanitized.cleaned,
            primaryReasoning: primaryResult.reasoning
        )

        logger.info("Pipeline: All stages exhausted. Failure reason: \(String(describing: reason))")
        return ModernCognitiveStep(
            reasoning: primaryResult.reasoning.isEmpty ? rawText : primaryResult.reasoning,
            thought: primaryResult.thought ?? sanitized.thought,
            toolCalls: [],
            parseOutcome: .failed(reason)
        )
    }

    /// Best-effort classification of WHY the cascade failed, based on the sanitized text.
    /// The distinctions drive different corrective alerts to the model.
    private func inferFailureReason(sanitizedText: String, primaryReasoning: String) -> ParseFailureReason {
        let text = sanitizedText
        let lowered = text.lowercased()
        let preview = String(text.prefix(200))

        // Empty after sanitization
        if text.isEmpty {
            return .emptyOutput
        }

        // JSON-ish object present but decode failed — report as malformed
        if text.contains("{") && text.contains("}") {
            // Look for common wrong-schema keys that wouldn't be caught by any parser.
            let knownWrongKeys = [
                "\"function_name\"", "\"function\"", "\"func\"",
                "\"parameters\"", "\"input\"", "\"args\""
            ]
            let foundWrong = knownWrongKeys.filter { text.contains($0) }
            if !foundWrong.isEmpty {
                let strippedFound = foundWrong.map { $0.replacingOccurrences(of: "\"", with: "") }
                return .schemaKeyMismatch(
                    expectedKeys: ["name", "arguments"],
                    foundKeys: strippedFound,
                    rawSnippet: preview
                )
            }
            return .malformedJSON(syntaxDetail: "JSON object present but could not be decoded", rawSnippet: preview)
        }

        // Registered tool name mentioned in short prose — high-signal case where we
        // know exactly which tool the model attempted. The corrective alert can name
        // the tool and show the expected JSON shape precisely.
        // Checked BEFORE the generic prose-description match because it's more specific.
        if let toolName = firstMentionedToolName(in: text) {
            return .toolNameInProse(toolName: toolName, snippet: preview)
        }

        // Model narrated a tool-call intent but didn't emit structured output
        let proseTriggers = ["i will call", "i'll call", "i will use", "let me use", "i need to call", "calling the", "now i'll"]
        if proseTriggers.contains(where: { lowered.contains($0) }) {
            return .proseDescribedIntent(snippet: preview)
        }

        // Pure prose, no structured output at all
        return .noStructuredOutput(snippet: preview)
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

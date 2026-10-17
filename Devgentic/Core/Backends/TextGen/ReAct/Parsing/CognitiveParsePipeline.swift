// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// Known tool names — the run's full loadout where the caller has it (`SemanticContext
    /// .runToolNames`, the Ollama request's tools), else this iteration's registry.
    /// Passed to `FormatDriftDetector` for precise dynamic-tag detection (Phase B), and read by
    /// `AttemptedToolCallGrammar` (via `callableNames`) to recognise a call by its tool name.
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

    /// The names an attempted call is recognised against (`AttemptedToolCallGrammar` rule 1):
    /// this iteration's registry plus `knownToolNames` — which callers widen to the run's full
    /// loadout, so a broken call to a tool withheld from this iteration's schema still counts.
    private var callableNames: Set<String> {
        Set(registeredTools.map(\.name)).union(knownToolNames)
    }

    // MARK: - Public API

    /// Parses raw LLM output through the cascade.
    /// Never throws — degrades gracefully to a typed `.failed` outcome on total failure.
    ///
    /// - Parameter raw: The unmodified text string returned by the model.
    /// - Returns: A `ModernCognitiveStep` with zero or more validated tool calls
    ///            and a `parseOutcome` describing what happened.
    func parse(raw: String) -> ModernCognitiveStep {
        // ⚠️ CR-3: fences INSIDE a call's JSON string values are shielded from the sanitizer's strip
        // and restored after parsing — see `CodeFenceShield`. Shielding only ever changes characters
        // inside string literals, so the calls found are the ones the unshielded parse finds.
        let shielded = CodeFenceShield.shield(raw)
        guard shielded.count > 0 else {
            return restoringCodeFences(in: cascade(raw: raw), raw: raw, parsedText: raw)
        }
        let step = cascade(raw: shielded.text)
        if case .failed = step.parseOutcome {
            // A failure's diagnostics quote the parsed text back to the model; never let the
            // placeholder reach it. The unshielded parse is exactly the pre-CR-3 behaviour.
            logger.notice("[PARSE] Parse with \(shielded.count) shielded code fence(s) failed [model \(modelId) iter \(iteration)]. CONSEQUENCE: re-parsed unshielded, as before CR-3 — the corrective message quotes the reply without placeholders.")
            return restoringCodeFences(in: cascade(raw: raw), raw: raw, parsedText: raw)
        }
        if !step.toolCalls.isEmpty {
            logger.info("[PARSE] Kept \(shielded.count) code fence(s) inside tool-call arguments [model \(modelId) iter \(iteration)]. CONSEQUENCE: argument values carry the ``` the model wrote; fences around the call were still stripped.")
        }
        return restoringCodeFences(in: CodeFenceShield.unshield(step), raw: raw, parsedText: shielded.text)
    }

    /// ⚠️ A PLAIN ANSWER KEEPS ITS CODE BLOCKS (2026-10-06). The cascade parses fence-free text —
    /// `OutputSanitizer.sanitize` strips every ``` so no parser trips on them — and the text a
    /// parser hands back as the answer was that same fence-free text. So every plain answer with
    /// code reached the user without its blocks: T2's JSON example and `[7, 1, 5]` arrived as bare
    /// lines, and a ```java fence even left a stray `java` line (the stripper knows five language
    /// names). Parsing is untouched; only the text of a `.genuineCompletion` changes, and only when
    /// the parser's answer IS the whole sanitized reply. A parser that took PART of it (ReAct's
    /// `Final Answer:`, a tagged final answer) keeps its own text: swapping in the whole reply would
    /// leak the scaffolding around it.
    ///
    /// - Parameter parsedText: what the cascade actually read (the shielded reply, when fences inside
    ///   string literals were shielded), so the "is this the whole reply" comparison compares like
    ///   with like.
    private func restoringCodeFences(in step: ModernCognitiveStep, raw: String, parsedText: String) -> ModernCognitiveStep {
        guard case .genuineCompletion = step.parseOutcome, raw.contains("```") else { return step }
        let fenceFree = CodeFenceShield.unshield(OutputSanitizer.sanitize(parsedText, preservingCallMarkers: true).cleaned)
        guard step.reasoning.trimmingCharacters(in: .whitespacesAndNewlines) == fenceFree else { return step }
        let fenced = OutputSanitizer.sanitize(raw, preservingCallMarkers: true, keepingCodeFences: true).cleaned
        guard fenced != step.reasoning else { return step }
        return ModernCognitiveStep(
            reasoning: fenced,
            thought: step.thought,
            toolCalls: step.toolCalls,
            tokenUsage: step.tokenUsage,
            parseOutcome: step.parseOutcome,
            reasoningReplay: step.reasoningReplay,
            callsRecoveredFromText: step.callsRecoveredFromText
        )
    }

    private func cascade(raw: String) -> ModernCognitiveStep {
        // Raw-input trace so cascade failures can be diagnosed from logs alone.
        let rawPreview = raw.count > 800 ? String(raw.prefix(800)) + "…[+\(raw.count - 800) chars]" : raw
        logger.debug("Pipeline: parse(raw=\(raw.count)B, dialect=\(expectedDialect.rawValue)) — input: \(rawPreview)")

        // === STAGE 0: Pre-Sanitization ===
        // Stage 0: calls MLXLMCommon already decoded. They are structured, so they skip every
        // dialect parser — whose bare-JSON fallbacks kept only the first call and dropped the prose.
        if let framework = FrameworkToolCallEnvelope.extract(from: raw), framework.calls.isEmpty,
           let discarded = framework.discardedTokens {
            // A call the model wrote and the runtime could not read. Typed, so the model is told
            // and the next attempt differs; a blind retry of the same prompt reproduced it 3 of 3.
            logger.warning("[MLX-TOOLCALL] Stage 0 — the framework discarded a \(discarded)-token tool call it could not decode (dialect=\(expectedDialect.rawValue), iter \(iteration)). CONSEQUENCE: a format failure — the model gets the corrective alert and retries, charged to the parse budget.")
            return ModernCognitiveStep(
                reasoning: OutputSanitizer.sanitize(framework.remainder).cleaned,
                toolCalls: [],
                parseOutcome: .failed(.malformedJSON(
                    syntaxDetail: "the runtime discarded the \(discarded)-token tool call you wrote because it could not be decoded",
                    rawSnippet: ""))
            )
        }
        if let framework = FrameworkToolCallEnvelope.extract(from: raw), !framework.calls.isEmpty {
            let prose = OutputSanitizer.sanitize(framework.remainder)
            logger.info("Pipeline: Stage 0 — \(framework.calls.count) framework-decoded tool call(s): \(framework.calls.map(\.name).joined(separator: ", ")); \(prose.cleaned.count) chars of text alongside.")
            return resolveAndFinalize(
                step: ModernCognitiveStep(reasoning: prose.cleaned, thought: prose.thought, toolCalls: framework.calls),
                sanitizedText: prose.cleaned,
                rawText: raw,
                stageTag: "stage0-framework"
            )
        }

        let sanitized = OutputSanitizer.sanitize(raw, preservingCallMarkers: true)
        // What `AttemptedToolCallGrammar` reads — the reply minus `<think>` blocks and NOTHING else.
        // Not `sanitized.cleaned`: the sanitizer strips fences (```tool_code) and `<|…|>` tokens,
        // which are evidence of a call. Not `raw`: a call the model only considered while thinking
        // is not an attempt.
        let callEvidence = OutputSanitizer.stripThinkBlocks(raw)

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
            return answerUnlessAttemptedCall(primaryStepWithThought, callEvidence: callEvidence, stage: "stage1-typed")
        }

        let primaryConfidence = classifyConfidence(
            primaryStepWithThought, sanitizedText: sanitized.cleaned, callEvidence: callEvidence)

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
                    rawText: raw,
                    callEvidence: callEvidence
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
        return runHeuristicRecovery(
            sanitized: sanitized, primaryResult: primaryStepWithThought, rawText: raw, callEvidence: callEvidence)
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
        var unknownNames: [String] = []
        var rejected: [RejectedSiblingCall] = []

        for call in step.toolCalls {
            switch resolver.resolve(emittedName: call.name, arguments: call.arguments) {
            case .exact(let name, let args):
                validated.append(PendingToolCall(id: call.id, name: name, arguments: coercingToSchema(args, tool: name)))
            case .remapped(_, let canonicalName, let args, _):
                validated.append(PendingToolCall(id: call.id, name: canonicalName,
                                                 arguments: coercingToSchema(args, tool: canonicalName)))
            case .argSchemaMismatch(let attempted, let resolvedTo, let missing, let unexpected):
                let reason = ParseFailureReason.argSchemaMismatch(
                    attempted: attempted, resolvedTo: resolvedTo, missingArgs: missing, unexpectedArgs: unexpected)
                rejected.append(RejectedSiblingCall(call: call, reason: reason))
                if firstFailure == nil { firstFailure = reason }
            case .unknown(let attempted, let suggestions):
                unknownNames.append(attempted)
                let reason = ParseFailureReason.unknownToolName(attempted: attempted, suggestions: suggestions)
                rejected.append(RejectedSiblingCall(call: call, reason: reason))
                if firstFailure == nil { firstFailure = reason }
            }
        }

        // ⚠️ A JSON object in the ANSWER is not a call (bug 3, 2026-10-06). The bare-JSON
        // fallbacks (`QwenHermesJsonParser` style 3, `HeuristicCognitiveParser` attempt 3) accept
        // any object with a `name` key, so `{"name": "John Doe", "email": …}` — the user record
        // T2 asked for — became a call to a tool named "John Doe" (and `{"name": "", …}` one named
        // ""), and correct answers were retried until the run ended on a fabricated one. Fixing
        // the extractors would break real argument-less calls; the verdict is the right place,
        // as for `answerUnlessAttemptedCall`. Qualifies only when EVERY call is to an unknown
        // name, and never for `stage0-framework`, whose calls the runtime decoded from a real
        // call protocol. The grammar decides: a name key with an arguments object, a run tool's
        // name or a call-format token (`<tool_call>` …) keeps it a call.
        if validated.isEmpty, !unknownNames.isEmpty, unknownNames.count == step.toolCalls.count,
           stageTag != "stage0-framework",
           AttemptedToolCallGrammar.attemptedCallName(
               in: OutputSanitizer.stripThinkBlocks(rawText), callableNames: callableNames) == nil {
            logger.notice("[PARSE_VERDICT] \(stageTag) dialect=\(expectedDialect.rawValue) model=\(modelId) iter \(iteration): recovered \(unknownNames.count) 'call(s)' to tool(s) this run does not offer (\(unknownNames.map { "'\($0)'" }.joined(separator: ", "))) and the reply declares no attempted call. CONSEQUENCE: the reply is the final answer; it is NOT retried as an unknown tool.")
            return ModernCognitiveStep(
                reasoning: sanitizedText,
                thought: step.thought,
                toolCalls: [],
                tokenUsage: step.tokenUsage,
                parseOutcome: .genuineCompletion
            )
        }

        let outcome: ParseOutcome
        if !validated.isEmpty {
            outcome = .success
            // [CR-52] A partial batch used to drop its failed calls without a word, here and to the
            // model. Logged now, and handed on so the loop reports each one as not run.
            if !rejected.isEmpty {
                logger.warning("[PARSE_VERDICT] \(stageTag) dialect=\(expectedDialect.rawValue) model=\(modelId) iter \(iteration): \(validated.count) call(s) validated, \(rejected.count) REJECTED: \(rejected.map { "\($0.call.name) (\(String(describing: $0.reason)))" }.joined(separator: "; ")). CONSEQUENCE: the valid calls run; each rejected one is reported to the model as not run, with its reason, instead of vanishing.")
            }
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
            parseOutcome: outcome,
            rejectedCalls: validated.isEmpty ? [] : rejected
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
        sanitizedText: String,
        callEvidence: String
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

        // An attempted call none of the signals above can see — the declared grammar's verdict.
        // A call CUT OFF mid-generation has no closing brace or tag, a format with no drift probe
        // has nothing to match, and a paragraph of prose before either defeats the short-text rule.
        // These used to be called "confident" prose and shown to the user as the answer on ~18 of
        // 19 paths (2026-10-05 audit). Degraded routes them through recovery: a complete call is
        // recovered there; a cut-off one ends as a typed failure that `answerUnlessAttemptedCall`
        // keeps (same grammar, same text), so the model is corrected and retries.
        if let attempted = AttemptedToolCallGrammar.attemptedCallName(in: callEvidence, callableNames: callableNames) {
            logger.info("[PARSE_VERDICT] dialect=\(expectedDialect.rawValue) model=\(modelId) iter \(iteration): no call parsed and no shape signal, but the text declares an attempted call ('\(attempted)'). CONSEQUENCE: routed to recovery instead of being accepted as the final answer.")
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

    /// String arguments typed by the tool's DECLARED schema (CR-21).
    ///
    /// Only a `.string` whose schema says number/integer/boolean/array/object, and only when the text
    /// genuinely is that type — `"5"` for an integer becomes 5, `"maybe"` for a boolean stays a string
    /// so the tool reports a precise error. A `"string"` parameter is never touched: that is what lets
    /// `write_file` content that happens to be JSON stay text.
    private func coercingToSchema(_ arguments: [String: JSONValue], tool name: String) -> [String: JSONValue] {
        guard let schema = registeredTools.first(where: { $0.name == name })?.parameters else { return arguments }
        return Self.coercingToSchema(arguments, schema: schema)
    }

    static func coercingToSchema(_ arguments: [String: JSONValue], schema: ToolParameters) -> [String: JSONValue] {
        arguments.reduce(into: [:]) { out, pair in
            let (key, value) = pair
            guard case .string(let text) = value, let declared = schema.properties[key]?.type else {
                out[key] = value; return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch declared {
            case "number", "integer":
                if let d = Double(trimmed), d.isFinite { out[key] = .number(d); return }
            case "boolean":
                if trimmed.lowercased() == "true" { out[key] = .bool(true); return }
                if trimmed.lowercased() == "false" { out[key] = .bool(false); return }
            case "array", "object":
                if let data = trimmed.data(using: .utf8), let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    switch (declared, decoded) {
                    case ("array", .array), ("object", .object): out[key] = decoded; return
                    default: break
                    }
                }
            default:
                break
            }
            out[key] = value
        }
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
        return registeredTools.first { Self.mentionsAsACall(lower, name: $0.name.lowercased()) }?.name
    }

    /// Whether `name` appears in `text` the way a broken call would write it.
    ///
    /// ⚠️⚠️ NOT a substring (readiness CR-20, 2026-10-10). `lower.contains(name)` made ordinary prose
    /// a format failure: Code profiles always register `forget`/`recall`/`remember`, and `git` is a
    /// tool, so "did you forget the extension?" and "it has 7 digits" (d-i-GIT-s) were retried as
    /// broken calls. Now: a WHOLE identifier, and — for a name that is also an ordinary word (no `_`)
    /// — followed by call punctuation (`(`, `{`, `:` or `=`), the shape of `codebase_map path: …`.
    static func mentionsAsACall(_ text: String, name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let whole = "(?<![a-z0-9_])\(escaped)(?![a-z0-9_])"
        let pattern = name.contains("_") ? whole : whole + "\\s*[({:=]"
        return text.range(of: pattern, options: .regularExpression) != nil
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
        rawText: String,
        callEvidence: String
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
        return answerUnlessAttemptedCall(
            ModernCognitiveStep(
                reasoning: primaryResult.reasoning.isEmpty ? rawText : primaryResult.reasoning,
                thought: primaryResult.thought ?? sanitized.thought,
                toolCalls: [],
                parseOutcome: .failed(reason)
            ),
            callEvidence: callEvidence,
            stage: "stage4-exhausted"
        )
    }

    // MARK: - Answer-vs-call verdict

    /// A failure that only means "we found no call in this text" becomes the ANSWER,
    /// unless the text declares an attempted call (`AttemptedToolCallGrammar`).
    ///
    /// Why: the cascade routes any reply containing `{…}` or `[…]` to heuristic recovery
    /// on JSON-family dialects. When recovery finds nothing, the reasons below were then
    /// reported as format failures — for `{7, 1, 5}`, `int[] prices`, `prices[i]`, a
    /// Markdown link, a ```json analysis block. Probe 2026-10-05: 12 of 18 dialects
    /// rejected every one of those answers, and a plain-prose answer passed on all 18.
    /// Routing is untouched — recovery still gets its shot at every odd call shape; only
    /// the verdict when it recovers NOTHING changes.
    ///
    /// Scope, deliberately narrow:
    ///   - Only with a registry. An EMPTY `registeredTools` marks a provider-level parse
    ///     (Ollama/MLX content fallback) whose verdict `NativeParsePipeline` re-decides
    ///     against the run's real tool names — deciding here would pre-empt it blind.
    ///   - Only `.malformedJSON`, `.noStructuredOutput`, `.schemaKeyMismatch`. Drift,
    ///     `.toolNameInProse`, `.proseDescribedIntent`, tool-name failures and
    ///     `.emptyOutput` keep their existing meaning.
    private func answerUnlessAttemptedCall(
        _ step: ModernCognitiveStep,
        callEvidence: String,
        stage: String
    ) -> ModernCognitiveStep {
        guard !registeredTools.isEmpty, case .failed(let reason) = step.parseOutcome else { return step }
        switch reason {
        case .malformedJSON, .noStructuredOutput, .schemaKeyMismatch: break
        default: return step
        }
        guard !step.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return step }

        if let attempted = AttemptedToolCallGrammar.attemptedCallName(in: callEvidence, callableNames: callableNames) {
            logger.info("[PARSE_VERDICT] \(stage) dialect=\(expectedDialect.rawValue) model=\(modelId) iter \(iteration): '\(reason.uiChipLabel)' kept — the text declares an attempted call ('\(attempted)'). CONSEQUENCE: corrective retry.")
            return step
        }
        logger.notice("[PARSE_VERDICT] \(stage) dialect=\(expectedDialect.rawValue) model=\(modelId) iter \(iteration): '\(reason.uiChipLabel)' overridden — recovery found no call and the text declares none (\(callEvidence.count) chars). CONSEQUENCE: the text is the final answer; it is NOT retried.")
        return ModernCognitiveStep(
            reasoning: step.reasoning,
            thought: step.thought,
            toolCalls: [],
            tokenUsage: step.tokenUsage,
            parseOutcome: .genuineCompletion
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

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CognitiveParsePipeline.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "CognitiveParsePipeline")

/// A stateless value type that orchestrates the Dialect-Anchored Cascade; instantiate per call with the expected dialect.
/// `parse` never throws; `parseOutcome` is `.success` (a validated tool call), `.genuineCompletion` (no tools, no drift
/// signals, no error) or `.failed(reason)` (cascade exhausted or validation rejected the extracted name).
struct CognitiveParsePipeline: Sendable {

    /// The dialect we EXPECT this model to produce (from CognitiveProfile).
    let expectedDialect: ModelDialect

    /// Optional model identifier for drift telemetry.
    let modelId: String

    /// Optional iteration number for drift telemetry.
    let iteration: Int

    /// Known tool names: the run's full loadout where the caller has it, else this iteration's registry.
    /// Passed to `FormatDriftDetector` for dynamic-tag detection and read by `AttemptedToolCallGrammar` (via `callableNames`)
    /// to recognise a call by its tool name.
    let knownToolNames: Set<String>

    // Why: no default value: every call site must decide; defaulting to `[]` silently opted call sites out of validation
    /// Registered tools for tool-name resolution at the end of the cascade.
    /// When empty, name resolution is skipped: extracted names pass through unvalidated as `.success` and a misspelling only
    /// fails at dispatch. Empty is correct only where validation is layered above or no dispatch follows.
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

    /// Parses raw LLM output through the cascade; never throws, degrading to a typed `.failed` outcome on total failure.
    /// - Parameter raw: the unmodified text returned by the model.
    /// - Returns: a `ModernCognitiveStep` with zero or more validated tool calls and a `parseOutcome`.
    func parse(raw: String) -> ModernCognitiveStep {
        // Fences inside a call's JSON string values are shielded from the sanitizer's strip and restored after parsing (see
        // `CodeFenceShield`); shielding only changes characters inside string literals, so the same calls are found.
        let shielded = CodeFenceShield.shield(raw)
        guard shielded.count > 0 else {
            return restoringCodeFences(in: cascade(raw: raw), raw: raw, parsedText: raw)
        }
        let step = cascade(raw: shielded.text)
        if case .failed = step.parseOutcome {
            // A failure's diagnostics quote the parsed text back to the model, so the shield placeholder must never reach it.
            logger.notice("[PARSE] Parse with \(shielded.count) shielded code fence(s) failed [model \(modelId) iter \(iteration)]. CONSEQUENCE: re-parsed unshielded, as before CR-3 — the corrective message quotes the reply without placeholders.")
            return restoringCodeFences(in: cascade(raw: raw), raw: raw, parsedText: raw)
        }
        if !step.toolCalls.isEmpty {
            logger.info("[PARSE] Kept \(shielded.count) code fence(s) inside tool-call arguments [model \(modelId) iter \(iteration)]. CONSEQUENCE: argument values carry the ``` the model wrote; fences around the call were still stripped.")
        }
        return restoringCodeFences(in: CodeFenceShield.unshield(step), raw: raw, parsedText: shielded.text)
    }

    /// Restores code fences in a plain answer, which the fence-free cascade text would otherwise lose. Applies
    /// only when the parser's answer is the whole sanitized reply; a partial answer keeps its own text.
    /// - Parameter parsedText: what the cascade actually read (the shielded reply, if shielded).
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

        // Stage 0: calls MLXLMCommon already decoded are structured, so they skip every dialect parser, whose bare-JSON
        // fallbacks keep only the first call and drop the prose.
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
        // What `AttemptedToolCallGrammar` reads: the reply minus `<think>` blocks only. The sanitized text would
        // drop fences and `<|…|>` tokens, which are call evidence.
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

        // Propagates the sanitizer's thought if the parser found none, and forwards any typed `parseOutcome` the
        // parser set (e.g. `.schemaKeyMismatch` from `HeuristicCognitiveParser`).
        let primaryStepWithThought = ModernCognitiveStep(
            reasoning: primaryResult.reasoning,
            thought: primaryResult.thought ?? sanitized.thought,
            toolCalls: primaryResult.toolCalls,
            tokenUsage: primaryResult.tokenUsage,
            parseOutcome: primaryResult.parseOutcome
        )

        // Short-circuit when the primary parser flagged a typed failure: skip drift and heuristic recovery and
        // return it, keeping the typed reason so the terminator routes to `.suspectedFormatFailure`.
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
    /// Empty `toolCalls` here, after a confident path, means the model intentionally produced no calls: `.genuineCompletion`.
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

        // A JSON object in the answer is not a call: bare-JSON fallbacks accept any `name`-keyed object, so a user
        // record would become one. Only when every call names an unknown tool (never `stage0-framework`).
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
            // A partial batch's failed calls are logged and handed on, so the loop reports each one as not run.
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

    /// Classifies a parse result as confident or degraded. Degraded: `toolCalls` is empty AND the sanitized text carries
    /// signals that calls were present but unparsed. Zero tools with no drift signals is a genuine text-only response (task
    /// termination), classified confident.
    private func classifyConfidence(
        _ result: ModernCognitiveStep,
        sanitizedText: String,
        callEvidence: String
    ) -> ParseConfidence {
        // Non-empty tool calls → confident
        if !result.toolCalls.isEmpty {
            return .confident(result)
        }

        // An explicit empty tool_calls array (`"tool_calls": []`) is a genuine completion signal; the drift detector must not
        // call it degraded just for containing the substring `"tool_calls"`.
        if containsExplicitEmptyToolCalls(in: sanitizedText) {
            return .confident(result)
        }

        // When primary returned 0 tools and the sanitized text contains a JSON object on a JSON dialect, route to
        // `.degraded` so Stage 4 recovery can catch bare shapes the strict `NativeJSONParser` misses.
        if isJsonDialect(expectedDialect) && containsJSONObjectShape(in: sanitizedText) {
            return .degraded(result)
        }

        // Zero tool calls → check if we might be missing something via drift probes
        let detector = FormatDriftDetector(excludedDialect: expectedDialect, knownToolNames: knownToolNames)
        if detector.containsAnySignal(in: sanitizedText) {
            return .degraded(result)
        }

        // Last-ditch signal: short output that mentions a registered tool name, catching function-call-like prose no drift probe
        // recognizes (e.g. `codebase_map path: "/..."`). The length gate avoids flagging long prose that merely mentions a tool.
        if firstMentionedToolName(in: sanitizedText) != nil {
            return .degraded(result)
        }

        // An attempted call none of the signals above can see (declared grammar), e.g. one cut off mid-generation.
        // Routed through recovery: a complete call is recovered; a cut-off one ends as a typed failure.
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

    /// String arguments typed by the tool's declared schema: only a `.string` whose schema says
    /// number/integer/boolean/array/object, and only when the text genuinely is that type (`"5"` → 5; `"maybe"`
    /// stays a string for a boolean). A `"string"` parameter is never touched.
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
    /// Only scans short outputs (< 300 chars): long prose legitimately references tools by name, while a short call-shaped
    /// emission naming a tool (e.g. `codebase_map path: "/..."`) is a high-signal broken call.
    private func firstMentionedToolName(in text: String) -> String? {
        guard !registeredTools.isEmpty else { return nil }
        guard text.count < 300 else { return nil }
        let lower = text.lowercased()
        return registeredTools.first { Self.mentionsAsACall(lower, name: $0.name.lowercased()) }?.name
    }

    // Why: not a substring match: Code profiles register `forget`, `recall`, `remember` and `git`, so a
    // substring turns ordinary prose ("did you forget…", "7 digits") into a format failure
    /// Whether `name` appears in `text` the way a broken call would write it: as a whole identifier and, for a
    /// name that is also an ordinary word (no `_`), followed by call punctuation (`(`, `{`, `:` or `=`), the
    /// shape of `codebase_map path: …`.
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

    /// Stage 4: falls through to the `HeuristicCognitiveParser`. If it finds tools, resolve and finalize normally; if it also
    /// fails, return `.failed` with a typed reason reflecting what can be inferred about why parsing failed.
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

    // Why: JSON-dialect recovery triggers on any `{…}` or `[…]`, so code-like answers (`prices[i]`, a Markdown link) would
    // otherwise be reported as format failures
    /// A failure that only means "found no call in this text" becomes the answer unless the text declares an attempted call
    /// (`AttemptedToolCallGrammar`). Only with a registry (an empty `registeredTools` marks a provider-level parse that
    /// `NativeParsePipeline` re-decides), and only for `.malformedJSON`, `.noStructuredOutput` and `.schemaKeyMismatch`.
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

    /// Best-effort classification of why the cascade failed, from the sanitized text; the distinctions drive
    /// different corrective alerts.
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

        // A registered tool name in short prose: the attempted tool is known, so the alert can name it and show the
        // JSON shape. Checked before the more generic prose-description match.
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

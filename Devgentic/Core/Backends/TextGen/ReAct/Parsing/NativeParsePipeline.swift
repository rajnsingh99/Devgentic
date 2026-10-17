// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NativeParsePipeline.swift
//  Devgentic
//
//  Validation pipeline for flows where the provider enforces tool-call
//  structure at the transport layer: Claude `tool_use` blocks, OpenAI
//  `tool_calls`, Gemini `functionCall` parts, and Ollama `message.tool_calls`
//  when the model honors the native path.
//
//  Unlike `CognitiveParsePipeline` (which parses raw prompt-generated text),
//  this pipeline receives a pre-built `ModernCognitiveStep` with
//  `[PendingToolCall]` already extracted by the provider wrapper. Its only
//  responsibility is to validate each call's name and arguments against the
//  registered tool set, applying forgive-then-audit remapping where safe.
//
//  Scope:
//    - Tool name resolution  (exact / alias / fuzzy with arg-compat gate)
//    - Argument key repair   (filename→path, query→search_term, etc.)
//    - Typed parse outcome   (`success` / `failed(.unknownToolName | .argSchemaMismatch)`)
//
//  Out of scope:
//    - Text parsing / JSON decode  (provider already did this)
//    - Dialect drift detection    (cloud providers can't drift at this layer)
//    - Heuristic rescue            (no raw text to rescue from)
//

import Foundation
import OSLog

private let logger = DGLogger(category: "NativeParsePipeline")

struct NativeParsePipeline: Sendable {

    /// Runtime tool registry for the current agent invocation.
    let registeredTools: [AgentTool]

    /// Optional model identifier for validation telemetry.
    let modelId: String

    /// Optional iteration number for validation telemetry.
    let iteration: Int

    /// Every tool name this RUN offers, including any withheld from this iteration's
    /// schema. Used only to recognise an attempted call in leaked content — a broken
    /// call to a withheld tool is still an attempted call, not an answer.
    /// Empty → falls back to `registeredTools`.
    let runToolNames: Set<String>

    init(
        registeredTools: [AgentTool],
        modelId: String = "unknown",
        iteration: Int = 0,
        runToolNames: Set<String> = []
    ) {
        self.registeredTools = registeredTools
        self.modelId = modelId
        self.iteration = iteration
        self.runToolNames = runToolNames
    }

    /// The names an attempted call is recognised against: the run's full loadout when
    /// the caller supplied it, else this iteration's registry.
    private var callableNames: Set<String> {
        runToolNames.isEmpty ? Set(registeredTools.map(\.name)) : runToolNames
    }

    // MARK: - Public API

    /// Validates each tool call in `step.toolCalls`, remapping names/args where
    /// a safe canonical resolution exists and flagging unresolvable ones.
    ///
    /// Never throws. Returns a new step with:
    ///   - `toolCalls` containing only the validated + (possibly remapped) calls
    ///   - `parseOutcome` set to `.success` when at least one call validated,
    ///     `.genuineCompletion` when the input had no calls at all, or
    ///     `.failed(reason)` when the sole call (or all calls) failed validation.
    func validate(step: ModernCognitiveStep) -> ModernCognitiveStep {
        // Zero incoming tool calls. On a native-tools API the structured channel is
        // authoritative: the model had a real way to call a tool and did not, so its
        // text IS the answer. The provider's content fallback (OllamaLLMProvider) may
        // still have classified it `.failed(reason)` — that cascade runs with an EMPTY
        // registry and can only judge by shape. The fallback exists to RECOVER calls
        // leaked into content; it must never VETO an answer. So a failure stands only
        // when the text declares an attempted call to a tool this run offers.
        guard !step.toolCalls.isEmpty else {
            return resolveZeroCallStep(step)
        }

        let resolver = ToolNameResolver(registeredTools: registeredTools)
        var validated: [PendingToolCall] = []
        var firstFailure: ParseFailureReason?
        var unknownNames: [String] = []
        var rejected: [RejectedSiblingCall] = []

        for call in step.toolCalls {
            let resolution = resolver.resolve(emittedName: call.name, arguments: call.arguments)
            switch resolution {
            case .exact(let name, let args):
                validated.append(PendingToolCall(id: call.id, name: name, arguments: args))

            case .remapped(let originalName, let canonicalName, let args, let remappedArgKeys):
                if remappedArgKeys.isEmpty {
                    logger.info("Name remap: '\(originalName)' → '\(canonicalName)'")
                } else {
                    let argSummary = remappedArgKeys.map { "\($0.from)→\($0.to)" }.joined(separator: ", ")
                    logger.info("Name + arg remap: '\(originalName)' → '\(canonicalName)' [\(argSummary)]")
                }
                validated.append(PendingToolCall(id: call.id, name: canonicalName, arguments: args))

            case .argSchemaMismatch(let originalName, let canonicalName, let missing, let unexpected):
                logger.warning("Arg schema mismatch: '\(originalName)' → '\(canonicalName)' missing=\(missing) unexpected=\(unexpected)")
                let reason = ParseFailureReason.argSchemaMismatch(
                    attempted: originalName, resolvedTo: canonicalName, missingArgs: missing, unexpectedArgs: unexpected)
                rejected.append(RejectedSiblingCall(call: call, reason: reason))
                if firstFailure == nil { firstFailure = reason }

            case .unknown(let attempted, let suggestions):
                logger.warning("Unknown tool name: '\(attempted)', suggestions=\(suggestions)")
                unknownNames.append(attempted)
                let reason = ParseFailureReason.unknownToolName(attempted: attempted, suggestions: suggestions)
                rejected.append(RejectedSiblingCall(call: call, reason: reason))
                if firstFailure == nil { firstFailure = reason }
            }
        }

        // Outcome policy:
        //   - If ANY call validated → success (partial success beats zero progress;
        //     failed siblings are dropped and logged). This matches ToolExecutionLoop's
        //     existing semantics where one bad call in a parallel batch doesn't kill the batch.
        //   - If NO calls validated and we captured a failure reason → return the first
        //     failure so the terminator routes to .suspectedFormatFailure.
        //   - If we got here with no validated calls and no captured reason something is
        //     structurally wrong — fall through to genuineCompletion rather than hang.
        // ⚠️ A JSON object in the ANSWER is not a call (bug 3, 2026-10-06). Ollama's content
        // fallback lifts the first `{…}` out of a reply with no structured calls, so a user record
        // like `{"name": "John Doe", "email": …}` arrived here as a call to a tool named "John
        // Doe", failed as unknown, and the correct answer was retried. Only calls recovered from
        // TEXT qualify (`callsRecoveredFromText`); a structured `tool_calls` entry naming an
        // unknown tool is a real hallucination and keeps its correction. The grammar is the
        // judge, as for every other answer-vs-call verdict: a name key with an arguments object,
        // a run tool's name or a call-format token still means an attempted call.
        if validated.isEmpty, !unknownNames.isEmpty, unknownNames.count == step.toolCalls.count,
           let text = step.callsRecoveredFromText,
           AttemptedToolCallGrammar.attemptedCallName(in: text, callableNames: callableNames) == nil {
            logger.notice("[PARSE_VERDICT] iter \(iteration) model=\(modelId): the content fallback recovered \(unknownNames.count) 'call(s)' to tool(s) this run does not offer (\(unknownNames.map { "'\($0)'" }.joined(separator: ", "))) and the reply declares no attempted call. CONSEQUENCE: the whole reply (\(text.count) chars) is the final answer; it is NOT retried as an unknown tool.")
            return ModernCognitiveStep(
                reasoning: text,
                thought: step.thought,
                toolCalls: [],
                tokenUsage: step.tokenUsage,
                parseOutcome: .genuineCompletion,
                reasoningReplay: step.reasoningReplay
            )
        }

        let outcome: ParseOutcome
        if !validated.isEmpty {
            outcome = .success
        } else if let reason = firstFailure {
            outcome = .failed(reason)
        } else {
            outcome = .genuineCompletion
        }

        if !validated.isEmpty, !rejected.isEmpty {
            logger.warning("[PARSE_VERDICT] iter \(iteration) model=\(modelId): \(validated.count) native call(s) validated, \(rejected.count) REJECTED: \(rejected.map(\.call.name).joined(separator: ", ")). CONSEQUENCE: the valid calls run; each rejected one is reported to the model as not run, with its reason (CR-52).")
        }

        return ModernCognitiveStep(
            reasoning: step.reasoning,
            thought: step.thought,
            toolCalls: validated,
            tokenUsage: step.tokenUsage,
            parseOutcome: outcome,
            reasoningReplay: step.reasoningReplay,
            rejectedCalls: validated.isEmpty ? [] : rejected
        )
    }

    /// Zero-call verdict — see the guard in `validate(step:)`.
    private func resolveZeroCallStep(_ step: ModernCognitiveStep) -> ModernCognitiveStep {
        guard case .failed(let reason) = step.parseOutcome else { return step }

        let text = step.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing to hand the user — a retry is the only useful move.
        guard !text.isEmpty else { return step }

        // Think blocks excluded, as in the content cascade: a call the model only considered
        // while thinking is not an attempt.
        let callEvidence = OutputSanitizer.stripThinkBlocks(text)
        if let attempted = AttemptedToolCallGrammar.attemptedCallName(in: callEvidence, callableNames: callableNames) {
            logger.info("[PARSE_VERDICT] iter \(iteration) model=\(modelId): zero native tool calls, content declares an attempted call ('\(attempted)') that did not decode (\(reason.uiChipLabel)). CONSEQUENCE: kept as a format failure — the model gets a corrective alert and retries.")
            return step
        }

        logger.notice("[PARSE_VERDICT] iter \(iteration) model=\(modelId): zero native tool calls and no attempted call in \(text.count) chars of content — overriding the content cascade's '\(reason.uiChipLabel)' verdict. CONSEQUENCE: the content is the final answer; it is NOT retried. (The cascade judges by shape with no tool registry; a brace or bracket in prose used to send correct answers into an unbounded retry loop.)")
        return ModernCognitiveStep(
            reasoning: step.reasoning,
            thought: step.thought,
            toolCalls: [],
            tokenUsage: step.tokenUsage,
            parseOutcome: .genuineCompletion,
            reasoningReplay: step.reasoningReplay
        )
    }
}

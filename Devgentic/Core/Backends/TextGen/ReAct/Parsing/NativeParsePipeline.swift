// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NativeParsePipeline.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "NativeParsePipeline")

/// Validates tool calls the provider already structured (Claude, OpenAI, Gemini, native Ollama) against the registered
/// tools, remapping names and argument keys where safe. Does no text parsing, dialect detection or heuristic rescue.
struct NativeParsePipeline: Sendable {

    /// Runtime tool registry for the current agent invocation.
    let registeredTools: [AgentTool]

    /// Optional model identifier for validation telemetry.
    let modelId: String

    /// Optional iteration number for validation telemetry.
    let iteration: Int

    /// Every tool name this run offers, including any withheld from this iteration's schema; recognises an attempted call
    /// in leaked content. Empty falls back to `registeredTools`.
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

    /// Validates each tool call in `step.toolCalls`, remapping names/args where a safe resolution exists. Never throws.
    /// Returns a step whose `parseOutcome` is `.success`, `.genuineCompletion` (no calls) or `.failed(reason)`.
    func validate(step: ModernCognitiveStep) -> ModernCognitiveStep {
        // Zero incoming tool calls: the structured channel is authoritative, so the text is the answer. A failure from the
        // provider's content fallback stands only when the text declares an attempted call to a tool this run offers.
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

        // Any validated call is success (failed siblings dropped); none returns the first failure. A JSON object in the answer
        // is not a call: only calls recovered from text qualify, and the grammar judges whether it was an attempt.
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

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

    init(registeredTools: [AgentTool], modelId: String = "unknown", iteration: Int = 0) {
        self.registeredTools = registeredTools
        self.modelId = modelId
        self.iteration = iteration
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
        // Zero incoming tool calls — preserve whatever upstream decided. The
        // provider or CognitiveParsePipeline may have already classified this
        // as `.failed(reason)` (content-fallback parse failure) or
        // `.genuineCompletion` (legitimately text-only). Overwriting either
        // would erase information the terminator needs.
        guard !step.toolCalls.isEmpty else {
            return step
        }

        let resolver = ToolNameResolver(registeredTools: registeredTools)
        var validated: [PendingToolCall] = []
        var firstFailure: ParseFailureReason?

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
                if firstFailure == nil {
                    firstFailure = .argSchemaMismatch(
                        attempted: originalName,
                        resolvedTo: canonicalName,
                        missingArgs: missing,
                        unexpectedArgs: unexpected
                    )
                }

            case .unknown(let attempted, let suggestions):
                logger.warning("Unknown tool name: '\(attempted)', suggestions=\(suggestions)")
                if firstFailure == nil {
                    firstFailure = .unknownToolName(
                        attempted: attempted,
                        suggestions: suggestions
                    )
                }
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
        let outcome: ParseOutcome
        if !validated.isEmpty {
            outcome = .success
        } else if let reason = firstFailure {
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
}

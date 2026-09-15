// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  NativeJSONParser.swift
//  Devgentic
//
//  Stage 1 primary parser for the `.nativeJSON` dialect — prompted-text flows
//  where the model was instructed to emit `{"content": "...", "tool_calls": [...]}`.
//
//  Strictly a fast-path decoder: accepts the canonical native array schema
//  and returns an empty step otherwise. Recovery (heuristic schemas, drift
//  detection, tool-name resolution) is owned by `CognitiveParsePipeline`'s
//  later stages — this parser does NOT internally fall back to
//  `HeuristicCognitiveParser` because doing so would bypass the pipeline's
//  `parseOutcome` tracking.
//
//  Transport-native flows (Claude/OpenAI/Gemini/Ollama-native) bypass this
//  parser entirely; their provider wrappers extract tool calls directly.
//
//  Created by Raj Singh on 06/03/26.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "NativeJSONParser")

/// Parses responses where the model emits a well-formed JSON object
/// containing a `content` field and a `tool_calls` array.
/// On failure, returns an empty step — the pipeline's Stage 2/3/4 take it from there.
struct NativeJSONParser: CognitiveParserProtocol {

    private struct NativeArraySchema: Decodable {
        let content: String
        let tool_calls: [NativeToolCall]

        struct NativeToolCall: Decodable {
            let name: String
            let arguments: [String: JSONValue]
        }
    }

    func parse(rawResponse: String) -> ModernCognitiveStep {
        // Strip markdown fences if the model wrapped its output
        var cleanText = rawResponse
        if cleanText.contains("```json") {
            cleanText = cleanText.components(separatedBy: "```json").last ?? cleanText
        }
        if cleanText.contains("```") {
            cleanText = cleanText.components(separatedBy: "```").first ?? cleanText
        }
        cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleanText.data(using: .utf8) else {
            logger.error("NativeJSONParser: Failed to encode text as UTF-8.")
            return ModernCognitiveStep(reasoning: rawResponse, toolCalls: [])
        }

        // Fast path: direct decode of the canonical native array schema
        if let decoded = try? JSONDecoder().decode(NativeArraySchema.self, from: data) {
            let pending = decoded.tool_calls.map {
                PendingToolCall(id: UUID().uuidString, name: $0.name, arguments: $0.arguments)
            }
            logger.info("NativeJSONParser: Fast-path succeeded. \(pending.count) tool call(s).")
            return ModernCognitiveStep(
                reasoning: ReasoningQualityFilter.filter(decoded.content),
                toolCalls: pending
            )
        }

        // Fast-path miss. Return no TOOL CALLS so the pipeline's subsequent stages
        // (drift detection → heuristic recovery) can take over with proper
        // `parseOutcome` tracking. Log the input verbatim (capped) so we can
        // diagnose parse regressions without attaching a debugger — the pipeline
        // only reports "Stage 1 confident tools=0" which hides WHAT the input was.
        //
        // ⚠️ THE TEXT IS RETURNED, and that is the whole point of this line. It used to
        // return `reasoning: ""`, discarding the model's answer — this parser was the ONLY
        // one of the fourteen that did. Every sibling ends its no-match path with
        // `reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)` under a
        // "Treating as conversational exit" log (MistralXMLParser.swift:45,
        // QwenHermesJsonParser.swift:69, MistralV3Parser.swift:72, and ten more), and even
        // the UTF-8 guard eight lines above this one preserves `rawResponse`.
        //
        // ⚠️ The consequence was NOT confined to parsing. A plain-text answer on this dialect
        // reaches `classifyConfidence`, which correctly finds no tool signals and returns
        // `.confident`; `resolveAndFinalize` then takes the zero-tools branch and emits
        // `.genuineCompletion` carrying this reasoning verbatim
        // (CognitiveParsePipeline.swift:207-217). The executor seats that as
        // `finalAgentThought`, so the user got an EMPTY final answer whenever a model on the
        // `.nativeJSON` prompted path (Ollama content-fallback, MLX JSON mode) replied in
        // prose instead of the `{content, tool_calls}` envelope — a refusal, a clarifying
        // question, or any direct answer. The pipeline's
        // `primaryResult.reasoning.isEmpty ? rawText : …` fallback only covers the heuristic
        // path, which a confident text-only exit never reaches.
        //
        // `rawResponse`, not `cleanText`: identical to every sibling, and it does not inherit
        // this file's fence-splitting above, whose `.first` branch discards everything after a
        // bare ``` fence.
        let preview = cleanText.count > 600 ? String(cleanText.prefix(600)) + "…[+\(cleanText.count - 600) chars]" : cleanText
        logger.info("NativeJSONParser: Fast-path miss — yielding to pipeline stages 2+. Input: \(preview)")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }
}

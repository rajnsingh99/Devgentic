// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NativeJSONParser.swift
//  Devgentic
//
//  Created by Raj Singh.
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

        // Fast-path miss: return no tool calls but keep `rawResponse` as the reasoning, so a prose answer is not dropped.
        // The input is logged (capped) to diagnose parse failures.
        let preview = cleanText.count > 600 ? String(cleanText.prefix(600)) + "…[+\(cleanText.count - 600) chars]" : cleanText
        logger.info("NativeJSONParser: Fast-path miss — yielding to pipeline stages 2+. Input: \(preview)")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  PythonicTagParser.swift
//  Devgentic
//
//  Fallback parser for the <|python_tag|> format used by Llama 3.1 variants.
//  Expected formats:
//    <|python_tag|>{"name": "tool", "parameters": {"key": "val"}}
//    <|python_tag|>[{"name": "tool", "parameters": {"key": "val"}}]
//
//  Created by Raj Singh on 10/03/26.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "PythonicTagParser")

/// Parses the `<|python_tag|>` format emitted by some Llama tool-calling variants.
/// Splits on the tag marker and attempts JSON decoding of the payload.
struct PythonicTagParser: CognitiveParserProtocol {

    /// Flexible schema: models vary between "parameters" and "arguments" keys.
    private struct PythonicCall: Decodable {
        let name: String
        let parameters: [String: JSONValue]?
        let arguments: [String: JSONValue]?
    }

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let parts = rawResponse.components(separatedBy: "<|python_tag|>")
        let reasoning = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var toolCalls: [PendingToolCall] = []

        // Everything after each <|python_tag|> marker should be a JSON payload
        for i in 1..<parts.count {
            var jsonPart = parts[i].trimmingCharacters(in: .whitespacesAndNewlines)

            // Strip trailing <|eom_id|> if present
            if let eomRange = jsonPart.range(of: "<|eom_id|>") {
                jsonPart = String(jsonPart[..<eomRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard !jsonPart.isEmpty, let data = jsonPart.data(using: .utf8) else { continue }

            // Try single call object
            if let call = try? JSONDecoder().decode(PythonicCall.self, from: data) {
                let args = call.parameters ?? call.arguments ?? [:]
                toolCalls.append(PendingToolCall(
                    id: UUID().uuidString,
                    name: call.name,
                    arguments: args
                ))
                continue
            }

            // Try array of calls
            if let calls = try? JSONDecoder().decode([PythonicCall].self, from: data) {
                for call in calls {
                    let args = call.parameters ?? call.arguments ?? [:]
                    toolCalls.append(PendingToolCall(
                        id: UUID().uuidString,
                        name: call.name,
                        arguments: args
                    ))
                }
            }
        }

        if toolCalls.isEmpty {
            logger.warning("PythonicTagParser: Found <|python_tag|> marker but could not decode any calls.")
        } else {
            logger.info("PythonicTagParser: Extracted \(toolCalls.count) tool call(s).")
        }

        return ModernCognitiveStep(
            reasoning: ReasoningQualityFilter.filter(reasoning),
            toolCalls: toolCalls
        )
    }
}

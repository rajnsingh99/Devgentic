// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GenericToolsXMLParser.swift
//  Devgentic
//
//  Fallback parser for generic XML tool-call wrappers: <tools>...</tools>
//  and <tool>...</tool>. Used by Qwen3 and other models that wrap bare
//  JSON tool-call objects in simple XML tags.
//
//  Expected formats:
//    Reasoning text here...
//    <tools>
//    {"name": "tool_name", "arguments": {"key": "value"}}
//    </tools>
//
//    <tool>
//    {"name": "tool_name", "arguments": {"key": "value"}}
//    </tool>
//
//  Also handles arrays inside the tags:
//    <tools>
//    [{"name": "tool1", "arguments": {...}}, {"name": "tool2", "arguments": {...}}]
//    </tools>
//
//  Created by Raj Singh on 10/03/26.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "GenericToolsXMLParser")

/// Parses generic `<tools>` / `<tool>` XML-wrapped tool calls.
/// Extracts reasoning from text before the tags and parses the JSON payload inside.
struct GenericToolsXMLParser: CognitiveParserProtocol {

    /// Bare tool call: `{"name": "...", "arguments": {...}}`
    /// Handles both "arguments" and "parameters" keys for flexibility.
    private struct BareToolCall: Decodable {
        let name: String
        let arguments: [String: JSONValue]?
        let parameters: [String: JSONValue]?
    }

    func parse(rawResponse: String) -> ModernCognitiveStep {
        var reasoning = ""
        var toolCalls: [PendingToolCall] = []

        // Try both tag variants: <tools>...</tools> and <tool>...</tool>
        let tagPatterns: [(open: String, pattern: String)] = [
            ("<tools>",  #"<tools>([\s\S]*?)</tools>"#),
            ("<tool>",   #"<tool>([\s\S]*?)</tool>"#)
        ]

        for (openTag, pattern) in tagPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }

            let matches = regex.matches(in: rawResponse, range: NSRange(rawResponse.startIndex..., in: rawResponse))
            guard !matches.isEmpty else { continue }

            // Extract reasoning: text before the first occurrence of the open tag
            if let tagStart = rawResponse.range(of: openTag, options: .caseInsensitive) {
                reasoning = String(rawResponse[..<tagStart.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Process each matched tag block
            for match in matches {
                guard let bodyRange = Range(match.range(at: 1), in: rawResponse) else { continue }
                let body = String(rawResponse[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty, let data = body.data(using: .utf8) else { continue }

                // Try decoding as a single bare tool call
                if let call = try? JSONDecoder().decode(BareToolCall.self, from: data) {
                    let args = call.arguments ?? call.parameters ?? [:]
                    toolCalls.append(PendingToolCall(
                        id: UUID().uuidString,
                        name: call.name,
                        arguments: args
                    ))
                    continue
                }

                // Try decoding as an array of bare tool calls
                if let calls = try? JSONDecoder().decode([BareToolCall].self, from: data) {
                    for call in calls {
                        let args = call.arguments ?? call.parameters ?? [:]
                        toolCalls.append(PendingToolCall(
                            id: UUID().uuidString,
                            name: call.name,
                            arguments: args
                        ))
                    }
                    continue
                }

                logger.warning("GenericToolsXMLParser: Found \(openTag) block but JSON decode failed for body: \(body.prefix(200))")
            }

            // If we found matches with this tag pattern, stop — don't try the next pattern
            if !toolCalls.isEmpty { break }
        }

        if toolCalls.isEmpty {
            logger.warning("GenericToolsXMLParser: Found generic XML tags but extracted zero tool calls.")
        } else {
            logger.info("GenericToolsXMLParser: Extracted \(toolCalls.count) tool call(s).")
        }

        return ModernCognitiveStep(
            reasoning: ReasoningQualityFilter.filter(reasoning),
            toolCalls: toolCalls
        )
    }
}

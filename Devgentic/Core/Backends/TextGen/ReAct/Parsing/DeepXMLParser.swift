// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DeepXMLParser.swift
//  Devgentic
//
//  Fallback parser for the Qwen-Coder deep XML format.
//  Expected format:
//    <function=tool_name>
//      <parameter=key1>value1</parameter>
//      <parameter=key2>value2</parameter>
//    </function>
//
//  Created by Raj Singh on 10/03/26.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "DeepXMLParser")

/// Parses Qwen-Coder style deep XML function calls where tool names
/// and parameters are encoded as XML attribute values rather than JSON.
struct DeepXMLParser: CognitiveParserProtocol {

    func parse(rawResponse: String) -> ModernCognitiveStep {
        var toolCalls: [PendingToolCall] = []
        var reasoning = ""

        // Extract reasoning: text before the first <function= tag
        if let funcStart = rawResponse.range(of: "<function=") {
            reasoning = String(rawResponse[..<funcStart.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Match all <function=NAME>...</function> blocks
        guard let funcRegex = try? NSRegularExpression(
            pattern: #"<function=([^>]+)>([\s\S]*?)</function>"#,
            options: .caseInsensitive
        ) else {
            logger.error("DeepXMLParser: Failed to compile function regex.")
            return ModernCognitiveStep(reasoning: rawResponse, toolCalls: [])
        }

        let matches = funcRegex.matches(
            in: rawResponse,
            range: NSRange(rawResponse.startIndex..., in: rawResponse)
        )

        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: rawResponse),
                  let bodyRange = Range(match.range(at: 2), in: rawResponse) else { continue }

            let toolName = String(rawResponse[nameRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let body = String(rawResponse[bodyRange])

            // Extract <parameter=KEY>VALUE</parameter> pairs
            var arguments: [String: JSONValue] = [:]
            if let paramRegex = try? NSRegularExpression(
                pattern: #"<parameter=([^>]+)>([\s\S]*?)</parameter>"#,
                options: .caseInsensitive
            ) {
                let paramMatches = paramRegex.matches(
                    in: body,
                    range: NSRange(body.startIndex..., in: body)
                )
                for pm in paramMatches {
                    if let keyRange = Range(pm.range(at: 1), in: body),
                       let valRange = Range(pm.range(at: 2), in: body) {
                        let key = String(body[keyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let val = String(body[valRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        arguments[key] = JSONValue.string(val)
                    }
                }
            }

            toolCalls.append(PendingToolCall(
                id: UUID().uuidString,
                name: toolName,
                arguments: arguments
            ))
        }

        if toolCalls.isEmpty {
            logger.warning("DeepXMLParser: Found no <function=...> blocks.")
        } else {
            logger.info("DeepXMLParser: Extracted \(toolCalls.count) tool call(s).")
        }

        return ModernCognitiveStep(
            reasoning: ReasoningQualityFilter.filter(reasoning),
            toolCalls: toolCalls
        )
    }
}

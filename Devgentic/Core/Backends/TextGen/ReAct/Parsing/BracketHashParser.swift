// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BracketHashParser.swift
//  Devgentic
//
//  Fallback parser for the <Functions#tool_name> format used by Devstral/OpenHands.
//  Expected formats:
//    <Functions#[tool_name]{"key": "value"}>
//    <Functions#tool_name>{"key": "value"}</Functions>
//
//  Created by Raj Singh on 10/03/26.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "BracketHashParser")

/// Parses the `<Functions#...>` format emitted by Devstral and OpenHands models.
/// Handles both closed-tag (`</Functions>`) and self-closing bracket variants.
struct BracketHashParser: CognitiveParserProtocol {

    func parse(rawResponse: String) -> ModernCognitiveStep {
        var reasoning = ""
        var toolCalls: [PendingToolCall] = []

        // Extract reasoning: text before first <Functions#
        if let funcStart = rawResponse.range(of: "<Functions#") {
            reasoning = String(rawResponse[..<funcStart.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Pattern 1: <Functions#[tool_name]{...}>  (bracket-wrapped name)
        toolCalls.append(contentsOf: extractBracketStyle(from: rawResponse))

        // Pattern 2: <Functions#tool_name>{...}</Functions>  (close-tag style)
        if toolCalls.isEmpty {
            toolCalls.append(contentsOf: extractCloseTagStyle(from: rawResponse))
        }

        if toolCalls.isEmpty {
            logger.warning("BracketHashParser: Found <Functions# marker but could not extract any calls.")
        } else {
            logger.info("BracketHashParser: Extracted \(toolCalls.count) tool call(s).")
        }

        return ModernCognitiveStep(
            reasoning: ReasoningQualityFilter.filter(reasoning),
            toolCalls: toolCalls
        )
    }

    // MARK: - Private Extraction

    /// Extracts `<Functions#[tool_name]{...}>` pattern.
    private func extractBracketStyle(from text: String) -> [PendingToolCall] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<Functions#\[([^\]]+)\]\s*\{([\s\S]*?)\}>"#,
            options: .caseInsensitive
        ) else { return [] }

        var calls: [PendingToolCall] = []
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else { continue }

            let toolName = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = "{\(String(text[bodyRange]))}"

            let arguments = decodeJSON(body)
            calls.append(PendingToolCall(id: UUID().uuidString, name: toolName, arguments: arguments))
        }
        return calls
    }

    /// Extracts `<Functions#tool_name>BODY</Functions>` pattern.
    private func extractCloseTagStyle(from text: String) -> [PendingToolCall] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<Functions#([^>]+)>([\s\S]*?)</Functions>"#,
            options: .caseInsensitive
        ) else { return [] }

        var calls: [PendingToolCall] = []
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else { continue }

            let toolName = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            let arguments = decodeJSON(body)
            calls.append(PendingToolCall(id: UUID().uuidString, name: toolName, arguments: arguments))
        }
        return calls
    }

    /// Attempts JSON decode, applying missing-quote heuristic for keys before decoding.
    private func decodeJSON(_ raw: String) -> [String: JSONValue] {
        var json = raw

        // Heuristic: fix missing opening quotes on keys (e.g., `command": "ls"` → `"command": "ls"`)
        if let fixRegex = try? NSRegularExpression(pattern: #"(\s)(\w+)":\s*"#) {
            json = fixRegex.stringByReplacingMatches(
                in: json,
                range: NSRange(json.startIndex..., in: json),
                withTemplate: #"$1"$2": "#
            )
        }

        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return [:]
        }
        return decoded
    }
}

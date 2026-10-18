// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DynamicToolTagParser.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "DynamicToolTagParser")

/// Fallback parser for the dynamic-tag format, where the XML tag itself is the tool name (Mistral
/// native output). Example: `<search_issues>{"q": "Acme"}</search_issues>`; distinct from the fixed
/// `<tool_call>` wrapper.
struct DynamicToolTagParser: CognitiveParserProtocol {

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let text = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)

        let toolCalls = extractDynamicToolCalls(from: text)
        let reasoning = extractReasoning(from: text)

        if toolCalls.isEmpty {
            logger.warning("DynamicToolTagParser: No dynamic tool tags found.")
            return ModernCognitiveStep(reasoning: text, toolCalls: [])
        }

        logger.info("DynamicToolTagParser: Extracted \(toolCalls.count) tool call(s): \(toolCalls.map { $0.name }.joined(separator: ", "))")
        return ModernCognitiveStep(reasoning: reasoning, toolCalls: toolCalls)
    }

    // MARK: - Extraction

    /// Extracts all `<tool_name>{JSON}</tool_name>` patterns: a lowercase-identifier tag with a
    /// backreferenced closer. Known structural tags (tool_call, tools, content) are excluded to avoid
    /// overlap with other parsers.
    private func extractDynamicToolCalls(from text: String) -> [PendingToolCall] {
        let pattern = #"<([a-z][a-z0-9_]*)>([\s\S]*?)</\1>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        // Tags that belong to other parser formats — skip them
        let reservedTags: Set<String> = [
            "tool_call", "tool_calls", "tools", "tool",
            "content", "arguments", "tool_name",
            "function", "parameter", "parameters",
            "think", "thinking", "thought",
            "result", "response", "output"
        ]

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var toolCalls: [PendingToolCall] = []

        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else {
                continue
            }

            let tagName = String(text[nameRange])

            // Skip reserved structural tags
            if reservedTags.contains(tagName) {
                continue
            }

            let body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Parse the body as JSON arguments
            guard let arguments = parseArguments(body) else {
                logger.warning("DynamicToolTagParser: Failed to parse JSON for tag '<\(tagName)>': \(body.count) chars (snippet at debug: model output is content, CR-57)")
                logger.debug("DynamicToolTagParser: snippet: \(body.prefix(200))")
                continue
            }

            toolCalls.append(PendingToolCall(
                id: UUID().uuidString,
                name: tagName,
                arguments: arguments
            ))
        }

        return toolCalls
    }

    /// Extracts reasoning text that appears before the first dynamic tool tag.
    private func extractReasoning(from text: String) -> String {
        let pattern = #"<[a-z][a-z0-9_]*>"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let firstMatch = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(firstMatch.range, in: text) {
            let before = String(text[text.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let filtered = ReasoningQualityFilter.filter(before)
            if !filtered.isEmpty { return filtered }
        }
        return ""
    }

    /// Parses a JSON string into a dictionary, with sanitization fallback.
    private func parseArguments(_ jsonString: String) -> [String: JSONValue]? {
        // Direct decode
        if let data = jsonString.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            return decoded
        }

        // Sanitizes trailing commas and Python literals outside string values only, so tool arguments keep
        // their own commas and `None` tokens.
        let sanitized = JSONStructuralSanitizer.repairingStructure(jsonString)

        if let data = sanitized.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            logger.info("DynamicToolTagParser: JSON decoded after sanitization.")
            return decoded
        }

        return nil
    }
}

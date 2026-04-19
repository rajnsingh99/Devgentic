//
//  DynamicToolTagParser.swift
//  Devgentic
//
//  Fallback parser for the .dynamicToolTag drift format.
//  Handles Mistral's native tool-calling output where the XML tag itself IS the tool name:
//
//    <search_issues>{"q": "Acme", "per_page": 10}</search_issues>
//    <get_file_contents>{"owner": "Acme", "repo": "main", "path": "."}</get_file_contents>
//
//  This is distinct from <tool_call> (fixed wrapper) or <tools> (generic wrapper).
//  The tag name is dynamic and matches the actual tool name the model chose to invoke.
//
//  Created by Devgentic Architect.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "DynamicToolTagParser")

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

    /// Extracts all `<tool_name>{JSON}</tool_name>` patterns from the text.
    ///
    /// The regex matches:
    ///   - Opening tag: `<identifier>` where identifier is lowercase + digits + underscores
    ///   - Body: any content (captured for JSON parsing)
    ///   - Closing tag: `</identifier>` matching the opening tag (backreference \1)
    ///
    /// This deliberately excludes known structural tags (tool_call, tools, content, etc.)
    /// to avoid overlap with other parsers.
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
                logger.warning("DynamicToolTagParser: Failed to parse JSON for tag '<\(tagName)>': \(body.prefix(200))")
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
            if !before.isEmpty {
                return before
            }
        }
        return "Executing tool calls..."
    }

    /// Parses a JSON string into a dictionary, with sanitization fallback.
    private func parseArguments(_ jsonString: String) -> [String: JSONValue]? {
        // Direct decode
        if let data = jsonString.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            return decoded
        }

        // Sanitize: trailing commas, Python literals, null values
        var sanitized = jsonString

        // Remove trailing commas before } or ]
        if let regex = try? NSRegularExpression(pattern: #",\s*([}\]])"#) {
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                range: NSRange(sanitized.startIndex..., in: sanitized),
                withTemplate: "$1"
            )
        }

        // Python literal normalization
        let replacements: [(String, String)] = [
            (#"\bFalse\b"#, "false"),
            (#"\bTrue\b"#, "true"),
            (#"\bNone\b"#, "null"),
            (#"\bnull\b"#, "null"),
        ]
        for (pattern, replacement) in replacements {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                sanitized = regex.stringByReplacingMatches(
                    in: sanitized,
                    range: NSRange(sanitized.startIndex..., in: sanitized),
                    withTemplate: replacement
                )
            }
        }

        if let data = sanitized.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            logger.info("DynamicToolTagParser: JSON decoded after sanitization.")
            return decoded
        }

        return nil
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  Llama3JsonParser.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "Llama3JsonParser")

/// Primary parser for the `.llama3JsonSingle` dialect (native Llama-3.1/3.2/3.3 Instruct output).
/// Single-call only: the template allows one tool call per message, so only the first is parsed.
/// Tolerates marker tokens, `arguments`/`tool_name` aliases, surrounding prose and Python literals (True/False/None).
struct Llama3JsonParser: CognitiveParserProtocol {

    /// Canonical decoded shape, tolerant of small-model key drift: `tool_name` aliases `name`, `arguments` `parameters`.
    /// `content` is captured for reasoning extraction (present in flat-JSON drift output).
    private struct ToolCallObject: Decodable {
        let name: String?
        let tool_name: String?
        let parameters: [String: JSONValue]?
        let arguments: [String: JSONValue]?
        let content: String?

        var resolvedName: String? {
            if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
            if let n = tool_name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
            return nil
        }

        var resolvedArguments: [String: JSONValue] {
            parameters ?? arguments ?? [:]
        }
    }

    // Known Llama-3.x marker tokens that may bracket the JSON in raw output.
    private static let markerTokens = [
        "<|python_tag|>",
        "<|eot_id|>",
        "<|eom_id|>",
        "<|start_header_id|>",
        "<|end_header_id|>"
    ]

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let stripped = stripLlamaMarkers(from: rawResponse)
        let reasoning = extractReasoning(from: stripped)

        if let call = extractFirstToolCall(from: stripped) {
            logger.info("Llama3JsonParser: Extracted 1 tool call: \(call.name)")
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: [call])
        }

        logger.warning("Llama3JsonParser: No Llama-3 tool call found. Treating as conversational exit.")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }

    // MARK: - Extraction

    /// Removes Llama-3 marker tokens so the JSON can decode cleanly.
    private func stripLlamaMarkers(from text: String) -> String {
        var result = text
        for marker in Self.markerTokens {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finds the first balanced JSON object containing a `name` or `tool_name` field
    /// and decodes it. Returns nil if no valid tool call found.
    private func extractFirstToolCall(from text: String) -> PendingToolCall? {
        // Require the quoted key `name` or `tool_name`, otherwise any JSON object would spuriously match; the quoted `name`
        // does not occur inside the quoted `tool_name`.
        guard text.contains("\"name\"") || text.contains("\"tool_name\"") else { return nil }
        guard let range = balancedJSONObjectRange(in: text, startingAt: text.startIndex) else { return nil }
        let body = String(text[range])
        return decodeToolCall(from: body)
    }

    /// Tracks string state so braces inside quoted strings don't affect depth.
    private func balancedJSONObjectRange(in text: String, startingAt: String.Index) -> Range<String.Index>? {
        BalancedJSONScanner.balancedRange(in: text, from: startingAt, opener: "{")
    }

    private func decodeToolCall(from jsonString: String) -> PendingToolCall? {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }

        if let decoded = try? JSONDecoder().decode(ToolCallObject.self, from: data),
           let resolvedName = decoded.resolvedName {
            return PendingToolCall(
                id: UUID().uuidString,
                name: resolvedName,
                arguments: decoded.resolvedArguments
            )
        }

        // Retry after sanitization (trailing commas, Python literals).
        let sanitized = sanitizeJSON(trimmed)
        if sanitized != trimmed,
           let data2 = sanitized.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ToolCallObject.self, from: data2),
           let resolvedName = decoded.resolvedName {
            logger.info("Llama3JsonParser: Decoded after sanitization.")
            return PendingToolCall(
                id: UUID().uuidString,
                name: resolvedName,
                arguments: decoded.resolvedArguments
            )
        }

        logger.warning("Llama3JsonParser: Failed to decode tool call JSON: \(trimmed.count) chars (snippet at debug: model output is content, CR-57)")
        logger.debug("Llama3JsonParser: snippet: \(trimmed.prefix(200))")
        return nil
    }

    /// Repairs trailing commas and Python literals in the model's JSON.
    /// Delegates to the shared `JSONStructuralSanitizer` so repair happens only outside string values;
    /// whole-payload regexes would rewrite file content carried in a `write_file` call's `arguments.content`.
    private func sanitizeJSON(_ raw: String) -> String {
        JSONStructuralSanitizer.repairingStructure(raw)
    }

    /// Reasoning priority: (1) prose before the first `{`, (2) the `content` field of the decoded call, (3) empty.
    /// Both paths go through `ReasoningQualityFilter`, which strips stock phrases (Executing tool ...) that carry no signal
    /// (Llama-3.x instruct models, especially at Q4, routinely fill `content` with them).
    private func extractReasoning(from text: String) -> String {
        guard let openIdx = text.firstIndex(of: "{") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let before = String(text[..<openIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredProse = ReasoningQualityFilter.filter(before)
        if !filteredProse.isEmpty { return filteredProse }
        if let content = extractContentFieldFromBareJSON(text) {
            return ReasoningQualityFilter.filter(content)
        }
        return ""
    }

    /// Best-effort reasoning from a flat-JSON body's `content` field, if present.
    /// Used when no prose surrounds the JSON object; sanitizes Python literals first so drifted JSON (False/None) decodes.
    private func extractContentFieldFromBareJSON(_ text: String) -> String? {
        guard let range = balancedJSONObjectRange(in: text, startingAt: text.startIndex) else { return nil }
        let body = String(text[range])
        let candidate = sanitizeJSON(body.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let data = candidate.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ToolCallObject.self, from: data),
              let content = decoded.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            return nil
        }
        return content
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CommandR7BActionParser.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "CommandR7BActionParser")

/// Primary parser for the `.commandR7BAction` dialect (Cohere Command-R7B, Command-A): a token-delimited JSON array
/// of actions with an optional `tool_call_id`. Tolerates a missing `<|END_ACTION|>`, `name`/`arguments` aliases for
/// `tool_name`/`parameters`, and Python literals.
struct CommandR7BActionParser: CognitiveParserProtocol {

    private struct ToolCallObject: Decodable {
        let tool_call_id: String?
        let tool_name: String?
        let name: String?
        let parameters: [String: JSONValue]?
        let arguments: [String: JSONValue]?

        var resolvedName: String? {
            if let n = tool_name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
            if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
            return nil
        }

        var resolvedArguments: [String: JSONValue] {
            parameters ?? arguments ?? [:]
        }
    }

    private static let actionBegin = "<|START_ACTION|>"
    private static let actionEnd = "<|END_ACTION|>"

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let calls = extractToolCalls(from: rawResponse)
        let reasoning = extractReasoning(from: rawResponse, extractedCount: calls.count)

        if !calls.isEmpty {
            logger.info("CommandR7BActionParser: Extracted \(calls.count) tool call(s): \(calls.map { $0.name }.joined(separator: ", "))")
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: calls)
        }

        logger.warning("CommandR7BActionParser: No <|START_ACTION|> found. Treating as conversational exit.")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }

    // MARK: - Extraction

    private func extractToolCalls(from text: String) -> [PendingToolCall] {
        // The pipeline hands parsers sanitized text, which strips the `<|START_ACTION|>` marker, so without the marker the
        // action array is recognised by its own shape (`markerlessActionArray`).
        guard let startRange = text.range(of: Self.actionBegin) else {
            let calls = markerlessActionArray(in: text).compactMap { toPendingCall($0) }
            if !calls.isEmpty {
                logger.info("CommandR7BActionParser: <|START_ACTION|> absent (the sanitizer strips it); recovered \(calls.count) call(s) from the action array's own shape.")
            }
            return calls
        }
        let afterStart = startRange.upperBound

        // Delimit by <|END_ACTION|> if present; otherwise take the rest of the text.
        let endIndex = text.range(of: Self.actionEnd, range: afterStart..<text.endIndex)?.lowerBound ?? text.endIndex
        let body = String(text[afterStart..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract balanced JSON array from body.
        guard let arraySlice = extractBalancedArray(body) else {
            logger.warning("CommandR7BActionParser: Failed to locate JSON array inside START_ACTION body.")
            return []
        }

        guard let decoded = decodeArray(arraySlice) else { return [] }
        return decoded.compactMap { toPendingCall($0) }
    }

    /// The first JSON array in `text` that decodes as action objects and names a tool with `tool_name`, this dialect's
    /// own key. Not the `name` alias, which would turn an ordinary JSON answer into a tool call; non-qualifying arrays
    /// are stepped over.
    private func markerlessActionArray(in text: String) -> [ToolCallObject] {
        var cursor = text.startIndex
        while cursor < text.endIndex, let open = text[cursor...].firstIndex(of: "[") {
            guard let range = BalancedJSONScanner.balancedRange(in: text, from: open, opener: "[") else {
                cursor = text.index(after: open)
                continue
            }
            if let objects = decodeArray(String(text[range]), quietly: true),
               objects.contains(where: { $0.tool_name?.isEmpty == false }) {
                return objects
            }
            cursor = text.index(after: open)
        }
        return []
    }

    private func extractBalancedArray(_ text: String) -> String? {
        BalancedJSONScanner.firstArray(in: text).map(String.init)
    }

    private func toPendingCall(_ obj: ToolCallObject) -> PendingToolCall? {
        guard let resolvedName = obj.resolvedName else {
            logger.warning("CommandR7BActionParser: Object missing tool_name — skipping.")
            return nil
        }
        return PendingToolCall(
            id: obj.tool_call_id ?? UUID().uuidString,
            name: resolvedName,
            arguments: obj.resolvedArguments
        )
    }

    private func decodeArray(_ arraySlice: String, quietly: Bool = false) -> [ToolCallObject]? {
        let trimmed = arraySlice.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ToolCallObject].self, from: data) {
            return decoded
        }
        let sanitized = sanitizeJSON(trimmed)
        if sanitized != trimmed,
           let data2 = sanitized.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ToolCallObject].self, from: data2) {
            logger.info("CommandR7BActionParser: Decoded array after sanitization.")
            return decoded
        }
        if !quietly {
            logger.warning("CommandR7BActionParser: Failed to decode array (\(trimmed.count) chars). CONSEQUENCE: no call is taken from this START_ACTION body; the cascade's fallbacks get the reply.")
        }
        return nil
    }

    /// Repairs trailing commas and Python literals in the model's JSON, outside string values only, via the shared
    /// sanitizer (see `JSONStructuralSanitizer`).
    private func sanitizeJSON(_ raw: String) -> String {
        JSONStructuralSanitizer.repairingStructure(raw)
    }

    private func extractReasoning(from text: String, extractedCount: Int) -> String {
        guard extractedCount > 0 else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Cohere R7B often includes <|START_THINKING|>...<|END_THINKING|> before action.
        if let start = text.range(of: "<|START_THINKING|>"),
           let end = text.range(of: "<|END_THINKING|>"),
           start.upperBound < end.lowerBound {
            let thinking = String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let filtered = ReasoningQualityFilter.filter(thinking)
            if !filtered.isEmpty { return filtered }
        }
        // Fallback: prose before <|START_ACTION|>.
        if let range = text.range(of: Self.actionBegin) {
            let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let filtered = ReasoningQualityFilter.filter(before)
            if !filtered.isEmpty { return filtered }
        }
        return ""
    }
}

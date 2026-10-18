// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CommandRActionParser.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "CommandRActionParser")

/// Primary parser for the `.commandRAction` dialect (Cohere Command-R / R+): an `Action:` directive followed by a
/// fenced JSON list of `tool_name` / `parameters` objects. Tolerates `name` and `arguments` aliases, a missing or
/// partial fence, and multiple `Action:` blocks.
struct CommandRActionParser: CognitiveParserProtocol {

    private struct ToolCallObject: Decodable {
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

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let calls = extractToolCalls(from: rawResponse)
        let reasoning = extractReasoning(from: rawResponse, extractedCount: calls.count)

        if !calls.isEmpty {
            logger.info("CommandRActionParser: Extracted \(calls.count) tool call(s): \(calls.map { $0.name }.joined(separator: ", "))")
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: calls)
        }

        logger.warning("CommandRActionParser: No Action: directive found. Treating as conversational exit.")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }

    // MARK: - Extraction

    // Why: resume the search after the consumed array; resuming just after `Action:` re-reads the same array
    // when a second `Action:` appears inside it, and emits every call twice.
    /// Locates each `Action:` segment and extracts the JSON array in its code fence (or a bare array).
    private func extractToolCalls(from text: String) -> [PendingToolCall] {
        var results: [PendingToolCall] = []
        var searchStart = text.startIndex

        while let actionRange = text.range(of: "Action:", range: searchStart..<text.endIndex) {
            let afterAction = actionRange.upperBound

            // Prefer fenced JSON; fall back to bare balanced array.
            guard let (arraySlice, consumedEnd) = extractJSONArraySlice(in: text, from: afterAction) else {
                searchStart = afterAction
                continue
            }

            if let decoded = decodeArray(arraySlice) {
                results.append(contentsOf: decoded.compactMap { toPendingCall($0) })
            }
            // Resume after the consumed array, not just past this `Action:`.
            searchStart = consumedEnd
        }

        return results
    }

    /// The first JSON array after `start` (fenced, else bare) and the index just past it.
    private func extractJSONArraySlice(in fullText: String, from start: String.Index) -> (String, String.Index)? {
        let text = fullText[start...]
        let fencePatterns = [
            #"```json\s*\n([\s\S]*?)\n\s*```"#,
            #"```\s*\n([\s\S]*?)\n\s*```"#
        ]
        for pattern in fencePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            if let match = regex.firstMatch(in: fullText, range: NSRange(start..<fullText.endIndex, in: fullText)),
               let bodyRange = Range(match.range(at: 1), in: fullText),
               let wholeRange = Range(match.range, in: fullText) {
                return (String(fullText[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines), wholeRange.upperBound)
            }
        }
        // Fallback: bare balanced `[...]`.
        guard let range = BalancedJSONScanner.balancedRange(in: fullText, from: text.startIndex, opener: "[") else { return nil }
        return (String(fullText[range]), range.upperBound)
    }

    private func toPendingCall(_ obj: ToolCallObject) -> PendingToolCall? {
        guard let resolvedName = obj.resolvedName else {
            logger.warning("CommandRActionParser: Object missing tool_name/name — skipping.")
            return nil
        }
        return PendingToolCall(id: UUID().uuidString, name: resolvedName, arguments: obj.resolvedArguments)
    }

    private func decodeArray(_ arraySlice: String) -> [ToolCallObject]? {
        let trimmed = arraySlice.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ToolCallObject].self, from: data) {
            return decoded
        }
        let sanitized = sanitizeJSON(trimmed)
        if sanitized != trimmed,
           let data2 = sanitized.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ToolCallObject].self, from: data2) {
            logger.info("CommandRActionParser: Decoded array after sanitization.")
            return decoded
        }
        logger.warning("CommandRActionParser: Failed to decode array: \(trimmed.count) chars (snippet at debug: model output is content, CR-57)")
        logger.debug("CommandRActionParser: snippet: \(trimmed.prefix(200))")
        return nil
    }

    /// Repairs trailing commas and Python literals in the model's JSON, outside string values only.
    /// Delegates to `JSONStructuralSanitizer`.
    private func sanitizeJSON(_ raw: String) -> String {
        JSONStructuralSanitizer.repairingStructure(raw)
    }

    private func extractReasoning(from text: String, extractedCount: Int) -> String {
        guard extractedCount > 0 else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = text.range(of: "Action:") {
            let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ReasoningQualityFilter.filter(before)
        }
        return ""
    }
}

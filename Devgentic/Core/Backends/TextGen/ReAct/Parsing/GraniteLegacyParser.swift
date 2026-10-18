// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GraniteLegacyParser.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "GraniteLegacyParser")

/// Primary parser for the `.graniteLegacyArray` dialect (IBM Granite 3.0–3.3): a JSON array of `{name,
/// arguments}` objects after `<|tool_call|>` (3.0) or `<tool_call>` (3.1+). Tolerates `tool_name` /
/// `parameters` aliases, Python literals in args and a missing closing marker.
struct GraniteLegacyParser: CognitiveParserProtocol {

    private struct ToolCallObject: Decodable {
        let name: String?
        let tool_name: String?
        let arguments: [String: JSONValue]?
        let parameters: [String: JSONValue]?

        var resolvedName: String? {
            if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
            if let n = tool_name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
            return nil
        }

        var resolvedArguments: [String: JSONValue] {
            arguments ?? parameters ?? [:]
        }
    }

    private static let markers = ["<|tool_call|>", "<tool_call>"]

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let calls = extractToolCalls(from: rawResponse)
        let reasoning = extractReasoning(from: rawResponse, extractedCount: calls.count)

        if !calls.isEmpty {
            logger.info("GraniteLegacyParser: Extracted \(calls.count) tool call(s): \(calls.map { $0.name }.joined(separator: ", "))")
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: calls)
        }

        logger.warning("GraniteLegacyParser: No Granite tool-call marker found. Treating as conversational exit.")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }

    // MARK: - Extraction

    /// Scans for any Granite marker, then extracts the balanced JSON array that follows.
    private func extractToolCalls(from text: String) -> [PendingToolCall] {
        var results: [PendingToolCall] = []

        for marker in Self.markers {
            var searchStart = text.startIndex
            while let markerRange = text.range(of: marker, range: searchStart..<text.endIndex) {
                guard let arrayRange = balancedJSONArrayRange(in: text, startingAt: markerRange.upperBound) else {
                    searchStart = markerRange.upperBound
                    continue
                }
                let arraySlice = String(text[arrayRange])
                if let decoded = decodeArray(arraySlice) {
                    results.append(contentsOf: decoded.compactMap { toPendingCall($0) })
                }
                searchStart = arrayRange.upperBound
            }
        }

        return results
    }

    private func toPendingCall(_ obj: ToolCallObject) -> PendingToolCall? {
        guard let resolvedName = obj.resolvedName else {
            logger.warning("GraniteLegacyParser: Decoded object missing name/tool_name — skipping.")
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
            logger.info("GraniteLegacyParser: Decoded array after sanitization.")
            return decoded
        }
        logger.warning("GraniteLegacyParser: Failed to decode array: \(trimmed.count) chars (snippet at debug: model output is content, CR-57)")
        logger.debug("GraniteLegacyParser: snippet: \(trimmed.prefix(200))")
        return nil
    }

    private func balancedJSONArrayRange(in text: String, startingAt: String.Index) -> Range<String.Index>? {
        BalancedJSONScanner.balancedRange(in: text, from: startingAt, opener: "[")
    }

    // Why: whole-payload regexes also rewrote file content in `write_file` arguments (real trailing commas,
    // `Double.NaN`); see `JSONStructuralSanitizer`
    /// Repairs trailing commas and Python literals in the model's JSON, delegating to the shared sanitizer so the
    /// repair happens outside string values only.
    private func sanitizeJSON(_ raw: String) -> String {
        JSONStructuralSanitizer.repairingStructure(raw)
    }

    private func extractReasoning(from text: String, extractedCount: Int) -> String {
        guard extractedCount > 0 else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for marker in Self.markers {
            if let range = text.range(of: marker) {
                let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let filtered = ReasoningQualityFilter.filter(before)
                if !filtered.isEmpty { return filtered }
            }
        }
        return ""
    }
}

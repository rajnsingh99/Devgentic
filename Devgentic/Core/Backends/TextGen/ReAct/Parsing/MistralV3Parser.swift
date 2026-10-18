// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MistralV3Parser.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "MistralV3Parser")

/// Primary parser for the `.mistralV3Array` dialect (older Mistral Tekken tokenizers): `[TOOL_CALLS] [{...}]`.
/// Tolerates a missing `</s>`, repeated markers, a missing `id`, and `parameters` as an alias for `arguments`.
struct MistralV3Parser: CognitiveParserProtocol {

    /// Mistral v3 tool call object. `id` is template-enforced but we ignore it.
    /// - `name` canonical; `tool_name` accepted as alias (cross-family flat-JSON drift).
    /// - `arguments` canonical; `parameters` accepted as alias (Llama-style leakage).
    private struct ToolCallObject: Decodable {
        let name: String?
        let tool_name: String?
        let arguments: [String: JSONValue]?
        let parameters: [String: JSONValue]?
        let id: String?

        var resolvedName: String? {
            if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
            if let n = tool_name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
            return nil
        }

        var resolvedArguments: [String: JSONValue] {
            arguments ?? parameters ?? [:]
        }
    }

    private static let marker = "[TOOL_CALLS]"

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let calls = extractToolCalls(from: rawResponse)
        let reasoning = extractReasoning(from: rawResponse, extractedCount: calls.count)

        if !calls.isEmpty {
            logger.info("MistralV3Parser: Extracted \(calls.count) tool call(s): \(calls.map { $0.name }.joined(separator: ", "))")
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: calls)
        }

        logger.warning("MistralV3Parser: No [TOOL_CALLS] array found. Treating as conversational exit.")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }

    // MARK: - Extraction

    /// Splits on `[TOOL_CALLS]` markers (drops the prose before the first) and parses
    /// a balanced JSON array after each marker. Handles both single and multiple markers.
    private func extractToolCalls(from text: String) -> [PendingToolCall] {
        var results: [PendingToolCall] = []
        let segments = text.components(separatedBy: Self.marker).dropFirst()

        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let arrayRange = balancedJSONArrayRange(in: trimmed, startingAt: trimmed.startIndex) else {
                logger.warning("MistralV3Parser: Failed to locate balanced JSON array after marker.")
                continue
            }
            let arraySlice = String(trimmed[arrayRange])
            guard let data = arraySlice.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([ToolCallObject].self, from: data) else {
                // Retry after sanitization
                let sanitized = sanitizeJSON(arraySlice)
                if sanitized != arraySlice,
                   let data2 = sanitized.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode([ToolCallObject].self, from: data2) {
                    logger.info("MistralV3Parser: Decoded array after sanitization.")
                    results.append(contentsOf: decoded.compactMap { toPendingCall($0) })
                    continue
                }
                logger.warning("MistralV3Parser: Failed to decode JSON array: \(arraySlice.count) chars (snippet at debug: model output is content, CR-57)")
                logger.debug("MistralV3Parser: snippet: \(arraySlice.prefix(200))")
                continue
            }
            results.append(contentsOf: decoded.compactMap { toPendingCall($0) })
        }

        return results
    }

    private func toPendingCall(_ obj: ToolCallObject) -> PendingToolCall? {
        guard let resolvedName = obj.resolvedName else {
            logger.warning("MistralV3Parser: Decoded object has no `name` or `tool_name` — skipping.")
            return nil
        }
        return PendingToolCall(
            id: obj.id ?? UUID().uuidString,
            name: resolvedName,
            arguments: obj.resolvedArguments
        )
    }

    /// Finds first balanced `[...]` JSON array starting at or after `startingAt`,
    /// tracking string state so brackets inside quoted strings don't affect depth.
    private func balancedJSONArrayRange(in text: String, startingAt: String.Index) -> Range<String.Index>? {
        BalancedJSONScanner.balancedRange(in: text, from: startingAt, opener: "[")
    }

    /// Repairs trailing commas and Python literals in the model's JSON via the shared sanitizer, which repairs only outside
    /// string values so file content in a `write_file` call is untouched; see `JSONStructuralSanitizer`.
    private func sanitizeJSON(_ raw: String) -> String {
        JSONStructuralSanitizer.repairingStructure(raw)
    }

    /// Prose text before the first `[TOOL_CALLS]` marker.
    private func extractReasoning(from text: String, extractedCount: Int) -> String {
        guard extractedCount > 0 else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = text.range(of: Self.marker) {
            let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ReasoningQualityFilter.filter(before)
        }
        return ""
    }
}

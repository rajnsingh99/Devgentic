// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MistralV11Parser.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "MistralV11Parser")

/// Primary parser for the `.mistralV11Flat` dialect (Mistral tokenizer v11 and later): flat
/// `[TOOL_CALLS]name[ARGS]{json}` blocks, one per call. Tolerates whitespace around the markers, trailing `</s>` or
/// `<|im_end|>`, and sanitized JSON.
struct MistralV11Parser: CognitiveParserProtocol {

    private static let callMarker = "[TOOL_CALLS]"
    private static let argsMarker = "[ARGS]"

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let calls = extractToolCalls(from: rawResponse)
        let reasoning = extractReasoning(from: rawResponse, extractedCount: calls.count)

        if !calls.isEmpty {
            logger.info("MistralV11Parser: Extracted \(calls.count) tool call(s): \(calls.map { $0.name }.joined(separator: ", "))")
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: calls)
        }

        logger.warning("MistralV11Parser: No [TOOL_CALLS]<name>[ARGS] pattern found. Treating as conversational exit.")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }

    // MARK: - Extraction

    /// For each `[TOOL_CALLS]` occurrence, extract the function name (up to `[ARGS]`)
    /// and the balanced JSON object after `[ARGS]`.
    private func extractToolCalls(from text: String) -> [PendingToolCall] {
        var results: [PendingToolCall] = []
        var searchStart = text.startIndex

        while let callRange = text.range(of: Self.callMarker, options: [], range: searchStart..<text.endIndex) {
            // Locate the `[ARGS]` marker after this `[TOOL_CALLS]` occurrence.
            guard let argsRange = text.range(of: Self.argsMarker, options: [], range: callRange.upperBound..<text.endIndex) else {
                logger.warning("MistralV11Parser: [TOOL_CALLS] without matching [ARGS] — skipping.")
                searchStart = callRange.upperBound
                continue
            }

            // Name is everything between end-of-[TOOL_CALLS] and start-of-[ARGS], trimmed.
            let name = String(text[callRange.upperBound..<argsRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                logger.warning("MistralV11Parser: Empty tool name between [TOOL_CALLS] and [ARGS] — skipping.")
                searchStart = argsRange.upperBound
                continue
            }

            // Args JSON starts after [ARGS]. Extract balanced `{...}`.
            guard let jsonRange = balancedJSONObjectRange(in: text, startingAt: argsRange.upperBound) else {
                logger.warning("MistralV11Parser: No balanced JSON after [ARGS] for '\(name)' — skipping.")
                searchStart = argsRange.upperBound
                continue
            }

            let argsBody = String(text[jsonRange])
            let arguments = decodeArguments(from: argsBody) ?? [:]

            results.append(PendingToolCall(
                id: UUID().uuidString,
                name: name,
                arguments: arguments
            ))

            searchStart = jsonRange.upperBound
        }

        return results
    }

    private func decodeArguments(from jsonString: String) -> [String: JSONValue]? {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }

        if let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            return decoded
        }

        // Retry after sanitization.
        let sanitized = sanitizeJSON(trimmed)
        if sanitized != trimmed,
           let data2 = sanitized.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data2) {
            logger.info("MistralV11Parser: Decoded args after sanitization.")
            return decoded
        }

        logger.warning("MistralV11Parser: Failed to decode [ARGS] JSON: \(trimmed.count) chars (snippet at debug: model output is content, CR-57)")
        logger.debug("MistralV11Parser: snippet: \(trimmed.prefix(200))")
        return nil
    }

    /// Tracks string state so braces inside quoted strings don't affect depth.
    private func balancedJSONObjectRange(in text: String, startingAt: String.Index) -> Range<String.Index>? {
        BalancedJSONScanner.balancedRange(in: text, from: startingAt, opener: "{")
    }

    /// Repairs trailing commas and Python literals in the model's JSON. Delegates to the shared sanitizer so the repair
    /// applies outside string values only (see `JSONStructuralSanitizer`).
    private func sanitizeJSON(_ raw: String) -> String {
        JSONStructuralSanitizer.repairingStructure(raw)
    }

    /// Prose text before the first `[TOOL_CALLS]` marker.
    private func extractReasoning(from text: String, extractedCount: Int) -> String {
        guard extractedCount > 0 else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = text.range(of: Self.callMarker) {
            let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ReasoningQualityFilter.filter(before)
        }
        return ""
    }
}

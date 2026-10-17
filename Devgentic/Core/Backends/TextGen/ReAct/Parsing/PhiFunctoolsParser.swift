// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PhiFunctoolsParser.swift
//  Devgentic
//
//  Phase 4 — Native-tool dialect expansion (2026-04-22).
//  Primary parser for the `.phiFunctoolsBracket` dialect.
//
//  Covers:
//    - microsoft/Phi-4-mini-instruct
//    - microsoft/Phi-4-mini-reasoning (partial — tool output when present)
//    - fireworks-ai/firefunction-v2 (same output shape, different family)
//
//  Canonical output:
//
//    functools[{"name": "list_directory", "arguments": {"path": "/tmp"}}]
//
//  Structurally similar to Mistral v3's `[TOOL_CALLS] [...]` but with a different
//  marker. Multiple calls = one array with multiple objects.
//
//  Drift tolerated:
//   - `tool_name` alias for `name` (cross-family flat-JSON drift)
//   - `parameters` alias for `arguments` (Llama-style leakage)
//   - Python literals (True/False/None → true/false/null)
//   - Multiple `functools[` markers on separate lines (segment each array)
//   - Missing trailing `]` (brace-balance recovery via extractor)
//

import Foundation
import OSLog

private let logger = DGLogger(category: "PhiFunctoolsParser")

struct PhiFunctoolsParser: CognitiveParserProtocol {

    /// Accepts `name` and `tool_name` aliases; `arguments` and `parameters` aliases.
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

    private static let marker = "functools["

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let calls = extractToolCalls(from: rawResponse)
        let reasoning = extractReasoning(from: rawResponse, extractedCount: calls.count)

        if !calls.isEmpty {
            logger.info("PhiFunctoolsParser: Extracted \(calls.count) tool call(s): \(calls.map { $0.name }.joined(separator: ", "))")
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: calls)
        }

        logger.warning("PhiFunctoolsParser: No functools[] marker found. Treating as conversational exit.")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }

    // MARK: - Extraction

    /// Segment on `functools[` markers; for each segment, extract the balanced JSON array
    /// that follows (counting `[` we already consumed in the marker — so start depth at 1).
    private func extractToolCalls(from text: String) -> [PendingToolCall] {
        var results: [PendingToolCall] = []
        var searchStart = text.startIndex

        while let markerRange = text.range(of: Self.marker, range: searchStart..<text.endIndex) {
            // The `[` in `functools[` is our array opener; track balance from there.
            // The body runs from markerRange.upperBound until the matching `]`.
            let openIdx = text.index(before: markerRange.upperBound)
            guard let endIdx = balancedArrayEnd(in: text, openBracket: openIdx) else {
                logger.warning("PhiFunctoolsParser: Unbalanced functools[ — no matching ].")
                searchStart = markerRange.upperBound
                continue
            }

            let arraySlice = String(text[openIdx...endIdx])
            if let decoded = decodeArray(arraySlice) {
                results.append(contentsOf: decoded.compactMap { toPendingCall($0) })
            }
            searchStart = text.index(after: endIdx)
        }

        return results
    }

    private func toPendingCall(_ obj: ToolCallObject) -> PendingToolCall? {
        guard let resolvedName = obj.resolvedName else {
            logger.warning("PhiFunctoolsParser: Decoded object missing name/tool_name — skipping.")
            return nil
        }
        return PendingToolCall(
            id: UUID().uuidString,
            name: resolvedName,
            arguments: obj.resolvedArguments
        )
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
            logger.info("PhiFunctoolsParser: Decoded array after sanitization.")
            return decoded
        }
        logger.warning("PhiFunctoolsParser: Failed to decode array: \(trimmed.count) chars (snippet at debug: model output is content, CR-57)")
        logger.debug("PhiFunctoolsParser: snippet: \(trimmed.prefix(200))")
        return nil
    }

    /// Finds the index of the matching `]` for an opening `[`. Tracks string state
    /// so brackets inside quoted strings don't affect depth.
    /// Returns index OF the closing `]` (inclusive).
    private func balancedArrayEnd(in text: String, openBracket: String.Index) -> String.Index? {
        guard text[openBracket] == "[" else { return nil }

        var depth = 0
        var inString = false
        var escaped = false

        for idx in text[openBracket...].indices {
            let c = text[idx]
            if escaped {
                escaped = false
                continue
            }
            if c == "\\" && inString {
                escaped = true
                continue
            }
            if c == "\"" {
                inString.toggle()
                continue
            }
            if inString { continue }
            if c == "[" { depth += 1 }
            else if c == "]" {
                depth -= 1
                if depth == 0 { return idx }
            }
        }
        return nil
    }

    /// Repairs trailing commas and Python literals in the model's JSON.
    ///
    /// Delegates to the shared sanitizer so the repair happens OUTSIDE string values only.
    /// This used to be eleven copies of the same two whole-payload regexes, each of which
    /// also rewrote the file content carried in a `write_file` call's `arguments.content` —
    /// deleting real trailing commas from array initializers and turning `Double.NaN` into
    /// `Double.null`. See `JSONStructuralSanitizer` for the full account.
    private func sanitizeJSON(_ raw: String) -> String {
        JSONStructuralSanitizer.repairingStructure(raw)
    }

    /// Prose text before the first `functools[` marker.
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

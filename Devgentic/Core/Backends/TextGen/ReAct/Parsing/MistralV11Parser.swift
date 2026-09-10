// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MistralV11Parser.swift
//  Devgentic
//
//  Phase 3 — Native-tool dialect expansion (2026-04-22).
//  Primary parser for the `.mistralV11Flat` dialect — Mistral 2025+ tokenizer family.
//
//  Covers:
//    - mistralai/Mistral-Small-3.1-24B-Instruct-2503
//    - mistralai/Mistral-Small-3.2-24B-Instruct-2506
//    - mistralai/Mistral-Medium-2025+
//    - mistralai/Devstral-Small-2505, Devstral-Small-2507
//    - Other Mistral releases with tokenizer_version >= v11
//
//  Canonical output (parallel calls = multiple flat blocks concatenated):
//
//    [TOOL_CALLS]list_directory[ARGS]{"path":"/tmp"}
//    [TOOL_CALLS]write_file[ARGS]{"path":"/tmp/a.txt","content":"hi"}
//
//  Structurally DIFFERENT from v3 (no JSON array wrapper; name and args are split
//  by the `[ARGS]` marker). That's why v3 and v11 live in separate parsers.
//
//  Drift tolerated:
//   - Whitespace between `[TOOL_CALLS]`, name, and `[ARGS]`
//   - Trailing `</s>` or `<|im_end|>` tokens
//   - Sanitized JSON (trailing commas, Python literals)
//

import Foundation
import OSLog

private let logger = DGLogger(category: "MistralV11Parser")

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

        logger.warning("MistralV11Parser: Failed to decode [ARGS] JSON: \(trimmed.prefix(200))")
        return nil
    }

    /// Tracks string state so braces inside quoted strings don't affect depth.
    private func balancedJSONObjectRange(in text: String, startingAt: String.Index) -> Range<String.Index>? {
        BalancedJSONScanner.balancedRange(in: text, from: startingAt, opener: "{")
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

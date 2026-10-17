// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  Llama3JsonParser.swift
//  Devgentic
//
//  Phase 3 — Native-tool dialect expansion (2026-04-22).
//  Primary parser for the `.llama3JsonSingle` dialect.
//
//  Handles the native output shape of Llama-3.1 / 3.2 / 3.3 Instruct:
//
//    <|python_tag|>{"name": "list_directory", "parameters": {"path": "/tmp"}}<|eot_id|>
//
//  ... or without the python_tag prefix (most common when the tool is NOT a builtin):
//
//    {"name": "list_directory", "parameters": {"path": "/tmp"}}
//
//  SINGLE-CALL ONLY — the Llama 3.x chat template raises an exception for more
//  than one tool call per message. Multiple calls in the raw are anomalous drift
//  and we parse only the FIRST one.
//
//  Recovery budget:
//   - Strip `<|python_tag|>` / `<|eot_id|>` / `<|eom_id|>` markers before decoding
//   - Accept `"arguments"` as alias for `"parameters"` (Q4 drift, Qwen-style leakage)
//   - Accept `"tool_name"` as alias for `"name"` (cross-family flat-JSON drift —
//     Llama 3.1-8B-4bit and Qwen 2.5-3B-4bit BOTH emit `{content, tool_name, arguments}`
//     regardless of their native chat template. Common pre-training pattern dominates
//     at Q4 quantization.)
//   - Handle brace-enclosed JSON even if surrounding prose exists
//   - Sanitize Python literals (True/False/None → true/false/null)
//

import Foundation
import OSLog

private let logger = DGLogger(category: "Llama3JsonParser")

struct Llama3JsonParser: CognitiveParserProtocol {

    /// Canonical decoded shape with tolerance for small-model key drift.
    /// - `name` is canonical; `tool_name` accepted as alias (cross-family flat-JSON drift).
    /// - `parameters` is canonical; `arguments` accepted as alias (Qwen-style leakage).
    /// - `content` captured for reasoning extraction (present in flat-JSON drift output).
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
        // Require canonical `"name"` OR alias `"tool_name"` — otherwise any JSON
        // object would spuriously match. Note: `"name"` means the literal 6 chars
        // `"name"` (with surrounding quotes), which does NOT appear inside `"tool_name"`.
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
    ///
    /// Delegates to the shared sanitizer so the repair happens OUTSIDE string values only.
    /// This used to be eleven copies of the same two whole-payload regexes, each of which
    /// also rewrote the file content carried in a `write_file` call's `arguments.content` —
    /// deleting real trailing commas from array initializers and turning `Double.NaN` into
    /// `Double.null`. See `JSONStructuralSanitizer` for the full account.
    private func sanitizeJSON(_ raw: String) -> String {
        JSONStructuralSanitizer.repairingStructure(raw)
    }

    /// Reasoning priority:
    ///   1. Prose text before the first `{` in the stripped raw (pure-prose path).
    ///   2. `content` field from the decoded tool call JSON (flat-JSON drift shape —
    ///      `{"content":"...", "tool_name":"...", ...}` has reasoning embedded in the object).
    ///   3. Empty (no reasoning produced).
    ///
    /// Both the prose path and the content-field path are routed through
    /// `ReasoningQualityFilter`. Llama-3.1 / 3.2 / 3.3 instruction-tuned models
    /// (especially at Q4) routinely fill the `content` slot with stock phrases
    /// like "Executing tool list_directory..." that look like reasoning but carry
    /// no signal beyond the tool name. The filter strips those while passing
    /// real reasoning through unchanged.
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
    /// Used when the model emits `{"content":"...", "tool_name":"...", ...}` with
    /// no prose text outside the JSON object. Sanitizes Python literals first so
    /// drifted JSON (`False`/`None`) decodes.
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

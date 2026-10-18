// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  QwenHermesJsonParser.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "QwenHermesJsonParser")

/// Primary parser for the `.qwenHermesToolCall` dialect (Qwen2.5/3, Hermes-2-Pro/3 and similar): JSON inside
/// `<tool_call>` tags, with parallel blocks. Recovers common Q4 drift: missing closer, reversed keys,
/// `parameters`/`tool_name` aliases and bare JSON.
struct QwenHermesJsonParser: CognitiveParserProtocol {

    /// Canonical decoded shape, tolerant of small-model key-name drift: `tool_name` is accepted as an alias of `name`,
    /// `parameters` of `arguments`, and `content` is ignored here.
    private struct ToolCallObject: Decodable {
        let name: String?
        let tool_name: String?
        let arguments: [String: JSONValue]?
        let parameters: [String: JSONValue]?
        let content: String?

        var resolvedName: String? {
            if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
            if let n = tool_name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
            return nil
        }

        var resolvedArguments: [String: JSONValue] {
            arguments ?? parameters ?? [:]
        }
    }

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let toolCalls = extractToolCalls(from: rawResponse)
        let reasoning = extractReasoning(from: rawResponse, extractedCount: toolCalls.count)

        if !toolCalls.isEmpty {
            logger.info("QwenHermesJsonParser: Extracted \(toolCalls.count) tool call(s): \(toolCalls.map { $0.name }.joined(separator: ", "))")
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: toolCalls)
        }

        logger.warning("QwenHermesJsonParser: No <tool_call> wrapper or bare tool JSON found. Treating as conversational exit.")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }

    /// Best-effort reasoning from a flat JSON body's `content` field, if present.
    /// Used when the model emits `{"content":"...", "tool_name":"...", "arguments":{...}}`
    /// without a `<tool_call>` wrapper.
    private func extractContentFieldFromBareJSON(_ text: String) -> String? {
        guard let range = balancedJSONObjectRange(in: text, startingAt: text.startIndex) else { return nil }
        let body = String(text[range])
        guard let data = body.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ToolCallObject.self, from: data),
              let content = decoded.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            return nil
        }
        return content
    }

    // MARK: - Extraction

    private func extractToolCalls(from text: String) -> [PendingToolCall] {
        var results: [PendingToolCall] = []

        // Style 1: Properly-closed wrappers: <tool_call> ... {JSON} ... </tool_call>
        //   Non-greedy body match; `[\s\S]` to cross newlines.
        let closedPattern = #"<tool_call>\s*([\s\S]*?)\s*</tool_call>"#
        if let regex = try? NSRegularExpression(pattern: closedPattern, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let bodyRange = Range(match.range(at: 1), in: text) else { continue }
                let body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let call = decodeToolCall(from: body) {
                    results.append(call)
                }
            }
        }

        // Style 2, unclosed wrapper drift: `<tool_call>` followed by a balanced JSON object with no closer (common with Q4
        // small models). Scan each occurrence and extract a balanced object after it.
        if results.isEmpty {
            results.append(contentsOf: extractFromUnclosedWrappers(text))
        }

        // Style 3: Bare JSON object with a `name` key, no wrapper.
        //   Last-resort: the model dropped the wrapper entirely but still emitted structured JSON.
        if results.isEmpty {
            if let call = extractBareToolJSON(text) {
                results.append(call)
            }
        }

        return results
    }

    private func extractFromUnclosedWrappers(_ text: String) -> [PendingToolCall] {
        var results: [PendingToolCall] = []
        var searchStart = text.startIndex
        let openTag = "<tool_call>"

        while let tagRange = text.range(of: openTag, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            let afterTag = tagRange.upperBound
            if let jsonRange = balancedJSONObjectRange(in: text, startingAt: afterTag) {
                let body = String(text[jsonRange])
                if let call = decodeToolCall(from: body) {
                    results.append(call)
                }
                searchStart = jsonRange.upperBound
            } else {
                // No balanced object after the tag. A doubled-brace truncation (`{{"name": …}`) is unbalanced as a whole, so hand
                // the remainder through, gated on the `{{` prefix so only the targeted repair path runs.
                let remainder = String(text[afterTag...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if remainder.hasPrefix("{{"), let call = decodeToolCall(from: remainder) {
                    results.append(call)
                }
                searchStart = afterTag
            }
        }

        return results
    }

    private func extractBareToolJSON(_ text: String) -> PendingToolCall? {
        // Require either canonical `name` OR alias `tool_name` to appear —
        // otherwise any JSON object would spuriously match.
        guard text.contains("\"name\"") || text.contains("\"tool_name\"") else { return nil }
        guard let range = balancedJSONObjectRange(in: text, startingAt: text.startIndex) else { return nil }
        let body = String(text[range])
        return decodeToolCall(from: body)
    }

    /// Finds the first balanced `{...}` JSON object starting at or after `startingAt`.
    /// Tracks string state so braces inside quoted strings don't affect depth.
    private func balancedJSONObjectRange(in text: String, startingAt: String.Index) -> Range<String.Index>? {
        BalancedJSONScanner.balancedRange(in: text, from: startingAt, opener: "{")
    }

    // MARK: - Decoding

    private func decodeToolCall(from jsonString: String) -> PendingToolCall? {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let call = decodeStrict(trimmed) {
            return call
        }

        // Doubled-brace repair: `{{` at the start of a candidate is never valid JSON, so drop one leading brace and keep the
        // first balanced object. No string content is touched and every firing is logged.
        if trimmed.hasPrefix("{{") {
            let stripped = String(trimmed.dropFirst())
            let candidate = BalancedJSONScanner.firstObject(in: stripped).map(String.init) ?? stripped
            if let call = decodeStrict(candidate) {
                logger.warning("[PARSE-REPAIR] Doubled-brace tool call repaired ({{…}} → {…}, \(trimmed.count) → \(candidate.count) chars) — the known corrupt-template output shape. CONSEQUENCE: the call is recovered instead of failing the parse; if this fires on MLX, the render-side ChatTemplateRepair did not cover this model and its template needs a register entry.")
                return call
            }
        }

        logger.warning("QwenHermesJsonParser: Failed to decode tool call JSON: \(trimmed.count) chars (snippet at debug: model output is content, CR-57)")
        logger.debug("QwenHermesJsonParser: snippet: \(trimmed.prefix(200))")
        return nil
    }

    /// The two ordinary decode attempts — verbatim, then structurally sanitized (trailing commas,
    /// Python literals). Factored out so the doubled-brace repair reuses them without recursing
    /// into itself.
    private func decodeStrict(_ trimmed: String) -> PendingToolCall? {
        guard let data = trimmed.data(using: .utf8) else { return nil }

        if let decoded = try? JSONDecoder().decode(ToolCallObject.self, from: data),
           let resolved = decoded.resolvedName {
            return PendingToolCall(
                id: UUID().uuidString,
                name: resolved,
                arguments: decoded.resolvedArguments
            )
        }

        // Sanitize common drift and retry: trailing commas, Python literals.
        let sanitized = sanitizeJSON(trimmed)
        if sanitized != trimmed,
           let data2 = sanitized.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ToolCallObject.self, from: data2),
           let resolved = decoded.resolvedName {
            logger.info("QwenHermesJsonParser: Decoded after sanitization.")
            return PendingToolCall(
                id: UUID().uuidString,
                name: resolved,
                arguments: decoded.resolvedArguments
            )
        }

        return nil
    }

    /// Repairs trailing commas and Python literals in the model's JSON, outside string values only, via the shared
    /// sanitizer (see `JSONStructuralSanitizer`).
    private func sanitizeJSON(_ raw: String) -> String {
        JSONStructuralSanitizer.repairingStructure(raw)
    }

    // MARK: - Reasoning extraction

    /// Reasoning priority: prose before the first `<tool_call>` wrapper, else the `content` field of a bare JSON object,
    /// else empty. Both paths go through `ReasoningQualityFilter`, since Q4 models fill `content` with stock phrases that
    /// carry no signal.
    private func extractReasoning(from text: String, extractedCount: Int) -> String {
        guard extractedCount > 0 else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = text.range(of: "<tool_call>", options: .caseInsensitive) {
            let before = String(text[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let filtered = ReasoningQualityFilter.filter(before)
            if !filtered.isEmpty { return filtered }
        }
        if let content = extractContentFieldFromBareJSON(text) {
            return ReasoningQualityFilter.filter(content)
        }
        return ""
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  Qwen3CoderDeepXMLParser.swift
//  Devgentic
//
//  Phase 5 — Native-tool dialect expansion (2026-04-22).
//  Primary parser for the `.qwen3CoderDeepXml` dialect (Qwen3-Coder 30B-A3B, 480B-A35B).
//
//  Canonical output — deep XML with structural tags (NOT JSON inside):
//
//    <tool_call>
//    <function=read_file>
//    <parameter=path>
//    /path/to/file.txt
//    </parameter>
//    <parameter=encoding>
//    utf-8
//    </parameter>
//    </function>
//    </tool_call>
//
//  Parallel calls = multiple `<function=...>` blocks inside `<tool_call>` OR
//  multiple `<tool_call>` wrappers concatenated.
//
//  Quirks from vLLM's qwen3coder_tool_parser.py:
//   - Parameter values are TEXT (not JSON) — type-coerced from declared schema.
//   - `"null"` (case-insensitive) → nil / JSON null.
//   - Leading/trailing newlines stripped from values.
//   - Invalid type → graceful string degradation (keep raw text).
//

import Foundation
import OSLog

private let logger = DGLogger(category: "Qwen3CoderDeepXMLParser")

struct Qwen3CoderDeepXMLParser: CognitiveParserProtocol {

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let calls = extractToolCalls(from: rawResponse)
        let reasoning = extractReasoning(from: rawResponse, extractedCount: calls.count)

        if !calls.isEmpty {
            logger.info("Qwen3CoderDeepXMLParser: Extracted \(calls.count) tool call(s): \(calls.map { $0.name }.joined(separator: ", "))")
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: calls)
        }

        logger.warning("Qwen3CoderDeepXMLParser: No <function=...> blocks found. Treating as conversational exit.")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }

    // MARK: - Extraction

    /// Matches each `<function=NAME>...</function>` block and parses the nested parameters.
    private func extractToolCalls(from text: String) -> [PendingToolCall] {
        var results: [PendingToolCall] = []

        // Find all `<function=...>...</function>` blocks (may be inside <tool_call> wrappers).
        let pattern = #"<function=([A-Za-z_][A-Za-z0-9_.]*)>([\s\S]*?)</function>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            logger.error("Qwen3CoderDeepXMLParser: Regex compile failed.")
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else { continue }

            let name = String(text[nameRange])
            let body = String(text[bodyRange])
            let arguments = extractParameters(from: body)

            results.append(PendingToolCall(
                id: UUID().uuidString,
                name: name,
                arguments: arguments
            ))
        }

        return results
    }

    /// Parses `<parameter=KEY>value</parameter>` pairs from a function body.
    private func extractParameters(from body: String) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        let pattern = #"<parameter=([A-Za-z_][A-Za-z0-9_]*)>([\s\S]*?)</parameter>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }

        let range = NSRange(body.startIndex..., in: body)
        for match in regex.matches(in: body, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: body),
                  let valueRange = Range(match.range(at: 2), in: body) else { continue }

            let key = String(body[keyRange])
            // ⚠️⚠️ CR-21: the TEXT, kept as written — one framing newline trimmed each side (what
            // vLLM's parser does), never all whitespace. Types come from the tool's SCHEMA in
            // `CognitiveParsePipeline.coercingToSchema`, not from what the value looks like: shape
            // typing turned `{"name":"app"}` content into an object (`write_file` then failed on
            // every JSON file), `1.10` into `1.1`, and dropped trailing newlines from file content.
            result[key] = .string(Self.trimmingOneFramingNewline(String(body[valueRange])))
        }
        return result
    }

    /// Removes at most one newline at each end — the line breaks around `<parameter=…>` tags.
    static func trimmingOneFramingNewline(_ raw: String) -> String {
        var value = Substring(raw)
        if value.hasPrefix("\r\n") { value = value.dropFirst(2) } else if value.hasPrefix("\n") { value = value.dropFirst() }
        if value.hasSuffix("\r\n") { value = value.dropLast(2) } else if value.hasSuffix("\n") { value = value.dropLast() }
        return String(value)
    }

    private func extractReasoning(from text: String, extractedCount: Int) -> String {
        guard extractedCount > 0 else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Prose before first <tool_call> or <function= marker.
        for marker in ["<tool_call>", "<function="] {
            if let range = text.range(of: marker) {
                let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let filtered = ReasoningQualityFilter.filter(before)
                if !filtered.isEmpty { return filtered }
            }
        }
        return ""
    }
}

//
//  QwenHermesJsonParser.swift
//  Devgentic
//
//  Phase 2 — Dialect taxonomy expansion (2026-04-22).
//  Primary parser for the `.qwenHermesToolCall` dialect.
//  Handles the native output shape of Qwen2.5/3 Instruct, Qwen3 base, Hermes-2-Pro,
//  Hermes-3, and structurally identical fine-tunes:
//
//      <tool_call>
//      {"name": "search", "arguments": {"q": "Paris"}}
//      </tool_call>
//
//  Multiple consecutive `<tool_call>` blocks are parallel calls.
//  Reasoning/commentary text outside the wrappers becomes the step's reasoning.
//
//  Recovery budget — handles common Q4 quantization drift:
//   - Missing closing `</tool_call>` (balanced-brace JSON extraction)
//   - Reversed key order (`{"arguments":..., "name":...}`)
//   - `"parameters"` instead of `"arguments"` (Llama-3 key leakage)
//   - `"tool_name"` instead of `"name"` (Mistral/hybrid key leakage — small-model drift)
//   - Bare JSON object with a name key but no `<tool_call>` wrapper
//   - Optional `"content"` field inside the bare JSON (hybrid flat shape from Qwen2.5-3B-Q4)
//   - Whitespace/newline variance between tag and JSON body
//

import Foundation
import OSLog

private let logger = DGLogger(category: "QwenHermesJsonParser")

struct QwenHermesJsonParser: CognitiveParserProtocol {

    /// Canonical decoded shape, tolerant of small-model key-name drift.
    /// - `name` is the canonical key; `tool_name` is accepted as an alias (Mistral/hybrid leakage).
    /// - `arguments` is canonical; `parameters` is accepted as an alias (Llama-3 key leakage).
    /// - `content` is ignored here; reasoning is extracted separately at the step level.
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

        // Style 2: Unclosed wrapper drift — <tool_call> followed by balanced {JSON} with no closer.
        //   Common with Q4 small models that drop trailing tokens. Scan each `<tool_call>` occurrence
        //   and try to extract a balanced JSON object starting after it.
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
        guard let openIdx = text[startingAt...].firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false

        for idx in text[openIdx...].indices {
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
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 {
                    let endIdx = text.index(after: idx)
                    return openIdx..<endIdx
                }
            }
        }
        return nil
    }

    // MARK: - Decoding

    private func decodeToolCall(from jsonString: String) -> PendingToolCall? {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
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

        logger.warning("QwenHermesJsonParser: Failed to decode tool call JSON: \(trimmed.prefix(200))")
        return nil
    }

    private func sanitizeJSON(_ raw: String) -> String {
        var s = raw
        // Trailing commas before } or ]
        if let regex = try? NSRegularExpression(pattern: #",\s*([}\]])"#) {
            s = regex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1"
            )
        }
        // Python literals → JSON
        let subs: [(String, String)] = [
            (#"\bTrue\b"#, "true"),
            (#"\bFalse\b"#, "false"),
            (#"\bNone\b"#, "null")
        ]
        for (pattern, replacement) in subs {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                s = regex.stringByReplacingMatches(
                    in: s, range: NSRange(s.startIndex..., in: s), withTemplate: replacement
                )
            }
        }
        return s
    }

    // MARK: - Reasoning extraction

    /// Reasoning priority:
    ///   1. Prose text before the first `<tool_call>` wrapper (wrapped path).
    ///   2. `content` field from a bare JSON object (flat-shape Q4 drift path).
    ///   3. Empty (no reasoning produced).
    ///
    /// Both extraction paths are routed through `ReasoningQualityFilter`.
    /// Qwen2.5/3 and Hermes-2/3-Pro at Q4 routinely fill the `content` slot
    /// with stock phrases like "Executing tool fs_smart_search..." that look
    /// like reasoning but carry no signal beyond the tool name.
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

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
                // No balanced object after the tag. One OBSERVED reason: the doubled-brace
                // corruption truncated at EOS — `{{"name": …, "arguments": {…}}` — is unbalanced
                // as a whole (depth never returns to 0), so the scanner cannot find it and the
                // repair in `decodeToolCall` would never see it. Hand the remainder through,
                // gated on the `{{` prefix so this stays the targeted repair path and not a
                // general re-parse of arbitrary trailing text.
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

        // ⚠️ DOUBLED-BRACE REPAIR (observed 2026-08-21). `mlx-community/Qwen2.5-3B-Instruct-4bit`
        // ships a chat template whose tool-call example reads `{{\"name\": ...}}` — an upstream
        // f-string escaping artifact — and the model copies it faithfully:
        //
        //     <tool_call>
        //     {{"name": "execute_shell", "arguments": {"command": "/Users/alice/Desktop"}}
        //     }}
        //     </tool_call>
        //
        // The render path repairs that template (`ChatTemplateRepair`), so on MLX this branch
        // should never fire — it is DEFENSE IN DEPTH for output that reaches this parser from a
        // route the repair does not cover: another provider serving the same corrupt artifact, or
        // a sibling model trained/templated the same way.
        //
        // Discipline (the recovery-budget rules this file already lives by):
        //   • STRUCTURAL POSITION ONLY. `{{` at the very start of a candidate is never valid
        //     JSON — an object's first non-whitespace child cannot be another bare `{` — so the
        //     trigger cannot be content. A `{{` INSIDE a string value (a sed script, a template
        //     file) is protected twice over: it cannot be at position zero, and the re-scan below
        //     is string/escape-aware, so it never counts quoted braces.
        //   • The mutation is exactly: drop ONE leading brace, then keep the first balanced
        //     object and discard trailing garbage (the model's orphaned `}}`). No byte inside any
        //     string value is touched.
        //   • Logged on every firing — a silent repair of model output would be the same sin as
        //     the silent framework discard this whole incident started from.
        if trimmed.hasPrefix("{{") {
            let stripped = String(trimmed.dropFirst())
            let candidate = BalancedJSONScanner.firstObject(in: stripped).map(String.init) ?? stripped
            if let call = decodeStrict(candidate) {
                logger.warning("[PARSE-REPAIR] Doubled-brace tool call repaired ({{…}} → {…}, \(trimmed.count) → \(candidate.count) chars) — the known corrupt-template output shape. CONSEQUENCE: the call is recovered instead of failing the parse; if this fires on MLX, the render-side ChatTemplateRepair did not cover this model and its template needs a register entry.")
                return call
            }
        }

        logger.warning("QwenHermesJsonParser: Failed to decode tool call JSON: \(trimmed.prefix(200))")
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

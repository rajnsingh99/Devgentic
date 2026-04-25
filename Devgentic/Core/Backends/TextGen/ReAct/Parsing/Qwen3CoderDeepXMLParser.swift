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
            let rawValue = String(body[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            result[key] = inferValueType(rawValue)
        }
        return result
    }

    /// Coerces a text parameter value to a JSONValue using lightweight type inference.
    /// Falls back to `.string` when nothing more specific matches. No schema lookup —
    /// we preserve the raw text and let downstream tool validation handle mismatches.
    private func inferValueType(_ raw: String) -> JSONValue {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // null / None
        let lowered = trimmed.lowercased()
        if lowered == "null" || lowered == "none" { return .null }

        // booleans
        if lowered == "true" { return .bool(true) }
        if lowered == "false" { return .bool(false) }

        // number
        if let d = Double(trimmed) {
            return .number(d)
        }

        // nested JSON (object / array)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
           (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            if let data = trimmed.data(using: .utf8),
               let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                return value
            }
        }

        // default: string (preserving the raw text including any embedded newlines)
        return .string(raw)
    }

    private func extractReasoning(from text: String, extractedCount: Int) -> String {
        guard extractedCount > 0 else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Prose before first <tool_call> or <function= marker.
        for marker in ["<tool_call>", "<function="] {
            if let range = text.range(of: marker) {
                let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty { return before }
            }
        }
        return "Executing tool calls..."
    }
}

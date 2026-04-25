//
//  GraniteLegacyParser.swift
//  Devgentic
//
//  Phase 5 — Native-tool dialect expansion (2026-04-22).
//  Primary parser for the `.graniteLegacyArray` dialect (IBM Granite 3.0 / 3.1 / 3.2 / 3.3).
//
//  Covers both sub-variants:
//    - Granite 3.0: `<|tool_call|>[{...}, ...]<|end_of_text|>` (ASCII pipes)
//    - Granite 3.1+: `<tool_call>[{...}, ...]` (no pipes)
//
//  Both emit a JSON array of `{name, arguments}` objects — we accept either marker.
//
//  Drift tolerated:
//   - `tool_name` alias for `name`
//   - `parameters` alias for `arguments`
//   - Python literals in args (True/False/None → true/false/null)
//   - Missing closing `</tool_call>` or `<|end_of_text|>`
//

import Foundation
import OSLog

private let logger = DGLogger(category: "GraniteLegacyParser")

struct GraniteLegacyParser: CognitiveParserProtocol {

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

    private static let markers = ["<|tool_call|>", "<tool_call>"]

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let calls = extractToolCalls(from: rawResponse)
        let reasoning = extractReasoning(from: rawResponse, extractedCount: calls.count)

        if !calls.isEmpty {
            logger.info("GraniteLegacyParser: Extracted \(calls.count) tool call(s): \(calls.map { $0.name }.joined(separator: ", "))")
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: calls)
        }

        logger.warning("GraniteLegacyParser: No Granite tool-call marker found. Treating as conversational exit.")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }

    // MARK: - Extraction

    /// Scans for any Granite marker, then extracts the balanced JSON array that follows.
    private func extractToolCalls(from text: String) -> [PendingToolCall] {
        var results: [PendingToolCall] = []

        for marker in Self.markers {
            var searchStart = text.startIndex
            while let markerRange = text.range(of: marker, range: searchStart..<text.endIndex) {
                guard let arrayRange = balancedJSONArrayRange(in: text, startingAt: markerRange.upperBound) else {
                    searchStart = markerRange.upperBound
                    continue
                }
                let arraySlice = String(text[arrayRange])
                if let decoded = decodeArray(arraySlice) {
                    results.append(contentsOf: decoded.compactMap { toPendingCall($0) })
                }
                searchStart = arrayRange.upperBound
            }
        }

        return results
    }

    private func toPendingCall(_ obj: ToolCallObject) -> PendingToolCall? {
        guard let resolvedName = obj.resolvedName else {
            logger.warning("GraniteLegacyParser: Decoded object missing name/tool_name — skipping.")
            return nil
        }
        return PendingToolCall(id: UUID().uuidString, name: resolvedName, arguments: obj.resolvedArguments)
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
            logger.info("GraniteLegacyParser: Decoded array after sanitization.")
            return decoded
        }
        logger.warning("GraniteLegacyParser: Failed to decode array: \(trimmed.prefix(200))")
        return nil
    }

    private func balancedJSONArrayRange(in text: String, startingAt: String.Index) -> Range<String.Index>? {
        guard let openIdx = text[startingAt...].firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false

        for idx in text[openIdx...].indices {
            let c = text[idx]
            if escaped { escaped = false; continue }
            if c == "\\" && inString { escaped = true; continue }
            if c == "\"" { inString.toggle(); continue }
            if inString { continue }
            if c == "[" { depth += 1 }
            else if c == "]" {
                depth -= 1
                if depth == 0 { return openIdx..<text.index(after: idx) }
            }
        }
        return nil
    }

    private func sanitizeJSON(_ raw: String) -> String {
        var s = raw
        if let regex = try? NSRegularExpression(pattern: #",\s*([}\]])"#) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        }
        let subs: [(String, String)] = [
            (#"\bTrue\b"#, "true"),
            (#"\bFalse\b"#, "false"),
            (#"\bNone\b"#, "null")
        ]
        for (pattern, replacement) in subs {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: replacement)
            }
        }
        return s
    }

    private func extractReasoning(from text: String, extractedCount: Int) -> String {
        guard extractedCount > 0 else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for marker in Self.markers {
            if let range = text.range(of: marker) {
                let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty { return before }
            }
        }
        return "Executing tool calls..."
    }
}

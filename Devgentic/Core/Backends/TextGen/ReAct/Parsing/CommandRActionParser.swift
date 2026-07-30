//
//  CommandRActionParser.swift
//  Devgentic
//
//  Phase 5 — Native-tool dialect expansion (2026-04-22).
//  Primary parser for the `.commandRAction` dialect (Cohere Command-R / R+).
//
//  Canonical output: `Action:` markdown directive + fenced JSON list using
//  `tool_name` + `parameters` keys (unique Cohere key-naming combo).
//
//    Action: ```json
//    [
//        {"tool_name": "search", "parameters": {"q": "weather"}}
//    ]
//    ```
//
//  Drift tolerated:
//   - `name` alias for `tool_name` (cross-family flat-JSON drift)
//   - `arguments` alias for `parameters` (Qwen-style leakage)
//   - Missing or partial code fence
//   - Multiple Action: blocks (extract all)
//

import Foundation
import OSLog

private let logger = DGLogger(category: "CommandRActionParser")

struct CommandRActionParser: CognitiveParserProtocol {

    private struct ToolCallObject: Decodable {
        let tool_name: String?
        let name: String?
        let parameters: [String: JSONValue]?
        let arguments: [String: JSONValue]?

        var resolvedName: String? {
            if let n = tool_name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
            if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
            return nil
        }

        var resolvedArguments: [String: JSONValue] {
            parameters ?? arguments ?? [:]
        }
    }

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let calls = extractToolCalls(from: rawResponse)
        let reasoning = extractReasoning(from: rawResponse, extractedCount: calls.count)

        if !calls.isEmpty {
            logger.info("CommandRActionParser: Extracted \(calls.count) tool call(s): \(calls.map { $0.name }.joined(separator: ", "))")
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: calls)
        }

        logger.warning("CommandRActionParser: No Action: directive found. Treating as conversational exit.")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }

    // MARK: - Extraction

    /// Locates each `Action:` segment and extracts the JSON array inside its code fence
    /// (or bare array if no fence).
    private func extractToolCalls(from text: String) -> [PendingToolCall] {
        var results: [PendingToolCall] = []
        var searchStart = text.startIndex

        while let actionRange = text.range(of: "Action:", range: searchStart..<text.endIndex) {
            let afterAction = actionRange.upperBound

            // Prefer fenced JSON; fall back to bare balanced array.
            let slice = extractJSONArraySlice(from: String(text[afterAction...]))
            guard let arraySlice = slice else {
                searchStart = afterAction
                continue
            }

            if let decoded = decodeArray(arraySlice) {
                results.append(contentsOf: decoded.compactMap { toPendingCall($0) })
            }
            // Advance past what we consumed.
            searchStart = afterAction
        }

        return results
    }

    private func extractJSONArraySlice(from text: String) -> String? {
        // Try fenced ``` json ... ``` first.
        let fencePatterns = [
            #"```json\s*\n([\s\S]*?)\n\s*```"#,
            #"```\s*\n([\s\S]*?)\n\s*```"#
        ]
        for pattern in fencePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            if let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let bodyRange = Range(match.range(at: 1), in: text) {
                return String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Fallback: bare balanced `[...]`.
        guard let openIdx = text.firstIndex(of: "[") else { return nil }

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
                if depth == 0 { return String(text[openIdx...idx]) }
            }
        }
        return nil
    }

    private func toPendingCall(_ obj: ToolCallObject) -> PendingToolCall? {
        guard let resolvedName = obj.resolvedName else {
            logger.warning("CommandRActionParser: Object missing tool_name/name — skipping.")
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
            logger.info("CommandRActionParser: Decoded array after sanitization.")
            return decoded
        }
        logger.warning("CommandRActionParser: Failed to decode array: \(trimmed.prefix(200))")
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

    private func extractReasoning(from text: String, extractedCount: Int) -> String {
        guard extractedCount > 0 else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = text.range(of: "Action:") {
            let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ReasoningQualityFilter.filter(before)
        }
        return ""
    }
}

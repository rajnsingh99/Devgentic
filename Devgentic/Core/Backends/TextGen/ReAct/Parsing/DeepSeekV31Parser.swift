//
//  DeepSeekV31Parser.swift
//  Devgentic
//
//  Phase 5 — Native-tool dialect expansion (2026-04-22).
//  Primary parser for the `.deepseekV31Flat` dialect (DeepSeek-V3.1).
//
//  Canonical output: same full-width Unicode tokens as V3 but NO code fence —
//  args follow `<｜tool▁sep｜>` directly as bare JSON.
//
//    <｜tool▁calls▁begin｜><｜tool▁call▁begin｜>list_directory<｜tool▁sep｜>{"path":"/"}<｜tool▁call▁end｜><｜tool▁calls▁end｜>
//
//  Differences from V3 (DeepSeekV3Parser):
//   - V3 wraps args in ` ```json\n...\n``` ` code fence; V3.1 does not.
//   - V3 has optional `function` type prefix before name; V3.1 is flat.
//
//  Kept as a separate parser (not a mode flag on DeepSeekV3Parser) for clarity.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "DeepSeekV31Parser")

struct DeepSeekV31Parser: CognitiveParserProtocol {

    // Same full-width Unicode markers as V3.
    private static let callBeginMarker = "<\u{FF5C}tool\u{2581}call\u{2581}begin\u{FF5C}>"
    private static let callEndMarker   = "<\u{FF5C}tool\u{2581}call\u{2581}end\u{FF5C}>"
    private static let sepMarker       = "<\u{FF5C}tool\u{2581}sep\u{FF5C}>"

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let calls = extractToolCalls(from: rawResponse)
        let reasoning = extractReasoning(from: rawResponse, extractedCount: calls.count)

        if !calls.isEmpty {
            logger.info("DeepSeekV31Parser: Extracted \(calls.count) tool call(s): \(calls.map { $0.name }.joined(separator: ", "))")
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: calls)
        }

        logger.warning("DeepSeekV31Parser: No <｜tool▁call▁begin｜> blocks found. Treating as conversational exit.")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }

    // MARK: - Extraction

    private func extractToolCalls(from text: String) -> [PendingToolCall] {
        var results: [PendingToolCall] = []
        var searchStart = text.startIndex

        while let beginRange = text.range(of: Self.callBeginMarker, range: searchStart..<text.endIndex) {
            let blockStart = beginRange.upperBound
            let endRange = text.range(of: Self.callEndMarker, range: blockStart..<text.endIndex)
            let blockEnd = endRange?.lowerBound ?? text.endIndex
            let block = String(text[blockStart..<blockEnd])

            if let call = parseBlock(block) {
                results.append(call)
            }
            searchStart = endRange?.upperBound ?? blockEnd
        }

        return results
    }

    /// Structure: [optional type prefix] <｜tool▁sep｜>name{args_bare_json}
    private func parseBlock(_ block: String) -> PendingToolCall? {
        guard let sepRange = block.range(of: Self.sepMarker) else {
            logger.warning("DeepSeekV31Parser: Block has no <｜tool▁sep｜>.")
            return nil
        }
        let afterSep = String(block[sepRange.upperBound...])

        // Name is everything until the JSON opener `{` or newline.
        let name = extractNamePrefix(from: afterSep)
        guard !name.isEmpty else {
            logger.warning("DeepSeekV31Parser: Empty tool name.")
            return nil
        }

        // Args are the next balanced JSON object.
        guard let argsBody = extractBalancedJSONObject(from: afterSep) else {
            logger.warning("DeepSeekV31Parser: No JSON object after name.")
            return PendingToolCall(id: UUID().uuidString, name: name, arguments: [:])
        }
        let arguments = decodeArguments(from: argsBody) ?? [:]

        return PendingToolCall(id: UUID().uuidString, name: name, arguments: arguments)
    }

    private func extractNamePrefix(from text: String) -> String {
        let terminators: [Character] = ["\n", "\r", "{"]
        var end = text.startIndex
        for idx in text.indices {
            if terminators.contains(text[idx]) { break }
            end = text.index(after: idx)
        }
        return String(text[text.startIndex..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractBalancedJSONObject(from text: String) -> String? {
        guard let openIdx = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false

        for idx in text[openIdx...].indices {
            let c = text[idx]
            if escaped { escaped = false; continue }
            if c == "\\" && inString { escaped = true; continue }
            if c == "\"" { inString.toggle(); continue }
            if inString { continue }
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { return String(text[openIdx...idx]) }
            }
        }
        return nil
    }

    private func decodeArguments(from jsonString: String) -> [String: JSONValue]? {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }

        if let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            return decoded
        }
        let sanitized = sanitizeJSON(trimmed)
        if sanitized != trimmed,
           let data2 = sanitized.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data2) {
            logger.info("DeepSeekV31Parser: Decoded args after sanitization.")
            return decoded
        }
        logger.warning("DeepSeekV31Parser: Failed to decode args: \(trimmed.prefix(200))")
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
        if let range = text.range(of: Self.callBeginMarker) {
            let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ReasoningQualityFilter.filter(before)
        }
        return ""
    }
}

//
//  DeepSeekV3Parser.swift
//  Devgentic
//
//  Phase 4 — Native-tool dialect expansion (2026-04-22).
//  Primary parser for the `.deepseekV3JsonFence` dialect.
//
//  Covers:
//    - deepseek-ai/DeepSeek-V3
//    - deepseek-ai/DeepSeek-V3-0324
//    - deepseek-ai/DeepSeek-R1
//    - deepseek-ai/DeepSeek-R1-0528
//
//  NOTE: DeepSeek-R1-Distill-* variants (Llama-distilled, Qwen-distilled) do NOT
//  use this format — they inherit the host model family's template. Only pure
//  DeepSeek-V3 and DeepSeek-R1 check in through our fingerprinter for this dialect.
//
//  Canonical output uses full-width Unicode tokens (NOT ASCII):
//    - U+FF5C (｜) for pipes — fullwidth vertical bar
//    - U+2581 (▁) for the underscore in markers
//
//    <｜tool▁calls▁begin｜><｜tool▁call▁begin｜>function<｜tool▁sep｜>list_directory
//    ```json
//    {"path": "/tmp"}
//    ```<｜tool▁call▁end｜><｜tool▁calls▁end｜><｜end▁of▁sentence｜>
//
//  Drift tolerated:
//   - Multiple tool calls in one block (loop over begin/end pairs)
//   - Missing `<｜end▁of▁sentence｜>` suffix
//   - Args inside ` ```json ... ``` ` code fence OR bare JSON without fence
//   - Python literals in args (True/False/None → true/false/null)
//

import Foundation
import OSLog

private let logger = DGLogger(category: "DeepSeekV3Parser")

struct DeepSeekV3Parser: CognitiveParserProtocol {

    // Full-width Unicode markers from DeepSeek's tokenizer.
    // These are explicit Swift string literals using the distinctive code points:
    //   \u{FF5C} = ｜ (FULLWIDTH VERTICAL LINE)
    //   \u{2581} = ▁ (LOWER ONE EIGHTH BLOCK / used as underscore in the tokenizer)
    private static let callBeginMarker = "<\u{FF5C}tool\u{2581}call\u{2581}begin\u{FF5C}>"
    private static let callEndMarker   = "<\u{FF5C}tool\u{2581}call\u{2581}end\u{FF5C}>"
    private static let sepMarker       = "<\u{FF5C}tool\u{2581}sep\u{FF5C}>"
    // `<｜tool▁calls▁begin｜>` / `<｜tool▁calls▁end｜>` wrap the whole section;
    // we don't need the outer markers for parsing — the inner begin/end pairs are
    // sufficient to extract each call.

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let calls = extractToolCalls(from: rawResponse)
        let reasoning = extractReasoning(from: rawResponse, extractedCount: calls.count)

        if !calls.isEmpty {
            logger.info("DeepSeekV3Parser: Extracted \(calls.count) tool call(s): \(calls.map { $0.name }.joined(separator: ", "))")
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: calls)
        }

        logger.warning("DeepSeekV3Parser: No <｜tool▁call▁begin｜> markers found. Treating as conversational exit.")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }

    // MARK: - Extraction

    /// Finds each `<｜tool▁call▁begin｜>...<｜tool▁call▁end｜>` block and extracts
    /// name (after `<｜tool▁sep｜>`) + JSON args (from code fence or bare JSON).
    private func extractToolCalls(from text: String) -> [PendingToolCall] {
        var results: [PendingToolCall] = []
        var searchStart = text.startIndex

        while let beginRange = text.range(of: Self.callBeginMarker, range: searchStart..<text.endIndex) {
            // Locate the matching call end marker; if missing, use end-of-string.
            let blockStart = beginRange.upperBound
            let endRange = text.range(of: Self.callEndMarker, range: blockStart..<text.endIndex)
            let blockEnd = endRange?.lowerBound ?? text.endIndex
            let block = String(text[blockStart..<blockEnd])

            if let call = parseBlock(block) {
                results.append(call)
            } else {
                logger.warning("DeepSeekV3Parser: Block failed to yield call: \(block.prefix(150))")
            }

            searchStart = endRange?.upperBound ?? blockEnd
        }

        return results
    }

    /// Parses one tool-call block (content between begin/end markers).
    /// Structure: [optional type prefix (e.g. "function")] <｜tool▁sep｜> name \n ```json\n{args}\n``` [or bare JSON]
    private func parseBlock(_ block: String) -> PendingToolCall? {
        // Locate the sep marker; name is everything between sep and the first newline (or JSON opener).
        guard let sepRange = block.range(of: Self.sepMarker) else {
            logger.warning("DeepSeekV3Parser: Block has no <｜tool▁sep｜>.")
            return nil
        }
        let afterSep = block[sepRange.upperBound...]

        // Extract name — run until we hit a code fence, bare `{`, or newline.
        let name = extractNamePrefix(from: String(afterSep))
        guard !name.isEmpty else {
            logger.warning("DeepSeekV3Parser: Empty tool name.")
            return nil
        }

        // Extract JSON args — prefer code-fenced `\`\`\`json\n...\n\`\`\`` payload,
        // fall back to bare `{...}` balanced object.
        let argsText = extractArgsJSON(from: String(afterSep))
        let arguments = decodeArguments(from: argsText) ?? [:]

        return PendingToolCall(id: UUID().uuidString, name: name, arguments: arguments)
    }

    /// Name is the token between sep marker and the next newline / fence / brace.
    private func extractNamePrefix(from text: String) -> String {
        let terminators: [Character] = ["\n", "\r", "{", "`"]
        var end = text.startIndex
        for idx in text.indices {
            if terminators.contains(text[idx]) { break }
            end = text.index(after: idx)
        }
        return String(text[text.startIndex..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract the JSON args string. Priority: code-fenced body → bare JSON object.
    private func extractArgsJSON(from text: String) -> String {
        if let fenced = extractFencedJSON(from: text) {
            return fenced
        }
        if let bare = extractBalancedJSONObject(from: text) {
            return bare
        }
        return ""
    }

    /// Matches ` ```json\n{...}\n``` ` (or without the `json` language tag).
    private func extractFencedJSON(from text: String) -> String? {
        // Accept `\`\`\`json\n...\n\`\`\`` or `\`\`\`\n...\n\`\`\``.
        let patterns = [
            #"```json\s*\n([\s\S]*?)\n\s*```"#,
            #"```\s*\n([\s\S]*?)\n\s*```"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let bodyRange = Range(match.range(at: 1), in: text) {
                return String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// Balanced-brace extraction for bare JSON object fallback.
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
                if depth == 0 {
                    return String(text[openIdx...idx])
                }
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
            logger.info("DeepSeekV3Parser: Decoded args after sanitization.")
            return decoded
        }
        logger.warning("DeepSeekV3Parser: Failed to decode args JSON: \(trimmed.prefix(200))")
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

    /// Prose text before the first tool-call-begin marker.
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

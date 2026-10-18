// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DeepSeekV3Parser.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "DeepSeekV3Parser")

/// Primary parser for the `.deepseekV3JsonFence` dialect (DeepSeek-V3 and DeepSeek-R1; the R1-Distill
/// variants use their host family's template). Reads full-width-token tool-call blocks with JSON arguments in
/// a code fence or bare, tolerating multiple calls, a missing end-of-sentence suffix and Python literals.
struct DeepSeekV3Parser: CognitiveParserProtocol {

    // Full-width Unicode markers from DeepSeek's tokenizer, written as explicit code points: U+FF5C (｜) for
    // pipes and U+2581 (▁) for the underscore.
    private static let callBeginMarker = "<\u{FF5C}tool\u{2581}call\u{2581}begin\u{FF5C}>"
    private static let callEndMarker   = "<\u{FF5C}tool\u{2581}call\u{2581}end\u{FF5C}>"
    private static let sepMarker       = "<\u{FF5C}tool\u{2581}sep\u{FF5C}>"
    // The outer `tool▁calls▁begin/end` markers are not needed for parsing; the inner begin/end pairs suffice to
    // extract each call.

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
                logger.warning("DeepSeekV3Parser: Block failed to yield call: \(block.count) chars (snippet at debug: model output is content, CR-57)")
                logger.debug("DeepSeekV3Parser: snippet: \(block.prefix(150))")
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
        BalancedJSONScanner.firstObject(in: text).map(String.init)
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
        logger.warning("DeepSeekV3Parser: Failed to decode args JSON: \(trimmed.count) chars (snippet at debug: model output is content, CR-57)")
        logger.debug("DeepSeekV3Parser: snippet: \(trimmed.prefix(200))")
        return nil
    }

    // Why: whole-payload regexes also rewrote file content in `write_file` arguments (real trailing commas,
    // `Double.NaN`); see `JSONStructuralSanitizer`
    /// Repairs trailing commas and Python literals in the model's JSON, delegating to the shared sanitizer so the
    /// repair happens outside string values only.
    private func sanitizeJSON(_ raw: String) -> String {
        JSONStructuralSanitizer.repairingStructure(raw)
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

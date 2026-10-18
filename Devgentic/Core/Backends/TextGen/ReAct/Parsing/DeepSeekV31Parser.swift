// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DeepSeekV31Parser.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "DeepSeekV31Parser")

/// Parser for the `.deepseekV31Flat` dialect (DeepSeek-V3.1) tool calls.
/// Arguments follow `<｜tool▁sep｜>` as bare JSON, with no code fence and no `function` type prefix (unlike V3).
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
            logger.info("DeepSeekV31Parser: Decoded args after sanitization.")
            return decoded
        }
        logger.warning("DeepSeekV31Parser: Failed to decode args: \(trimmed.count) chars (snippet at debug: model output is content, CR-57)")
        logger.debug("DeepSeekV31Parser: snippet: \(trimmed.prefix(200))")
        return nil
    }

    // Why: whole-payload regexes also rewrite file content carried in `write_file` arguments.
    /// Repairs trailing commas and Python literals in the model's JSON.
    /// Delegates to the shared sanitizer, which repairs outside string values only.
    private func sanitizeJSON(_ raw: String) -> String {
        JSONStructuralSanitizer.repairingStructure(raw)
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

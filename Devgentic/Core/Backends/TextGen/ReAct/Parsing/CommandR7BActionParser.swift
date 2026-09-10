// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  CommandR7BActionParser.swift
//  Devgentic
//
//  Phase 5 — Native-tool dialect expansion (2026-04-22).
//  Primary parser for the `.commandR7BAction` dialect (Cohere Command-R7B, Command-A).
//
//  Canonical output: token-delimited JSON array with an explicit `tool_call_id` field.
//
//    <|START_OF_TURN_TOKEN|><|CHATBOT_TOKEN|><|START_THINKING|>plan...<|END_THINKING|>
//    <|START_ACTION|>[
//        {"tool_call_id": "0", "tool_name": "search", "parameters": {"q": "x"}}
//    ]<|END_ACTION|><|END_OF_TURN_TOKEN|>
//
//  Drift tolerated:
//   - Missing `<|END_ACTION|>` (balance brackets to find array end)
//   - Missing `tool_call_id` (we don't require it anyway — if present we preserve it)
//   - `name` alias for `tool_name`, `arguments` alias for `parameters`
//   - Python literals in args
//

import Foundation
import OSLog

private let logger = DGLogger(category: "CommandR7BActionParser")

struct CommandR7BActionParser: CognitiveParserProtocol {

    private struct ToolCallObject: Decodable {
        let tool_call_id: String?
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

    private static let actionBegin = "<|START_ACTION|>"
    private static let actionEnd = "<|END_ACTION|>"

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let calls = extractToolCalls(from: rawResponse)
        let reasoning = extractReasoning(from: rawResponse, extractedCount: calls.count)

        if !calls.isEmpty {
            logger.info("CommandR7BActionParser: Extracted \(calls.count) tool call(s): \(calls.map { $0.name }.joined(separator: ", "))")
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: calls)
        }

        logger.warning("CommandR7BActionParser: No <|START_ACTION|> found. Treating as conversational exit.")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }

    // MARK: - Extraction

    private func extractToolCalls(from text: String) -> [PendingToolCall] {
        guard let startRange = text.range(of: Self.actionBegin) else { return [] }
        let afterStart = startRange.upperBound

        // Delimit by <|END_ACTION|> if present; otherwise take the rest of the text.
        let endIndex = text.range(of: Self.actionEnd, range: afterStart..<text.endIndex)?.lowerBound ?? text.endIndex
        let body = String(text[afterStart..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract balanced JSON array from body.
        guard let arraySlice = extractBalancedArray(body) else {
            logger.warning("CommandR7BActionParser: Failed to locate JSON array inside START_ACTION body.")
            return []
        }

        guard let decoded = decodeArray(arraySlice) else { return [] }
        return decoded.compactMap { toPendingCall($0) }
    }

    private func extractBalancedArray(_ text: String) -> String? {
        BalancedJSONScanner.firstArray(in: text).map(String.init)
    }

    private func toPendingCall(_ obj: ToolCallObject) -> PendingToolCall? {
        guard let resolvedName = obj.resolvedName else {
            logger.warning("CommandR7BActionParser: Object missing tool_name — skipping.")
            return nil
        }
        return PendingToolCall(
            id: obj.tool_call_id ?? UUID().uuidString,
            name: resolvedName,
            arguments: obj.resolvedArguments
        )
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
            logger.info("CommandR7BActionParser: Decoded array after sanitization.")
            return decoded
        }
        logger.warning("CommandR7BActionParser: Failed to decode array: \(trimmed.prefix(200))")
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
        // Cohere R7B often includes <|START_THINKING|>...<|END_THINKING|> before action.
        if let start = text.range(of: "<|START_THINKING|>"),
           let end = text.range(of: "<|END_THINKING|>"),
           start.upperBound < end.lowerBound {
            let thinking = String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let filtered = ReasoningQualityFilter.filter(thinking)
            if !filtered.isEmpty { return filtered }
        }
        // Fallback: prose before <|START_ACTION|>.
        if let range = text.range(of: Self.actionBegin) {
            let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let filtered = ReasoningQualityFilter.filter(before)
            if !filtered.isEmpty { return filtered }
        }
        return ""
    }
}

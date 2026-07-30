//
//  MistralV3Parser.swift
//  Devgentic
//
//  Phase 3 — Native-tool dialect expansion (2026-04-22).
//  Primary parser for the `.mistralV3Array` dialect — older Mistral Tekken tokenizer family.
//
//  Covers:
//    - mistralai/Mistral-7B-Instruct-v0.3
//    - mistralai/Mistral-Nemo-Instruct-2407
//    - mistralai/Mixtral-8x22B-Instruct
//    - mistralai/Mistral-Small-Instruct-2409 (pre-3.1)
//    - mistralai/Ministral-8B-Instruct-2410
//    - mistralai/Pixtral-Large-Instruct-2411
//    - Older Devstral variants
//
//  Canonical output (parallel calls = all objects in one array):
//
//    [TOOL_CALLS] [{"name": "list_directory", "arguments": {"path": "/"}, "id": "abc123xyz"}]</s>
//
//  Drift tolerated:
//   - Missing `</s>` suffix
//   - Multiple `[TOOL_CALLS]` markers on separate lines (segment and parse each array)
//   - Missing `id` field (optional; ignored when present)
//   - Whitespace between `[TOOL_CALLS]` and `[`
//   - `parameters` as alias for `arguments` (cross-family key leakage)
//

import Foundation
import OSLog

private let logger = DGLogger(category: "MistralV3Parser")

struct MistralV3Parser: CognitiveParserProtocol {

    /// Mistral v3 tool call object. `id` is template-enforced but we ignore it.
    /// - `name` canonical; `tool_name` accepted as alias (cross-family flat-JSON drift).
    /// - `arguments` canonical; `parameters` accepted as alias (Llama-style leakage).
    private struct ToolCallObject: Decodable {
        let name: String?
        let tool_name: String?
        let arguments: [String: JSONValue]?
        let parameters: [String: JSONValue]?
        let id: String?

        var resolvedName: String? {
            if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
            if let n = tool_name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
            return nil
        }

        var resolvedArguments: [String: JSONValue] {
            arguments ?? parameters ?? [:]
        }
    }

    private static let marker = "[TOOL_CALLS]"

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let calls = extractToolCalls(from: rawResponse)
        let reasoning = extractReasoning(from: rawResponse, extractedCount: calls.count)

        if !calls.isEmpty {
            logger.info("MistralV3Parser: Extracted \(calls.count) tool call(s): \(calls.map { $0.name }.joined(separator: ", "))")
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: calls)
        }

        logger.warning("MistralV3Parser: No [TOOL_CALLS] array found. Treating as conversational exit.")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }

    // MARK: - Extraction

    /// Splits on `[TOOL_CALLS]` markers (drops the prose before the first) and parses
    /// a balanced JSON array after each marker. Handles both single and multiple markers.
    private func extractToolCalls(from text: String) -> [PendingToolCall] {
        var results: [PendingToolCall] = []
        let segments = text.components(separatedBy: Self.marker).dropFirst()

        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let arrayRange = balancedJSONArrayRange(in: trimmed, startingAt: trimmed.startIndex) else {
                logger.warning("MistralV3Parser: Failed to locate balanced JSON array after marker.")
                continue
            }
            let arraySlice = String(trimmed[arrayRange])
            guard let data = arraySlice.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([ToolCallObject].self, from: data) else {
                // Retry after sanitization
                let sanitized = sanitizeJSON(arraySlice)
                if sanitized != arraySlice,
                   let data2 = sanitized.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode([ToolCallObject].self, from: data2) {
                    logger.info("MistralV3Parser: Decoded array after sanitization.")
                    results.append(contentsOf: decoded.compactMap { toPendingCall($0) })
                    continue
                }
                logger.warning("MistralV3Parser: Failed to decode JSON array: \(arraySlice.prefix(200))")
                continue
            }
            results.append(contentsOf: decoded.compactMap { toPendingCall($0) })
        }

        return results
    }

    private func toPendingCall(_ obj: ToolCallObject) -> PendingToolCall? {
        guard let resolvedName = obj.resolvedName else {
            logger.warning("MistralV3Parser: Decoded object has no `name` or `tool_name` — skipping.")
            return nil
        }
        return PendingToolCall(
            id: obj.id ?? UUID().uuidString,
            name: resolvedName,
            arguments: obj.resolvedArguments
        )
    }

    /// Finds first balanced `[...]` JSON array starting at or after `startingAt`,
    /// tracking string state so brackets inside quoted strings don't affect depth.
    private func balancedJSONArrayRange(in text: String, startingAt: String.Index) -> Range<String.Index>? {
        BalancedJSONScanner.balancedRange(in: text, from: startingAt, opener: "[")
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

    /// Prose text before the first `[TOOL_CALLS]` marker.
    private func extractReasoning(from text: String, extractedCount: Int) -> String {
        guard extractedCount > 0 else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = text.range(of: Self.marker) {
            let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ReasoningQualityFilter.filter(before)
        }
        return ""
    }
}

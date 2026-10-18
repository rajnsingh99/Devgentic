// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FrameworkToolCallEnvelope.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "FrameworkToolCallEnvelope")

/// How a tool call that MLXLMCommon already decoded travels through the text stream to the parse pipeline.
/// A declared grammar of exact tags with one JSON payload per call, decoded once at the top of `CognitiveParsePipeline`.
/// The tags are unambiguous, not a security boundary.
enum FrameworkToolCallEnvelope {

    static let openTag = "<devgentic:framework_tool_call>"
    static let closeTag = "</devgentic:framework_tool_call>"

    /// Written instead of output when the framework generated tokens and passed none of them on, meaning the model wrote
    /// a call the runtime could not read. A fallback: the framework normally reports such a call as `.rejectedToolCall`.
    static let discardedPrefix = "<devgentic:framework_discarded_tool_call tokens=\""
    static let discardedSuffix = "\"/>"

    static func discardedMarker(generatedTokens: Int) -> String {
        discardedPrefix + String(generatedTokens) + discardedSuffix
    }

    private struct Payload: Codable {
        let name: String
        let arguments: [String: JSONValue]
    }

    /// One call as the stream carries it. Sorted keys, so identical calls are byte-identical — the
    /// identical-output loop detector and the log compare these strings.
    static func encode(name: String, arguments: [String: Any]) -> String? {
        let payload: [String: Any] = ["name": name, "arguments": arguments]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return nil }
        return openTag + String(decoding: data, as: UTF8.self) + closeTag
    }

    struct Extraction {
        /// Every decodable call, in stream order.
        let calls: [PendingToolCall]
        /// The text with every envelope removed — the model's own prose around the calls.
        let remainder: String
        /// Envelopes whose payload did not decode. Only an app bug can produce one.
        let undecodable: Int
        /// Tokens of a call the framework generated and discarded, when the stream reported one.
        let discardedTokens: Int?
    }

    /// Nil when the text carries no envelope, so callers fall through to dialect parsing unchanged.
    static func extract(from text: String) -> Extraction? {
        var text = text
        var discardedTokens: Int?
        if let start = text.range(of: discardedPrefix),
           let end = text.range(of: discardedSuffix, range: start.upperBound..<text.endIndex) {
            discardedTokens = Int(text[start.upperBound..<end.lowerBound])
            text.removeSubrange(start.lowerBound..<end.upperBound)
            if !text.contains(openTag) {
                return Extraction(calls: [], remainder: text, undecodable: 0, discardedTokens: discardedTokens ?? 0)
            }
        }
        guard text.contains(openTag) else { return nil }

        var calls: [PendingToolCall] = []
        var remainder = ""
        var undecodable = 0
        var cursor = text.startIndex

        while let open = text.range(of: openTag, range: cursor..<text.endIndex) {
            remainder += text[cursor..<open.lowerBound]
            guard let close = text.range(of: closeTag, range: open.upperBound..<text.endIndex) else {
                // Unclosed: keep the rest as text rather than guessing where the payload ends.
                remainder += text[open.lowerBound...]
                undecodable += 1
                cursor = text.endIndex
                break
            }
            let body = Data(text[open.upperBound..<close.lowerBound].utf8)
            if let payload = try? JSONDecoder().decode(Payload.self, from: body) {
                calls.append(PendingToolCall(id: UUID().uuidString, name: payload.name, arguments: payload.arguments))
            } else {
                undecodable += 1
            }
            cursor = close.upperBound
        }
        remainder += text[cursor...]

        if undecodable > 0 {
            logger.error("[MLX-TOOLCALL] \(undecodable) framework tool-call envelope(s) did not decode (\(calls.count) did). CONSEQUENCE: those calls are not run; the envelope text is the app's own serialization, so this is an encode/decode mismatch, not model output.")
        }
        return Extraction(calls: calls, remainder: remainder, undecodable: undecodable, discardedTokens: discardedTokens)
    }
}

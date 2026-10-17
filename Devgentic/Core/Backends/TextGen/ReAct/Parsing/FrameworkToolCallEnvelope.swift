// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FrameworkToolCallEnvelope.swift
//  Devgentic
//
//  How a tool call that MLXLMCommon ALREADY decoded travels through the text stream to the parse
//  pipeline — the one definition both ends use.
//
//  WHY IT EXISTS (device run 2026-10-06). mlx-swift-lm parses tool calls itself (`ToolCallProcessor`,
//  9 formats, always on) and emits them as structured `.toolCall` events. `MLXService` used to turn
//  each one back into a bare JSON object — `{"arguments":…,"content":"Executing tool X...",
//  "tool_name":"X"}` — appended to the text with no wrapper, and every dialect parser then had to
//  rediscover it by shape. Their bare-JSON fallbacks take the FIRST object only: a turn where the
//  framework reported `toolCalls=3` ran ONE call (`b.py` was never read), and the prose before the
//  calls was dropped as "no reasoning" because there was no `<tool_call>` tag to split on.
//
//  The envelope is a declared grammar, not a shape: exact tags the app writes, one JSON payload per
//  call, decoded once at the top of `CognitiveParsePipeline` before any dialect parser runs. A model
//  that wrote these tags itself would get its call run — the same as writing any call — so the tags
//  are not a security boundary, only an unambiguous one.
//

import Foundation

private let logger = DGLogger(category: "FrameworkToolCallEnvelope")

enum FrameworkToolCallEnvelope {

    static let openTag = "<devgentic:framework_tool_call>"
    static let closeTag = "</devgentic:framework_tool_call>"

    /// Written INSTEAD of output when the framework generated tokens and passed none of them on.
    /// The only thing in the stream that withholds text is `ToolCallProcessor`, which buffers from
    /// the call opener and drops the buffer when the call fails to decode — so this is a call the
    /// model wrote and the runtime could not read. Measured 2026-10-06: the same 76 tokens were
    /// discarded on all three blind retries of a byte-identical prompt; only telling the model
    /// changes the next attempt.
    ///
    /// ⚠️ NOW A FALLBACK. From mlx-swift-lm 3.32 the framework reports such a call as
    /// `.rejectedToolCall` with its raw text, which `MLXService` forwards as ordinary output for the
    /// dialect parsers to repair or correct specifically. This marker fires only if tokens still
    /// vanish with no rejection reported, i.e. a framework regression.
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

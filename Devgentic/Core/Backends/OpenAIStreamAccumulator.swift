// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OpenAIStreamAccumulator.swift
//  Devgentic
//
//  Reassembles a streamed `chat/completions` response (OpenAI, OpenRouter, OpenAI-compatible) into
//  the single assistant message the non-streaming API would have returned, so both paths parse it
//  with the same `OpenAILLMProvider.step(fromMessage:usage:)`.
//
//  Streamed shape, per chunk: `choices[0].delta` carries fragments —
//    content            String, appended
//    reasoning /
//    reasoning_content  String, appended (OpenRouter / DeepSeek names for the thinking trace)
//    tool_calls         [{index, id?, type?, function: {name?, arguments?}}] — fragments of each call,
//                       keyed by `index`; `arguments` arrives as a JSON string split across chunks
//    reasoning_details  [{index?, type, text?/summary?/data?, ...}] — OpenRouter, merged by `index`
//  plus `finish_reason` on the last content chunk and, with `stream_options.include_usage`, a final
//  chunk whose `usage` is set (and `choices` empty).
//
//  Pure value type: no I/O, fully unit-testable from recorded chunks.
//

import Foundation

struct OpenAIStreamAccumulator {

    private(set) var content = ""
    private(set) var reasoning = ""
    private(set) var finishReason: String?

    /// The chunk that carried `usage`, with the response metadata (`id`, `provider`, `model`) from
    /// earlier chunks folded in — the input `logRouterMetadata` and `TokenUsage.fromOpenAI` expect.
    private(set) var lastUsageChunk: [String: Any]?

    private var toolCalls: [Int: ToolCallParts] = [:]
    private var reasoningDetails: [[String: Any]] = []
    private var metadata: [String: Any] = [:]

    private struct ToolCallParts {
        var id: String?
        var type: String?
        var name = ""
        var arguments = ""
    }

    /// Folds one parsed chunk in. Returns the visible-text delta it carried (nil when none).
    mutating func consume(_ chunk: [String: Any]) -> String? {
        for key in ["id", "provider", "model"] where metadata[key] == nil {
            if let value = chunk[key] { metadata[key] = value }
        }
        if chunk["usage"] is [String: Any] {
            lastUsageChunk = chunk.merging(metadata) { current, _ in current }
        }

        guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { return nil }
        if let reason = choice["finish_reason"] as? String { finishReason = reason }
        guard let delta = choice["delta"] as? [String: Any] else { return nil }

        for key in ["reasoning", "reasoning_content"] {
            if let text = delta[key] as? String { reasoning += text }
        }
        if let calls = delta["tool_calls"] as? [[String: Any]] {
            for call in calls { mergeToolCall(call) }
        }
        if let details = delta["reasoning_details"] as? [[String: Any]] {
            for detail in details { mergeReasoningDetail(detail) }
        }

        guard let text = delta["content"] as? String, !text.isEmpty else { return nil }
        content += text
        return text
    }

    /// The reassembled assistant message, in the non-streaming `choices[0].message` shape.
    var message: [String: Any] {
        var msg: [String: Any] = ["role": "assistant", "content": content]
        if !reasoning.isEmpty { msg["reasoning"] = reasoning }
        if !toolCalls.isEmpty {
            msg["tool_calls"] = toolCalls.keys.sorted().compactMap { index -> [String: Any]? in
                guard let parts = toolCalls[index], !parts.name.isEmpty else { return nil }
                var call: [String: Any] = [
                    "type": parts.type ?? "function",
                    "function": ["name": parts.name, "arguments": parts.arguments],
                ]
                if let id = parts.id { call["id"] = id }
                return call
            }
        }
        if !reasoningDetails.isEmpty { msg["reasoning_details"] = reasoningDetails }
        return msg
    }

    // MARK: - Merging

    private mutating func mergeToolCall(_ call: [String: Any]) {
        // `index` is the stable key across fragments. A provider that omits it sends each call
        // whole in one chunk, so a fresh slot per call is correct there.
        let index = (call["index"] as? Int) ?? (toolCalls.keys.max().map { $0 + 1 } ?? 0)
        var parts = toolCalls[index] ?? ToolCallParts()
        if let id = call["id"] as? String, !id.isEmpty { parts.id = id }
        if let type = call["type"] as? String { parts.type = type }
        if let function = call["function"] as? [String: Any] {
            if let name = function["name"] as? String { parts.name += name }
            if let args = function["arguments"] as? String { parts.arguments += args }
        }
        toolCalls[index] = parts
    }

    /// Fragments of one detail share an `index`; their text-bearing fields are concatenated and any
    /// other field (type, id, format, signature) is taken from the first fragment that carries it.
    private mutating func mergeReasoningDetail(_ detail: [String: Any]) {
        guard let index = detail["index"] as? Int,
              let existing = reasoningDetails.firstIndex(where: { ($0["index"] as? Int) == index }) else {
            reasoningDetails.append(detail)
            return
        }
        var merged = reasoningDetails[existing]
        for (key, value) in detail {
            if ["text", "summary", "data"].contains(key), let fragment = value as? String {
                merged[key] = ((merged[key] as? String) ?? "") + fragment
            } else if merged[key] == nil || merged[key] is NSNull {
                merged[key] = value
            }
        }
        reasoningDetails[existing] = merged
    }
}

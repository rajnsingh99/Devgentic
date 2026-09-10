// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  OllamaToolTurnAdapter.swift
//  Devgentic
//
//  Native-turn serializer for Ollama's /api/chat endpoint. Ollama mirrors
//  OpenAI's tool-calling shape closely but accepts arguments as a dict
//  (not a stringified JSON blob) — matches what our receive-side parser
//  in OllamaLLMProvider emits.
//

import Foundation

struct OllamaToolTurnAdapter: ToolTurnAdapter {

    func assistantTurn(toolCalls: [PendingToolCall], reasoning: String?) -> [String: Any] {
        let calls: [[String: Any]] = toolCalls.map { call in
            [
                "id": call.id,
                "type": "function",
                "function": [
                    "name": call.name,
                    "arguments": argumentsToDict(call.arguments)
                ]
            ]
        }
        // Ollama requires `content` to be a string (not null) even when tool_calls
        // are present; empty string is the canonical "no reasoning" value.
        return [
            "role": "assistant",
            "content": reasoning ?? "",
            "tool_calls": calls
        ]
    }

    func toolResultTurns(observations: [ToolObservation]) -> [[String: Any]] {
        observations.map { obs in
            [
                "role": "tool",
                "tool_call_id": obs.toolCallId,
                "content": obs.result
            ]
        }
    }

    /// Kickoff user turn. Text-only → plain string content (byte-identical to the
    /// default `normalizeCanonical`, so text runs and their KV-cache prefix are
    /// unchanged). With images → Ollama's per-message `images` array of RAW base64
    /// strings (NO `data:` prefix, per /api/chat). The vision model's processor /
    /// chat template inserts the image tokens server-side, so we never hand-place
    /// placeholders. Flows straight through `buildCognitiveBody` into the request.
    func userTurn(text: String, images: [ResolvedImage]) -> [String: Any] {
        guard !images.isEmpty else {
            return ["role": "user", "content": text]
        }
        return [
            "role": "user",
            "content": text,
            "images": images.map { $0.base64 }
        ]
    }

    private func argumentsToDict(_ args: [String: JSONValue]) -> [String: Any] {
        args.mapValues { $0.rawValue }
    }
}

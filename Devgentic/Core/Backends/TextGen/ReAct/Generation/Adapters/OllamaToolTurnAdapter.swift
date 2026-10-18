// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OllamaToolTurnAdapter.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Native-turn serializer for Ollama's /api/chat endpoint. The tool-calling shape mirrors OpenAI's, but arguments are a
/// dict rather than a stringified JSON blob, matching what the receive-side parser in `OllamaLLMProvider` emits.
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

    /// Kickoff user turn. Text-only gives plain string content (byte-identical to `normalizeCanonical`, so KV-cache holds).
    /// With images, uses Ollama's per-message `images` array of raw base64 strings (no `data:` prefix).
    /// The server inserts image tokens; flows straight through `buildCognitiveBody` into the request.
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

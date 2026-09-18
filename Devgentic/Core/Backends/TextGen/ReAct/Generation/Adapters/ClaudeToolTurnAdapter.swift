// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ClaudeToolTurnAdapter.swift
//  Devgentic
//
//  Native-turn serializer for Anthropic's Messages API. Claude uses a
//  content-block array on every message rather than top-level tool_calls:
//    assistant turn → [{type: text}, {type: tool_use, ...}, ...]
//    tool results   → user message with [{type: tool_result, ...}, ...]
//

import Foundation

struct ClaudeToolTurnAdapter: ToolTurnAdapter {

    func assistantTurn(toolCalls: [PendingToolCall], reasoning: String?) -> [String: Any] {
        var blocks: [[String: Any]] = []

        // Reasoning precedes tool_use blocks so the model's monologue is
        // preserved in-stream with its tool calls.
        if let reasoning = reasoning, !reasoning.isEmpty {
            blocks.append([
                "type": "text",
                "text": reasoning
            ])
        }

        for call in toolCalls {
            blocks.append([
                "type": "tool_use",
                "id": call.id,
                "name": call.name,
                "input": argumentsToDict(call.arguments)
            ])
        }

        return [
            "role": "assistant",
            "content": blocks
        ]
    }

    func toolResultTurns(observations: [ToolObservation]) -> [[String: Any]] {
        // Claude requires all tool_result blocks for a given assistant turn to
        // live inside ONE user message, not separate messages per result.
        let blocks: [[String: Any]] = observations.map { obs in
            var block: [String: Any] = [
                "type": "tool_result",
                "tool_use_id": obs.toolCallId,
                "content": obs.result
            ]
            // Structural error signal — lets Claude distinguish failures without
            // string-matching on the content.
            if !obs.isSuccess {
                block["is_error"] = true
            }
            return block
        }
        return [[
            "role": "user",
            "content": blocks
        ]]
    }

    /// Kickoff user turn. Text-only → plain string content (byte-identical to the
    /// default normalizeCanonical). With images → an Anthropic content-block array
    /// mixing text and base64 image source blocks.
    func userTurn(text: String, images: [ResolvedImage]) -> [String: Any] {
        guard !images.isEmpty else {
            return ["role": "user", "content": text]
        }
        var blocks: [[String: Any]] = []
        if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
        for img in images {
            blocks.append([
                "type": "image",
                "source": ["type": "base64", "media_type": img.mimeType, "data": img.base64]
            ])
        }
        return ["role": "user", "content": blocks]
    }

    private func argumentsToDict(_ args: [String: JSONValue]) -> [String: Any] {
        args.mapValues { $0.rawValue }
    }
}

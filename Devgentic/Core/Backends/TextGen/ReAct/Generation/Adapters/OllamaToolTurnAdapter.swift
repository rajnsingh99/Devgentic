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

    private func argumentsToDict(_ args: [String: JSONValue]) -> [String: Any] {
        args.mapValues { $0.rawValue }
    }
}

//
//  OpenAIToolTurnAdapter.swift
//  Devgentic
//
//  Native-turn serializer for OpenAI's Chat Completions API.
//  Differs from Ollama's shape in one place: OpenAI requires `arguments`
//  to be a stringified JSON blob (not a dict), per the API spec.
//

import Foundation

struct OpenAIToolTurnAdapter: ToolTurnAdapter {

    func assistantTurn(toolCalls: [PendingToolCall], reasoning: String?) -> [String: Any] {
        let calls: [[String: Any]] = toolCalls.map { call in
            [
                "id": call.id,
                "type": "function",
                "function": [
                    "name": call.name,
                    "arguments": serializeArguments(call.arguments)
                ]
            ]
        }
        var msg: [String: Any] = [
            "role": "assistant",
            "tool_calls": calls
        ]
        // OpenAI spec: `content` is null when only tool_calls are emitted;
        // populated when the model also emits text alongside them.
        if let reasoning = reasoning, !reasoning.isEmpty {
            msg["content"] = reasoning
        } else {
            msg["content"] = NSNull()
        }
        return msg
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
    /// default normalizeCanonical). With images → an OpenAI content array mixing
    /// text and `image_url` data-URL blocks.
    func userTurn(text: String, images: [ResolvedImage]) -> [String: Any] {
        guard !images.isEmpty else {
            return ["role": "user", "content": text]
        }
        var content: [[String: Any]] = []
        if !text.isEmpty { content.append(["type": "text", "text": text]) }
        for img in images {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:\(img.mimeType);base64,\(img.base64)"]
            ])
        }
        return ["role": "user", "content": content]
    }

    private func serializeArguments(_ args: [String: JSONValue]) -> String {
        let rawDict = args.mapValues { $0.rawValue }
        guard let data = try? JSONSerialization.data(withJSONObject: rawDict),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

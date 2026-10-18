// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GeminiToolTurnAdapter.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Native-turn serializer for Google Gemini's generateContent API. Differs from OpenAI-family shapes: the assistant
/// role is "model", content lives in `parts`, tool calls are `functionCall` parts and results are `functionResponse`
/// parts.
struct GeminiToolTurnAdapter: ToolTurnAdapter {

    func assistantTurn(toolCalls: [PendingToolCall], reasoning: String?) -> [String: Any] {
        var parts: [[String: Any]] = []

        if let reasoning = reasoning, !reasoning.isEmpty {
            parts.append(["text": reasoning])
        }

        for call in toolCalls {
            parts.append([
                "functionCall": [
                    "name": call.name,
                    "args": argumentsToDict(call.arguments)
                ]
            ])
        }

        return [
            "role": "model",
            "parts": parts
        ]
    }

    /// Each function-call part gets back the `thoughtSignature` the model sent with it. See
    /// `GeminiLLMProvider.thoughtSignatureReplay(in:)`.
    func assistantTurn(toolCalls: [PendingToolCall], reasoning: String?, replay: JSONValue?) -> [String: Any] {
        var turn = assistantTurn(toolCalls: toolCalls, reasoning: reasoning)
        guard case .object(let fields)? = replay, case .array(let signatures)? = fields["functionCallThoughtSignatures"],
              var parts = turn["parts"] as? [[String: Any]] else { return turn }
        var callIndex = 0
        for i in parts.indices where parts[i]["functionCall"] != nil {
            if callIndex < signatures.count, case .string(let signature) = signatures[callIndex] {
                parts[i]["thoughtSignature"] = signature
            }
            callIndex += 1
        }
        turn["parts"] = parts
        return turn
    }

    func toolResultTurns(observations: [ToolObservation]) -> [[String: Any]] {
        // Gemini collects all functionResponse parts into one user turn, mirroring
        // Claude's one-message-per-batch shape.
        let parts: [[String: Any]] = observations.map { obs in
            [
                "functionResponse": [
                    "name": obs.toolName,
                    // `response` must be an object per Gemini spec; wrap the tool's
                    // output string under a conventional `result` key.
                    "response": [
                        "result": obs.result
                    ]
                ]
            ]
        }
        return [[
            "role": "user",
            "parts": parts
        ]]
    }

    /// Gemini has no `content` field on messages — everything is `parts`. Overrides
    /// the default `{role, content}` shape so system alerts inject correctly.
    func systemAlertTurn(message: String) -> [String: Any] {
        [
            "role": "user",
            "parts": [["text": message]]
        ]
    }

    /// Converts canonical `{role, content: string}` messages to `{role, parts: [{text}]}` and the `assistant` role to
    /// `model`; "system" passes through, since the provider extracts it to `systemInstruction`.
    func normalizeCanonical(message: [String: String]) -> [String: Any] {
        let rawRole = message["role"] ?? "user"
        let content = message["content"] ?? ""
        let geminiRole: String
        switch rawRole {
        case "assistant": geminiRole = "model"
        case "system":    geminiRole = "system"
        default:          geminiRole = "user"
        }
        return [
            "role": geminiRole,
            "parts": [["text": content]]
        ]
    }

    /// Kickoff user turn. Text-only → `parts:[{text}]` (byte-identical to this
    /// adapter's normalizeCanonical user turn). With images → `parts` mixing text
    /// and `inlineData` (base64) blocks.
    func userTurn(text: String, images: [ResolvedImage]) -> [String: Any] {
        var parts: [[String: Any]] = []
        if !text.isEmpty { parts.append(["text": text]) }
        for img in images {
            parts.append(["inlineData": ["mimeType": img.mimeType, "data": img.base64]])
        }
        return ["role": "user", "parts": parts]
    }

    private func argumentsToDict(_ args: [String: JSONValue]) -> [String: Any] {
        args.mapValues { $0.rawValue }
    }
}

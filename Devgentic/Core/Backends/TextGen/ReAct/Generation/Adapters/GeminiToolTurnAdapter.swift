// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GeminiToolTurnAdapter.swift
//  Devgentic
//
//  Native-turn serializer for Google Gemini's generateContent API.
//  Gemini differs from the OpenAI-family shapes in three ways:
//    1. Role is "model" for assistant turns (not "assistant").
//    2. Content lives inside `parts`, not `content`.
//    3. Tool calls are `functionCall` parts; results are `functionResponse` parts.
//

import Foundation

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

    /// Canonical `{role, content: string}` messages need to be converted to
    /// `{role, parts: [{text}]}` for Gemini's message shape, and canonical
    /// `assistant` role translated to Gemini's `model` role.
    /// Role "system" passes through — the provider extracts it to the top-level
    /// `systemInstruction` field.
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

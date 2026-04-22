//
//  ToolTurnAdapterProtocol.swift
//  Devgentic
//
//  Serializes in-request tool-call / tool-result exchanges into each
//  provider's native conversation shape. Parallel to `ToolSchemaAdapter`,
//  which serializes OUTGOING tool definitions; this serializes the
//  CONVERSATIONAL turns that carry tool calls and their results.
//
//  Used only on the native-turn path (Claude / OpenAI / Ollama native / Gemini).
//  MLX and dialect generators parse tool calls from text and keep the legacy
//  `<working_memory>` user-message path — they do not use this adapter.
//

import Foundation

/// Provider-specific serializer for `assistant(tool_calls) → tool(result)` turn pairs.
///
/// Providers diverge on the exact wire shape:
///   - Claude: content blocks (`tool_use`, `tool_result`) inside `content` arrays.
///   - OpenAI / Ollama: top-level `tool_calls` on assistant messages + `tool` role messages for results.
///   - Gemini: `parts` arrays with `functionCall` / `functionResponse` objects, and `model` role instead of `assistant`.
///
/// Each adapter encapsulates one of these shapes so the executor stays provider-agnostic.
protocol ToolTurnAdapter: Sendable {

    /// Serializes the assistant turn the model just produced — its tool calls
    /// plus any reasoning content emitted alongside them.
    ///
    /// `reasoning` is rendered in the provider's natural place for model text:
    ///   - Claude: a `text` content block preceding the `tool_use` blocks.
    ///   - OpenAI / Ollama: the top-level `content` field alongside `tool_calls`.
    ///   - Gemini: a `text` part preceding `functionCall` parts.
    func assistantTurn(toolCalls: [PendingToolCall], reasoning: String?) -> [String: Any]

    /// Serializes tool-result turn(s) for a batch of observations from one iteration.
    ///
    /// The returned array length varies by provider:
    ///   - Claude: 1 user message carrying all `tool_result` blocks.
    ///   - OpenAI / Ollama: N `tool` role messages — one per observation.
    ///   - Gemini: 1 user message carrying all `functionResponse` parts.
    ///
    /// Returning a flat `[[String: Any]]` lets the executor append directly to its
    /// live turns without per-provider branching.
    func toolResultTurns(observations: [ToolObservation]) -> [[String: Any]]

    /// Converts a canonical `{role, content}` message (string content, OpenAI-family shape)
    /// into this provider's native wire shape. Used for the initial turns produced by
    /// `PromptBuilder` (system prompt + kickoff user message) so the executor can thread
    /// them into `liveConversationTurns` without per-provider branching.
    ///
    /// Default implementation returns the message as-is (correct for Ollama/OpenAI/Claude —
    /// all three accept `{role, content: string}` at minimum). Gemini overrides because
    /// its messages use `parts: [{text: ...}]` instead of a `content` field.
    func normalizeCanonical(message: [String: String]) -> [String: Any]
}

extension ToolTurnAdapter {
    /// Serializes a system alert (memory-pressure, circuit-breaker, format-correction)
    /// as a plain user turn. Default implementation is universal — every provider
    /// accepts `{"role": "user", "content": "..."}`. Providers can override if a
    /// specialized shape is ever needed.
    func systemAlertTurn(message: String) -> [String: Any] {
        ["role": "user", "content": message]
    }

    /// Default: pass canonical through as-is. Valid for Ollama/OpenAI/Claude.
    /// Gemini overrides.
    func normalizeCanonical(message: [String: String]) -> [String: Any] {
        message as [String: Any]
    }
}

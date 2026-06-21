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

/// A pre-resolved image ready for native serialization. Bytes are already loaded
/// and base64-encoded, because `ToolTurnAdapter` methods are synchronous — image
/// resolution (async) happens upstream in the executor before the turn is built.
struct ResolvedImage: Sendable {
    let mimeType: String   // "image/png", "image/jpeg", …
    let base64: String     // base64-encoded image bytes
}

/// Coarse classification of an already-serialized native turn, used by the executor
/// to compact the conversation payload along pairing-safe boundaries (#22). The
/// concrete wire shapes diverge per provider, so classification lives on the adapter.
enum NativeTurnKind {
    /// Assistant/model turn carrying tool calls (`tool_use` blocks / top-level
    /// `tool_calls` / `functionCall` parts).
    case toolCallAssistant
    /// Turn carrying tool results (`tool_result` blocks / `role: tool` / `functionResponse` parts).
    case toolResult
    /// Anything else — system prompt, user kickoff, history, or a standalone alert turn.
    /// Unpaired, so safe to drop or keep without orphaning a tool-call id.
    case other
}

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

    /// Builds the kickoff user turn carrying the original query plus any attached
    /// images (native multimodal input on the agent path). `images` is empty for
    /// text-only turns — in which case the output MUST be byte-identical to
    /// `normalizeCanonical({role:user, content:text})` so text runs (and their
    /// KV-cache prefix) are unchanged. Vision-capable cloud adapters (Claude/
    /// OpenAI/Gemini) override to emit their native image shape; non-vision/local
    /// adapters use the default and silently ignore images.
    func userTurn(text: String, images: [ResolvedImage]) -> [String: Any]

    /// Classifies an already-built turn so the executor can find pairing-safe
    /// compaction boundaries without reaching into provider-specific keys (#22). A
    /// default implementation covers every current provider; override only if a new
    /// wire shape can't be told apart by the shared key inspection.
    func classifyTurn(_ turn: [String: Any]) -> NativeTurnKind
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

    /// Default: ignore images (non-vision / local providers) — produce the same
    /// normalized text turn as before, so text-only runs stay byte-identical.
    /// Vision-capable cloud adapters override.
    func userTurn(text: String, images: [ResolvedImage]) -> [String: Any] {
        normalizeCanonical(message: ["role": "user", "content": text])
    }

    /// Universal classifier covering every current adapter's wire shape:
    ///   - OpenAI / Ollama: `role == "tool"` (result) or a top-level `tool_calls` array (call).
    ///   - Claude: a `content` block array containing a `tool_use` (call) or `tool_result` (result) block.
    ///   - Gemini: a `parts` array containing a `functionCall` (call) or `functionResponse` (result) part.
    /// Everything else (system / user / kickoff / alert) is `.other`. The branches are
    /// mutually exclusive across providers, so one shared implementation is safe.
    func classifyTurn(_ turn: [String: Any]) -> NativeTurnKind {
        // OpenAI / Ollama
        if (turn["role"] as? String) == "tool" { return .toolResult }
        if let calls = turn["tool_calls"] as? [Any], !calls.isEmpty { return .toolCallAssistant }
        // Claude content-block array
        if let blocks = turn["content"] as? [[String: Any]] {
            if blocks.contains(where: { ($0["type"] as? String) == "tool_use" }) { return .toolCallAssistant }
            if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) { return .toolResult }
        }
        // Gemini parts array
        if let parts = turn["parts"] as? [[String: Any]] {
            if parts.contains(where: { $0["functionCall"] != nil }) { return .toolCallAssistant }
            if parts.contains(where: { $0["functionResponse"] != nil }) { return .toolResult }
        }
        return .other
    }
}

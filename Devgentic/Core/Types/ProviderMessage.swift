//
//  ProviderMessage.swift
//  Devgentic
//
//  Multimodal Pipeline Migration — Phase 6
//  Provider-agnostic message representation that replaces [[String: String]].
//  Each provider adapter maps this to its specific API format.
//
//  Created by Raj Singh on 15/03/26.
//

import Foundation

/// Provider-agnostic message representation supporting multimodal content.
/// Replaces the legacy `[String: String]` message dictionaries used by LLMProvider.
public struct ProviderMessage: Sendable {
    /// Message role: "system", "user", "assistant", "tool"
    public let role: String

    /// Multimodal content blocks.
    public let content: [MessageBlock]

    /// For tool result messages — the ID of the tool call this responds to.
    public let toolCallId: String?

    public init(role: String, content: [MessageBlock], toolCallId: String? = nil) {
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
    }

    /// Construct from legacy [String: String] dict for backward compatibility.
    public init(legacy dict: [String: String]) {
        self.role = dict["role"] ?? "user"
        self.content = [.text(dict["content"] ?? "")]
        self.toolCallId = nil
    }

    /// Downgrade to legacy format (for providers not yet migrated to multimodal).
    public func toLegacyDict() -> [String: String] {
        ["role": role, "content": content.textContent]
    }
}

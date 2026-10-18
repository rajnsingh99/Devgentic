// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProviderMessage.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Provider-agnostic message representation supporting multimodal content.
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

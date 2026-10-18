// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsTransport.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - HITL Type

/// Describes the type of Human-In-The-Loop interaction to present on a remote transport.
/// `Codable` and `Equatable` are declared on the type because `RemoteView.prompt` requires them.
enum HITLType: Sendable, Equatable, Codable {
    case toolConfirmation(toolName: String, params: String)
    case clarification(question: String)
    case planReview(subtaskDescriptions: [String])
    /// [D1] Workflow Gate — rendered as one tappable button per option (callback `hitl:gate:<opID>:<idx>`).
    case gate(prompt: String, options: [String])
}

// MARK: - Transport Protocol

/// Abstraction over messaging platforms (Telegram, Discord, Slack, etc.).
/// `RemoteMirrorService` mirrors stream events through it without knowing the platform.
/// All IDs are `String` to accommodate non-numeric identifiers (e.g. Slack channel `"C0123456789"`).
protocol ChatOpsTransport: AnyObject, Sendable {

    /// Unique identifier for this transport (e.g., "telegram", "discord", "slack").
    var transportID: String { get }

    /// Send a plain text message.
    func sendTextMessage(chatID: String, text: String) async throws

    /// Send a long text message, splitting into platform-appropriate chunks.
    func sendChunkedMessage(chatID: String, text: String) async throws

    /// Edit an existing message in-place (e.g., to update HITL status after resolution).
    func editMessage(chatID: String, messageID: String, newText: String) async throws

    /// Show a typing/processing indicator.
    func sendTypingIndicator(chatID: String) async throws

    // MARK: - Remote view rendering (C3)

    /// What this platform can render. Facts about the platform, not preferences — see
    /// `RemoteCapabilities`.
    nonisolated var capabilities: RemoteCapabilities { get }

    // Why: `RemoteMirrorService` stores the id to edit a prompt in place when it resolves.
    /// Posts a view whose content was decided elsewhere; a `.silent` view posts nothing and logs why.
    /// - Returns: the platform message id of what was posted, or nil when nothing was posted.
    @discardableResult
    func render(_ view: RemoteView, to destination: RemoteDestination) async throws -> String?
}

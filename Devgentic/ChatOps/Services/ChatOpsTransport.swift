//
//  ChatOpsTransport.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import Foundation

// MARK: - HITL Type

/// Describes the type of Human-In-The-Loop interaction to present on a remote transport.
enum HITLType: Sendable {
    case toolConfirmation(toolName: String, params: String)
    case clarification(question: String)
    case planReview(subtaskDescriptions: [String])
    /// [D1] Workflow Gate — rendered as one tappable button per option (callback `hitl:gate:<opID>:<idx>`).
    case gate(prompt: String, options: [String])
}

// MARK: - Transport Protocol

/// Abstraction over messaging platforms (Telegram, Discord, Slack, etc.).
///
/// Each transport implements platform-specific APIs behind a uniform interface.
/// The `RemoteMirrorService` uses this protocol to mirror stream events
/// without knowing which platform it's talking to.
///
/// All IDs are `String` to accommodate platforms with non-numeric identifiers
/// (e.g., Slack channels like `"C0123456789"`, timestamps like `"1716307200.123456"`).
protocol ChatOpsTransport: AnyObject, Sendable {

    /// Unique identifier for this transport (e.g., "telegram", "discord", "slack").
    var transportID: String { get }

    /// Send a plain text message.
    func sendTextMessage(chatID: String, text: String) async throws

    /// Send a long text message, splitting into platform-appropriate chunks.
    func sendChunkedMessage(chatID: String, text: String) async throws

    /// Send an HITL prompt (approval buttons or clarification question).
    /// - Returns: The platform-specific message ID for later editing.
    func sendHITLPrompt(
        chatID: String,
        operationID: UUID,
        type: HITLType
    ) async throws -> String

    /// Edit an existing message in-place (e.g., to update HITL status after resolution).
    func editMessage(chatID: String, messageID: String, newText: String) async throws

    /// Show a typing/processing indicator.
    func sendTypingIndicator(chatID: String) async throws
}

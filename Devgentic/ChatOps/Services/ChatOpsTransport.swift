// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsTransport.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import Foundation

// MARK: - HITL Type

/// Describes the type of Human-In-The-Loop interaction to present on a remote transport.
///
/// ⚠️ `Codable` and `Equatable` are carried for `RemoteView.prompt`, which requires them so the
/// compiler can refuse any view that reaches for a secret-bearing type — `BackendProfileSnapshot`
/// is deliberately non-`Codable` for exactly that reason. Synthesis must be declared on the type
/// itself, not bolted on in an extension from another file. No behaviour change: nothing encodes
/// or compares a `HITLType` today.
enum HITLType: Sendable, Equatable, Codable {
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

    /// Edit an existing message in-place (e.g., to update HITL status after resolution).
    func editMessage(chatID: String, messageID: String, newText: String) async throws

    /// Show a typing/processing indicator.
    func sendTypingIndicator(chatID: String) async throws

    // MARK: - Remote view rendering (C3)

    /// What this platform can render. Facts about the platform, not preferences — see
    /// `RemoteCapabilities`.
    nonisolated var capabilities: RemoteCapabilities { get }

    /// Posts a view whose content was decided elsewhere.
    ///
    /// ⚠️ THE DECISION ARRIVES ALREADY MADE, AND THAT IS THE WHOLE REFACTOR. Today twelve
    /// `private func … -> Void` handlers each run a SwiftData query, build a platform widget AND
    /// send — written three times over, which is why `/conversations` has two different Discord
    /// renderings. A command returns a `RemoteView`; this is the only thing that posts one.
    ///
    /// A `.silent` view posts nothing and logs why. Every other case — including `.prompt`, whose
    /// dedicated send method this replaced at C8.5 — goes out through here.
    /// - Returns: the platform message id of what was posted, so a prompt can be edited in place
    ///   when it resolves — or nil when nothing was posted (a `.silent` view).
    ///
    /// ⚠️ THE RETURN VALUE IS LOAD-BEARING, and it was the last thing keeping the old
    /// prompt-sending method alive. `RemoteMirrorService` stores this id in `hitlMessageIDs` and
    /// uses it at four sites to strike through a resolved prompt and clear its buttons — a
    /// `Void`-returning render could not replace a method whose entire contract was that id.
    @discardableResult
    func render(_ view: RemoteView, to destination: RemoteDestination) async throws -> String?
}

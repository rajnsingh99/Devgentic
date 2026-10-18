// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsHosting.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Run control

/// What a remote surface needs to know and do about a conversation's in-flight run.
/// Every member is keyed on a conversation id alone, so a remote command can act on a conversation
/// the local user is not viewing.
@MainActor
protocol RemoteRunControlling: AnyObject {

    /// Whether a run is currently streaming into `conversation`.
    /// Conversation-scoped: another conversation being busy does not count.
    func hasActiveRun(inConversation conversation: UUID) -> Bool

    /// The operation id of the clarification this conversation is parked on, if any.
    /// Derived by the host from `InteractionCenter`, never stored by a bridge.
    func pendingClarificationID(inConversation conversation: UUID) -> UUID?

    /// What the run in `conversation` is waiting on from a human ("your approval", ...), if anything.
    /// Lets a refused remote prompt say what is pending instead of only "still working".
    func pendingQuestionNoun(inConversation conversation: UUID) -> String?

    // Why: the three steps are one method so the order cannot change:
    // cancelling destroys the evidence, and denying a parked gate alone fails the run's error branch.
    /// Cancels the run in `conversation`, not merely its parked question, and reports whether one was active.
    /// Reads `hasActiveRun` first, cancels the stream, then clears any parked suspension that had no live task.
    @discardableResult
    func cancelRun(inConversation conversation: UUID) async -> Bool
}

// MARK: - Conversation commanding

/// Creating a conversation, pointing it at a profile, and submitting a remote turn to it.
@MainActor
protocol RemoteConversationCommanding: AnyObject {

    /// The profile a new remote conversation falls back to when none is bound.
    /// The app-global composer selection shared with the Mac window and Orb; read-only so a remote
    /// write cannot retarget the local composer.
    var defaultProfileID: UUID? { get }

    /// Creates a conversation bound to `profile` and returns its id.
    /// Takes the profile rather than an id because the call needs the model to derive the `BackendType` column.
    func createConversation(profile: BackendProfileModel, title: String) -> UUID

    /// Moves the Mac window's selection to `conversation`.
    /// A remote conversation switch therefore moves the local user's window.
    func focusConversationInMainWindow(_ conversation: UUID)

    /// Binds `profile` to `conversation`, so every later run there uses it.
    /// Persisted on the conversation rather than as a composer pointer; a write to the app-global
    /// selection would retarget the next local send.
    func bindProfile(_ profile: UUID, toConversation conversation: UUID)

    func submitRemote(
        prompt: String,
        conversationID: UUID,
        source: MessageSource,
        config: BackendRequestConfig
    )
}

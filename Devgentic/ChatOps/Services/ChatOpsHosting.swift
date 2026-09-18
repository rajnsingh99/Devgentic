// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsHosting.swift
//  Devgentic
//
//  The seam between a ChatOps command and the running app.
//
//  WHY THIS EXISTS. Constructing a `MainApplicationViewModel` runs `ChatOpsCoordinator.bootstrap()`,
//  which opens REAL Telegram/Discord/Slack listeners — six files in this repo carry that warning.
//  So no unit test may build one, and today every ChatOps command handler reaches the view model
//  directly. That is the structural reason the twelve handlers are untestable, and being
//  untestable is why three of them silently diverged and two shipped dead.
//
//  ⚠️ TWO PROTOCOLS, NOT ONE, AND THE SPLIT IS THE POINT. The first draft of this seam was a
//  single seven-member `ChatOpsHosting` — three and a half times `MessageStreamStarting`, whose
//  own file warns against exactly this ("not an interface for ActiveStreamManager … a protocol
//  carrying all of it would just be the class again with extra steps"). A seven-member protocol
//  over one god object is that class again. These are two protocols because they answer two
//  different questions, and a caller adopts only the one it needs:
//
//    - `RemoteRunControlling`        — what is this conversation's run doing, and stop it.
//    - `RemoteConversationCommanding` — aim a conversation at a profile and submit work to it.
//
//  A future member belongs to whichever question it answers. If it answers neither, it needs its
//  own narrow protocol, not a slot in one of these.
//
//  ⚠️ WHAT IS DELIBERATELY ABSENT: persistence reads. `ChatPersistenceProtocol` already carries
//  `getConversation(withId:)` and is already injected, so routing conversation reads through the
//  host would be a second path to data that already has one. Conversation LIST reads get their
//  own narrow protocol when they arrive; they do not belong here either.
//

import Foundation

// MARK: - Run control

/// What a remote surface needs to know and do about a conversation's in-flight run.
///
/// Every member is keyed on a conversation id and nothing else — no message id, no run id, no
/// selection. That is what lets a remote command act on a conversation the local user is not
/// looking at, which is the normal case for ChatOps.
@MainActor
protocol RemoteRunControlling: AnyObject {

    /// Whether a run is currently streaming into `conversation`.
    ///
    /// ⚠️ Conversation-scoped on purpose. `/status` once read the app-global
    /// `MainApplicationViewModel.streamingMessageID` and so reported "streaming" whenever ANY
    /// conversation was busy, including one the remote user had never touched.
    func hasActiveRun(inConversation conversation: UUID) -> Bool

    /// The operation id of the clarification this conversation is parked on, if any.
    ///
    /// ⚠️ DERIVED, never stored. The Telegram bridge computes this from `InteractionCenter` and is
    /// correct; the Discord and Slack bridges each hold a `private var awaitingClarification` that
    /// is only ever assigned `false`, so on those two platforms a clarification reply can never be
    /// recognised and instead starts a second concurrent run. Handing the derivation to the host
    /// is what lets all three share the one correct answer and lets both dead flags be deleted.
    func pendingClarificationID(inConversation conversation: UUID) -> UUID?

    /// Cancels the RUN in `conversation` — not merely its parked question — and reports whether
    /// one was active.
    ///
    /// ⚠️ THE ORDERING IS THE CONTRACT, WHICH IS WHY IT IS ONE METHOD AND NOT THREE. [WF-SE10]
    /// This path used to call only `ExecutionSuspensionService.cancel(for:)` and then claim the
    /// agent was cancelled — but that denies a parked HITL while the stream keeps executing, and a
    /// denied Gate manufactures a red "not answered" failure that routes the run down its error
    /// branch (WF-CC1). The correct sequence is: read `hasActiveRun` FIRST (cancelling destroys the
    /// evidence), then cancel the stream, then clear any parked suspension that had no live task.
    /// Exposing the three steps separately would let a caller reorder them; bundling makes the
    /// wrong order unrepresentable rather than merely discouraged.
    @discardableResult
    func cancelRun(inConversation conversation: UUID) async -> Bool
}

// MARK: - Conversation commanding

/// Creating a conversation, pointing it at a profile, and submitting a remote turn to it.
@MainActor
protocol RemoteConversationCommanding: AnyObject {

    /// The profile a new remote conversation falls back to when none is bound.
    ///
    /// ⚠️ This is the app-global composer selection, shared with the Mac window and Orb. It is
    /// exposed READ-ONLY on purpose: a remote write would retarget the local user's composer.
    var defaultProfileID: UUID? { get }

    /// Creates a conversation bound to `profile` and returns its id.
    ///
    /// The parameter is a profile, not an id, because the underlying call needs the model to derive
    /// the legacy `BackendType` column. Named `profile` rather than the existing call's misleading
    /// `profileID:` label.
    func createConversation(profile: BackendProfileModel, title: String) -> UUID

    /// Moves the Mac window's selection to `conversation`.
    ///
    /// ⚠️ SLICE 1 PRESERVES TODAY'S BEHAVIOUR: a remote conversation switch really does move the
    /// local user's window. That is almost certainly wrong once a remote session owns its own
    /// cursor, and it is a separate member — rather than folded into the switch handler — so that
    /// retiring it is deleting one call site and one test rather than untangling a fused method.
    func focusConversationInMainWindow(_ conversation: UUID)

    /// Submits a remote turn through the same send path the Mac UI uses.
    ///
    /// ⚠️ `source` is stamped on the persisted user message and is the only record that a run was
    /// started remotely. It is a parameter rather than a property of the host because one host
    /// serves all three providers.
    /// Binds `profile` to `conversation`, so every later run there uses it.
    ///
    /// ⚠️ Persisted (`ConversationSD.backendEntityId`), not a composer pointer — the Mac's own
    /// selection is app-global and a remote write to it would retarget the local user's next send.
    func bindProfile(_ profile: UUID, toConversation conversation: UUID)

    func submitRemote(
        prompt: String,
        conversationID: UUID,
        source: MessageSource,
        config: BackendRequestConfig
    )
}

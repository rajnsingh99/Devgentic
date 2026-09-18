// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ComposerDraftStore.swift
//  Devgentic
//
//  Per-conversation composer drafts (typed text + attachments), held for the app session.
//
//  WHY: the composer's view model is APP-SCOPED — one `ChatInputViewModel` for every
//  conversation (`DevgenticApp`), and `attachedFiles` likewise lives on the single
//  `MainApplicationViewModel`. Nothing reset either when the selected conversation
//  changed, so a half-typed message and its attachments followed you from conversation A
//  into B, where they could be sent by accident. (Asymmetric, too: `startNewConversation`
//  cleared attachments but never the text.)
//
//  This store makes the composer's contents belong to a conversation: they're saved under
//  the one you're leaving and restored for the one you're entering.
//
//  Session-scoped on purpose — drafts do NOT survive relaunch. Persisting them is a
//  separate feature with its own questions (staleness, privacy of unsent text on disk);
//  the bug being fixed here is the cross-conversation leak.
//

import Foundation

@MainActor
final class ComposerDraftStore {

    /// Shared instance used by the composer and the conversation coordinator. The type is
    /// still freely instantiable so tests get an isolated store instead of shared state.
    static let shared = ComposerDraftStore()

    init() {}

    /// What the composer holds for one conversation.
    struct Draft: Equatable {
        var text: String = ""
        var attachments: [FileSystemItem] = []

        var isEmpty: Bool { text.isEmpty && attachments.isEmpty }
    }

    /// Keyed by conversation. `nil` is a real key — it's the not-yet-created "new chat",
    /// so a draft typed before the first send is preserved across a detour into an
    /// existing conversation and back.
    private var drafts: [UUID?: Draft] = [:]

    /// Number of stored drafts — for tests and for reasoning about growth.
    var storedDraftCount: Int { drafts.count }

    /// Saves the draft for a conversation. An EMPTY draft removes the entry rather than
    /// storing it, so merely visiting a conversation doesn't leave a slot behind and a
    /// sent (cleared) composer doesn't resurrect as an empty draft later.
    func save(_ draft: Draft, for conversationID: UUID?) {
        if draft.isEmpty {
            drafts.removeValue(forKey: conversationID)
        } else {
            drafts[conversationID] = draft
        }
    }

    /// The stored draft, or an empty one — restoring an empty draft is what CLEARS the
    /// composer when entering a conversation that has none.
    func draft(for conversationID: UUID?) -> Draft {
        drafts[conversationID] ?? Draft()
    }

    /// Drops a conversation's draft. Called when the conversation is deleted so unsent
    /// text doesn't outlive the thing it belonged to.
    func discard(for conversationID: UUID?) {
        drafts.removeValue(forKey: conversationID)
    }
}

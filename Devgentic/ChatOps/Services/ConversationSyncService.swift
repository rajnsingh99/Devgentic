// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationSyncService.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import Foundation
import os

/// Ensures the Mac UI updates in real-time when remote messages arrive.
///
/// Without this service, `ChatHistoryViewModel` only loads messages when the user
/// selects a conversation (pull-based). This service adds push-based observation:
///
/// 1. **CoreData observation** — when a new message is persisted for the currently
///    displayed conversation, it's automatically inserted into the view.
/// 2. **ActiveStreamManager observation** — when a new agent stream starts for the
///    currently displayed conversation, the streaming message is injected into the view.
@MainActor
final class ConversationSyncService {

    private let logger = DGLogger(category: "ConversationSync")

    private weak var chatHistoryViewModel: ChatHistoryViewModel?
    private weak var activeStreamManager: ActiveStreamManager?

    /// Tracks message IDs already in the view (to avoid duplicate insertions).

    /// Bridges `ActiveStreamManager.activeStreams` changes so we can inject
    /// newly-started streams into the visible conversation.
    private var activeStreamsObserver: ObservationStream?

    init(chatHistoryViewModel: ChatHistoryViewModel, activeStreamManager: ActiveStreamManager) {
        self.chatHistoryViewModel = chatHistoryViewModel
        self.activeStreamManager = activeStreamManager

        setupActiveStreamsObserver()

        logger.info("ConversationSyncService initialized.")
    }

    deinit { }

    // MARK: - Active Conversation ID

    /// The conversation an arriving stream belongs to.
    ///
    /// ⚠️ Was `currentChatMessages.first?.conversationId` — identity inferred from POSITION, and
    /// the weakest of the competing definitions in the codebase. THE FAILURE THAT FIXES: after a
    /// pre-clear (`= []` — the welcome screen, an interface-mode switch, ⌘N) the array is empty,
    /// so this returned nil and the observer bailed. The stream was never injected, leaving a bubble
    /// that only appeared on reload. (This sentence named `syncedMessageIDs` until [MIR-6] deleted
    /// that set — a comment describing a field that no longer exists is how the next reader is sent
    /// looking for state that is not there.)
    ///
    /// `destinationConversationID` is the authority for this question, and it is VIEWER identity:
    /// `loadingConversationID ?? viewerOwningConversationID`. It does not lead the user's
    /// SELECTION, which is the property this call site depends on.
    ///
    /// ⚠️ IT IS NOT CONSTANT ACROSS A SWITCH, and an earlier version of this comment claimed both
    /// that it "trails the load" and that a stream for the incoming conversation used to be
    /// wrongly rejected — two statements that cannot both be requirements. What actually happens,
    /// in two spans:
    ///   1. The 250 ms debounce + `unloadModel()` span, before `loadConversation` runs.
    ///      `loadingConversationID` is nil, so the destination is the OUTGOING conversation and a
    ///      stream for the incoming one is still dropped here. That is correct: its rows are not
    ///      on screen yet.
    ///   2. Inside `loadConversation`, from `loadingConversationID = selectedID` to the array
    ///      assignment. The destination is the INCOMING conversation while `currentChatMessages`
    ///      still holds the outgoing rows, so a stream CAN be injected into the outgoing array.
    ///      Benign, and checked rather than assumed: the transcript is at `.opacity(0)` behind a
    ///      ProgressView for exactly that span (`ChatHistoryView` drives `isContentReady` off
    ///      `isInitiallyLoadingConversation`, set two lines later), and the load then replaces the
    ///      array wholesale with a list that already merges `activeStreams` for the incoming
    ///      conversation. It survives only if that load is discarded as stale or cancelled, and
    ///      the next load replaces it.
    ///
    /// ⚠️ An identity that led the SELECTION existed for one day (2026-09-06/07) and was removed;
    /// see `ChatHistoryViewModel.destinationConversationID`'s own comment. Do not reintroduce one
    /// for this call site: through the whole of span 1 it would inject the incoming
    /// conversation's streaming bubble into the outgoing conversation's VISIBLE transcript.
    private var destinationConversationID: UUID? {
        chatHistoryViewModel?.destinationConversationID
    }

    // MARK: - ActiveStreamManager Observation

    /// When a new stream appears for the currently displayed conversation,
    /// inject it into `currentChatMessages` so the user sees it immediately.
    private func setupActiveStreamsObserver() {
        guard let asm = activeStreamManager else { return }

        activeStreamsObserver = ObservationStream(
            track: {
                _ = asm.activeStreams
            },
            onChange: { [weak self] in
                guard let self,
                      let chvm = self.chatHistoryViewModel,
                      let asm = self.activeStreamManager else { return }
                guard let destinationID = self.destinationConversationID else { return }

                // ⚠️⚠️ [MIR-6] THE `syncedMessageIDs` SET IS GONE, AND DELETING IT IS MORE CORRECT
                // THAN RESETTING IT. It was a second, weaker copy of the question the next line
                // already answers authoritatively — "is this message in the view?" — and its only
                // reset hook (`resetForConversation`) had ZERO callers, so it grew for the life of
                // the process and could SUPPRESS an injection the view genuinely needed after a
                // conversation switch. Keeping it would have meant either wiring the dead hook up or
                // documenting an unwritten cross-file claim about what `loadConversation` merges —
                // the kind of load-bearing assumption about another file this codebase's comments
                // keep getting wrong. Asking the view directly cannot go stale, and unbounded growth
                // becomes unrepresentable rather than merely unlikely.
                for (_, message) in asm.activeStreams {
                    guard message.conversationId == destinationID else { continue }
                    guard !chvm.currentChatMessages.contains(where: { $0.id == message.id }) else { continue }

                    chvm.currentChatMessages.insert(message, at: 0)
                    self.logger.info("[Sync] Injected streaming message \(message.id) into displayed conversation.")
                }
            }
        )
    }

    // CoreData observation removed — SwiftData handles persistence updates via @Observable.

}

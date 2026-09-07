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

    private let logger = Logger(subsystem: DGLogger.subsystem, category: "ConversationSync")

    private weak var chatHistoryViewModel: ChatHistoryViewModel?
    private weak var activeStreamManager: ActiveStreamManager?

    /// Tracks message IDs already in the view (to avoid duplicate insertions).
    private var syncedMessageIDs: Set<UUID> = []

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
    /// so this returned nil and the observer bailed. The stream was never injected and
    /// `syncedMessageIDs` never recorded it, leaving a bubble that only appeared on reload.
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

                for (_, message) in asm.activeStreams {
                    guard message.conversationId == destinationID else { continue }
                    guard !self.syncedMessageIDs.contains(message.id) else { continue }

                    let alreadyInView = chvm.currentChatMessages.contains { $0.id == message.id }
                    guard !alreadyInView else {
                        self.syncedMessageIDs.insert(message.id)
                        continue
                    }

                    chvm.currentChatMessages.insert(message, at: 0)
                    self.syncedMessageIDs.insert(message.id)
                    self.logger.info("[Sync] Injected streaming message \(message.id) into displayed conversation.")
                }
            }
        )
    }

    // CoreData observation removed — SwiftData handles persistence updates via @Observable.

    /// Called when the displayed conversation changes (to reset tracking state).
    func resetForConversation(_ conversationID: UUID?) {
        syncedMessageIDs.removeAll()
        // Pre-populate with existing messages in the view
        if let messages = chatHistoryViewModel?.currentChatMessages {
            for msg in messages {
                syncedMessageIDs.insert(msg.id)
            }
        }
    }
}

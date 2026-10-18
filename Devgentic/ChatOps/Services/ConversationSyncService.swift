// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationSyncService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Pushes remote messages into the Mac UI in real time.
/// Observes persisted messages and `ActiveStreamManager` streams for the displayed conversation and injects them into
/// the view.
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

    /// The conversation an arriving stream belongs to: the viewer identity `destinationConversationID`.
    /// It does not lead the user's selection, so a stream for the incoming conversation is dropped until the load runs.
    /// During the load it may enter the outgoing array, which is hidden behind the loading overlay.
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

                // Asks the view directly whether the message is already shown, rather than tracking synced ids that could go stale or
                // grow unbounded.
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

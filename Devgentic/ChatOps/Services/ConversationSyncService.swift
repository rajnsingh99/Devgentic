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

    private let logger = Logger(subsystem: "com.devgentic", category: "ConversationSync")

    private weak var chatHistoryViewModel: ChatHistoryViewModel?
    private weak var activeStreamManager: ActiveStreamManager?

    /// Tracks message IDs already in the view (to avoid duplicate insertions).
    private var syncedMessageIDs: Set<UUID> = []

    init(chatHistoryViewModel: ChatHistoryViewModel, activeStreamManager: ActiveStreamManager) {
        self.chatHistoryViewModel = chatHistoryViewModel
        self.activeStreamManager = activeStreamManager

        setupActiveStreamsObserver()

        logger.info("ConversationSyncService initialized.")
    }

    deinit { }

    // MARK: - Active Conversation ID

    /// The conversation currently displayed in the Mac UI.
    private var displayedConversationID: UUID? {
        chatHistoryViewModel?.currentChatMessages.first?.conversationId
    }

    // MARK: - ActiveStreamManager Observation

    /// When a new stream appears for the currently displayed conversation,
    /// inject it into `currentChatMessages` so the user sees it immediately.
    private func setupActiveStreamsObserver() {
        guard let asm = activeStreamManager else { return }

        func observe() {
            withObservationTracking {
                _ = asm.activeStreams
            } onChange: {
                Task { @MainActor [weak self] in
                    guard let self, let chvm = self.chatHistoryViewModel, let asm = self.activeStreamManager else { return }
                    guard let displayedID = self.displayedConversationID else {
                        self.setupActiveStreamsObserver()
                        return
                    }

                    for (_, message) in asm.activeStreams {
                        guard message.conversationId == displayedID else { continue }
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

                    self.setupActiveStreamsObserver()
                }
            }
        }
        observe()
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

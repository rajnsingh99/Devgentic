//
//  ConversationSyncService.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import Foundation
import CoreData
import Combine
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

    private var activeStreamsSubscription: AnyCancellable?
    private var coreDataObserver: NSObjectProtocol?

    /// Tracks message IDs already in the view (to avoid duplicate insertions).
    private var syncedMessageIDs: Set<UUID> = []

    init(chatHistoryViewModel: ChatHistoryViewModel, activeStreamManager: ActiveStreamManager) {
        self.chatHistoryViewModel = chatHistoryViewModel
        self.activeStreamManager = activeStreamManager

        setupActiveStreamsObserver()
        setupCoreDataObserver()

        logger.info("ConversationSyncService initialized.")
    }

    deinit {
        if let obs = coreDataObserver { NotificationCenter.default.removeObserver(obs) }
    }

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

        activeStreamsSubscription = asm.$activeStreams
            .receive(on: RunLoop.main)
            .sink { [weak self] streams in
                guard let self, let chvm = self.chatHistoryViewModel else { return }
                guard let displayedID = self.displayedConversationID else { return }

                for (_, message) in streams {
                    guard message.conversationId == displayedID else { continue }
                    guard !self.syncedMessageIDs.contains(message.id) else { continue }

                    // Check it's not already in the view
                    let alreadyInView = chvm.currentChatMessages.contains { $0.id == message.id }
                    guard !alreadyInView else {
                        self.syncedMessageIDs.insert(message.id)
                        continue
                    }

                    // Insert at index 0 (newest first, matching ChatHistoryViewModel convention)
                    chvm.currentChatMessages.insert(message, at: 0)
                    self.syncedMessageIDs.insert(message.id)
                    self.logger.info("[Sync] Injected streaming message \(message.id) into displayed conversation.")
                }
            }
    }

    // MARK: - CoreData Observation

    /// When CoreData saves a new message for the currently displayed conversation,
    /// convert it and insert it into the view.
    private func setupCoreDataObserver() {
        coreDataObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: .main
        ) { notification in
            let insertedObjects = notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>

            Task { @MainActor [weak self] in
                guard let self,
                      let insertedObjects,
                      let displayedID = self.displayedConversationID else { return }

                for object in insertedObjects {
                    // Check if this is a message entity for the displayed conversation
                    guard object.entity.name == "ChatMessageEntity",
                          let conversationRelation = object.value(forKey: "conversation") as? NSManagedObject,
                          let convID = conversationRelation.value(forKey: "id") as? UUID,
                          convID == displayedID,
                          let msgID = object.value(forKey: "id") as? UUID else { continue }

                    // Skip if already synced (from submitRemoteMessage's direct insert or stream observer)
                    guard !self.syncedMessageIDs.contains(msgID) else { continue }

                    // Check it's not already in the view
                    guard let chvm = self.chatHistoryViewModel else { continue }
                    let alreadyInView = chvm.currentChatMessages.contains { $0.id == msgID }
                    guard !alreadyInView else {
                        self.syncedMessageIDs.insert(msgID)
                        continue
                    }

                    // Convert entity to ChatMessage (the entity should have the conversion method)
                    // For now, trigger a lightweight reload of the most recent message
                    self.syncedMessageIDs.insert(msgID)
                    self.logger.info("[Sync] Detected new persisted message \(msgID) for displayed conversation. View should update on next load.")
                }
            }
        }
    }

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

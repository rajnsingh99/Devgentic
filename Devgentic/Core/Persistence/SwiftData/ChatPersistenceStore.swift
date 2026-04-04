//
//  ChatPersistenceStore.swift
//  Devgentic
//
//  Created by Raj Singh on 03/04/26.
//  SwiftData store replacing CDPersistenceService for chat persistence.
//

import Foundation
import SwiftData
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ChatPersistenceStore")

// MARK: - Chat Persistence Protocol

@MainActor
protocol ChatPersistenceProtocol: Sendable {
    func addConversation(from conversation: Conversation)
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async
    func getConversation(withId id: UUID) -> ConversationSD?
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage]
    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String)
    func deleteConversation(with id: UUID)
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?)
    func togglePinStatus(for conversationId: UUID)
}

// MARK: - SwiftData Chat Persistence Store

@MainActor
final class ChatPersistenceStore: ChatPersistenceProtocol {

    // MARK: - Singleton Instance
    static let shared = ChatPersistenceStore()

    // MARK: - SwiftData Container

    private(set) var modelContainer: ModelContainer?

    func configureContainer(_ container: ModelContainer) {
        self.modelContainer = container
        logger.info("ChatPersistenceStore configured with SwiftData ModelContainer.")
    }

    private var mainContext: ModelContext? {
        modelContainer?.mainContext
    }

    // MARK: - Initialization
    private init() {}

    // MARK: - Conversation Methods

    func addConversation(from conversation: Conversation) {
        guard let context = mainContext else {
            logger.error("ChatPersistenceStore: container not configured.")
            return
        }

        let sd = ConversationSD(
            id: conversation.id,
            timestamp: conversation.timestamp,
            userDefinedTitle: conversation.userDefinedTitle,
            isPinned: conversation.isPinned,
            openAIThreadID: conversation.openAIThreadID,
            backendType: conversation.backendType?.rawValue,
            backendEntityId: conversation.backendEntityId
        )

        for message in conversation.messages {
            let messageSD = ChatMessageSD.from(message)
            messageSD.conversation = sd
            sd.messages.append(messageSD)
        }

        context.insert(sd)
        saveContext()
        logger.info("Added conversation \(conversation.id.uuidString).")
    }

    func getConversation(withId id: UUID) -> ConversationSD? {
        guard let context = mainContext else { return nil }

        var descriptor = FetchDescriptor<ConversationSD>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        return try? context.fetch(descriptor).first
    }

    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        guard let context = mainContext else { return [] }

        var descriptor = FetchDescriptor<ChatMessageSD>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset

        do {
            let entities = try context.fetch(descriptor)
            let messages = entities.map { $0.toChatMessage() }
            logger.debug("Fetched \(messages.count) messages for conversation \(conversationId.uuidString) (offset: \(offset), limit: \(limit)).")
            return messages
        } catch {
            logger.error("Failed to fetch messages for \(conversationId.uuidString): \(error.localizedDescription)")
            return []
        }
    }

    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {
        await addMessages([message], toConversation: conversationId)
    }

    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {
        guard let context = mainContext else { return }

        let conversation = getConversation(withId: conversationId)

        for message in messages {
            // Upsert: check if message already exists
            let messageId = message.id
            var descriptor = FetchDescriptor<ChatMessageSD>(
                predicate: #Predicate { $0.id == messageId }
            )
            descriptor.fetchLimit = 1

            let existing = try? context.fetch(descriptor).first

            if let existing {
                // Update existing message in-place
                let contentToEncode = message.currentAgentContent ?? message.content
                existing.contentData = (try? JSONEncoder().encode(contentToEncode)) ?? Data()
                existing.agentResponseData = message.agentResponse.flatMap { try? JSONEncoder().encode($0) }
                existing.timelineEventsData = message.timelineEvents.isEmpty
                    ? nil
                    : (try? JSONEncoder().encode(message.timelineEvents))
                existing.traceID = message.traceID
                existing.senderType = message.sender.rawValue

                // Update attachments
                for old in existing.attachedTextFiles { context.delete(old) }
                existing.attachedTextFiles = message.attachedTextFiles?.map { AttachedTextFileSD.from($0) } ?? []

                for old in existing.attachedImageFiles { context.delete(old) }
                existing.attachedImageFiles = message.attachedImageFiles?.map { AttachedImageFileSD.from($0) } ?? []
            } else {
                // Insert new message
                let sd = ChatMessageSD.from(message)
                sd.conversation = conversation
                context.insert(sd)
                conversation?.messages.append(sd)
            }
        }

        // Update conversation timestamp
        conversation?.timestamp = Date()
        saveContext()
        logger.debug("Upserted \(messages.count) messages for conversation \(conversationId.uuidString).")
    }

    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {
        guard let conversation = getConversation(withId: conversationId) else {
            logger.warning("Attempted to update thread ID for non-existent conversation: \(conversationId.uuidString)")
            return
        }
        conversation.openAIThreadID = threadId
        saveContext()
        logger.info("Updated conversation \(conversationId.uuidString) with OpenAI thread ID.")
    }

    func deleteConversation(with id: UUID) {
        guard let context = mainContext,
              let conversation = getConversation(withId: id) else {
            logger.warning("Tried to delete conversation \(id.uuidString), but it was not found.")
            return
        }
        context.delete(conversation)
        saveContext()
        logger.info("Deleted conversation \(id.uuidString).")
    }

    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {
        guard let conversation = getConversation(withId: id) else {
            logger.warning("Attempted to update backend for non-existent conversation: \(id.uuidString)")
            return
        }
        conversation.backendType = backendType?.rawValue
        conversation.backendEntityId = backendEntityId
        saveContext()
        logger.info("Updated conversation \(id.uuidString) with backend type: \(backendType?.rawValue ?? "none").")
    }

    func togglePinStatus(for conversationId: UUID) {
        guard let conversation = getConversation(withId: conversationId) else {
            logger.warning("Attempted to toggle pin for non-existent conversation: \(conversationId.uuidString)")
            return
        }
        conversation.isPinned.toggle()
        saveContext()
        logger.info("Toggled pin for conversation \(conversationId.uuidString) to \(conversation.isPinned).")
    }

    // MARK: - Private

    private func saveContext() {
        guard let context = mainContext else { return }
        do {
            try context.save()
        } catch {
            logger.error("Failed to save chat context: \(error.localizedDescription)")
        }
    }
}

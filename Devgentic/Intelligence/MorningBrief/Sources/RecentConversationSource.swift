//
//  RecentConversationSource.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import CoreData
import os

/// Gathers raw message content from the most recent conversations.
/// This content is fed to the Intelligence Core for AI summarization —
/// the source itself does NOT display anything directly.
final class RecentConversationSource: MorningBriefSource, Sendable {

    let id = "recent_conversations"
    let displayName = "Recent Conversations"
    let icon = "bubble.left.and.text.bubble.right"

    var isEnabled: Bool { true }

    private let maxConversations: Int
    private let maxMessagesPerConversation: Int
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic", category: "RecentConversationSource")

    init(maxConversations: Int = 3, maxMessagesPerConversation: Int = 20) {
        self.maxConversations = maxConversations
        self.maxMessagesPerConversation = maxMessagesPerConversation
    }

    func gather() async -> [BriefFragment] {
        let contexts = await fetchConversationContexts()

        guard !contexts.isEmpty else {
            logger.info("[RecentConversationSource] No recent conversations found.")
            return []
        }

        logger.notice("[RecentConversationSource] Gathered \(contexts.count) conversations with message content.")

        // Each fragment carries the full condensed content as rawContext for IC processing
        return contexts.enumerated().map { index, ctx in
            BriefFragment(
                sourceID: id,
                title: ctx.title,
                detail: "\(ctx.messageCount) messages — \(ctx.timeAgo)",
                destination: .conversation(id: ctx.conversationID),
                priority: index,
                rawContext: ctx.condensedContent
            )
        }
    }

    // MARK: - Context Extraction

    /// Fetches the most recent conversations and extracts condensed message content.
    private func fetchConversationContexts() async -> [ConversationContext] {
        let context = CoreDataPersistenceService.shared.persistentContainer.viewContext

        return await context.perform {
            // Fetch recent conversations
            let convRequest: NSFetchRequest<ConversationEntity> = ConversationEntity.fetchRequest()
            convRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ConversationEntity.timestamp, ascending: false)]
            convRequest.fetchLimit = self.maxConversations

            guard let conversations = try? context.fetch(convRequest), !conversations.isEmpty else {
                return []
            }

            var results: [ConversationContext] = []

            for convEntity in conversations {
                let conv = convEntity.toConversationStruct()
                guard !conv.messages.isEmpty else { continue }

                // Get the most recent messages (newest first from CoreData, take last N)
                let msgRequest: NSFetchRequest<ChatMessageEntity> = ChatMessageEntity.fetchRequest()
                msgRequest.predicate = NSPredicate(format: "conversationId == %@", conv.id as CVarArg)
                msgRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ChatMessageEntity.timestamp, ascending: false)]
                msgRequest.fetchLimit = self.maxMessagesPerConversation

                let messageEntities = (try? context.fetch(msgRequest)) ?? []
                let messages = messageEntities.reversed().map { $0.toChatMessageStruct() }

                // Build condensed content: role + first 200 chars of each message
                let condensed = messages.compactMap { msg -> String? in
                    guard let text = msg.content.textContent,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return nil
                    }
                    let role = msg.sender == .user ? "User" : "Assistant"
                    let snippet = String(text.prefix(200))
                    return "\(role): \(snippet)"
                }.joined(separator: "\n")

                guard !condensed.isEmpty else { continue }

                results.append(ConversationContext(
                    conversationID: conv.id,
                    title: conv.displayTitle,
                    timeAgo: conv.timestamp.timeAgoDisplay(),
                    messageCount: conv.messages.count,
                    condensedContent: condensed
                ))
            }

            self.logger.debug("[RecentConversationSource] Extracted context from \(results.count) conversations.")
            return results
        }
    }
}

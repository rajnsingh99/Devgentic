//
//  RecentConversationSource.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import SwiftData
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
    @MainActor
    private func fetchConversationContexts() async -> [ConversationContext] {
        guard let context = ChatPersistenceStore.shared.modelContainer?.mainContext else {
            logger.error("[RecentConversationSource] ChatPersistenceStore container not configured.")
            return []
        }

        // Fetch recent conversations
        var convDescriptor = FetchDescriptor<ConversationSD>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        convDescriptor.fetchLimit = self.maxConversations

        guard let conversations = try? context.fetch(convDescriptor), !conversations.isEmpty else {
            return []
        }

        var results: [ConversationContext] = []

        for conversationSD in conversations {
            let conv = conversationSD.toStruct()
            guard !conv.messages.isEmpty else { continue }

            // Get the most recent messages (newest first, take last N)
            let convID = conversationSD.id
            var msgDescriptor = FetchDescriptor<ChatMessageSD>(
                predicate: #Predicate { $0.conversationId == convID },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            msgDescriptor.fetchLimit = self.maxMessagesPerConversation

            let messageModels = (try? context.fetch(msgDescriptor)) ?? []
            let messages = messageModels.reversed().map { $0.toChatMessage() }

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

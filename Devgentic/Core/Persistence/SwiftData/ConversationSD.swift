// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationSD.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData

@Model
final class ConversationSD {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var userDefinedTitle: String?
    var isPinned: Bool
    var backendEntityId: UUID?
    var profileTypeRaw: String?
    /// The project folder a Code conversation runs in, recorded on its first send and fixed afterwards.
    /// Reopened on selection and the key for grouping the Code sidebar; nil for Chat, Workflow and "No project" Code.
    var projectPath: String?

    @Relationship(deleteRule: .cascade, inverse: \ChatMessageSD.conversation)
    var messages: [ChatMessageSD] = []

    /// Workflow execution runs that happened in this conversation. Cascade-deleted
    /// with the conversation. Matches the `messages` pattern above — the to-many
    /// side declares the inverse keypath and the delete rule.
    @Relationship(deleteRule: .cascade, inverse: \WorkflowRunRecordSD.conversation)
    var workflowRuns: [WorkflowRunRecordSD] = []

    init(id: UUID = UUID(), timestamp: Date = Date(), userDefinedTitle: String? = nil,
         isPinned: Bool = false, backendEntityId: UUID? = nil,
         profileTypeRaw: String? = nil, projectPath: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.userDefinedTitle = userDefinedTitle
        self.isPinned = isPinned
        self.backendEntityId = backendEntityId
        self.profileTypeRaw = profileTypeRaw
        self.projectPath = projectPath
    }

    func toStruct() -> Conversation {
        Conversation(
            id: id,
            messages: messages.sorted(by: { $0.timestamp < $1.timestamp }).map { $0.toChatMessage() },
            timestamp: timestamp,
            userDefinedTitle: userDefinedTitle,
            isPinned: isPinned,
            backendEntityId: backendEntityId
        )
    }

    // Why: the full projection decodes four JSON blobs per message,
    // and the sidebar runs it per row on the MainActor on every mid-stream flush.
    /// Row-weight projection for the sidebar: a `Conversation` built without decoding every message.
    /// The title comes from the first message with non-empty text, via the same logic as `Conversation.displayTitle`.
    /// `isStreaming` is false here as in the full projection, since no persisted column backs it.
    func toRowStruct() -> Conversation {
        var probe: ChatMessage?
        let hasUserTitle = !(userDefinedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !hasUserTitle {
            for sd in messages.sorted(by: { $0.timestamp < $1.timestamp }) {
                guard let content = try? JSONDecoder().decode(MessageContent.self, from: sd.contentData) else { continue }
                switch content {
                case .plainText(let text), .markdownText(let text):
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    probe = ChatMessage(
                        conversationId: id,
                        timestamp: sd.timestamp,
                        sender: SenderRole(rawValue: sd.senderType) ?? .user,
                        content: content
                    )
                default:
                    continue
                }
                break
            }
        }
        return Conversation(
            id: id,
            messages: probe.map { [$0] } ?? [],
            timestamp: timestamp,
            userDefinedTitle: userDefinedTitle,
            isPinned: isPinned,
            backendEntityId: backendEntityId
        )
    }
}

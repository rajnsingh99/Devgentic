//
//  ConversationSD.swift
//  Devgentic
//
//  Created by Raj Singh on 03/04/26.
//  SwiftData model replacing ConversationEntity (CoreData).
//

import Foundation
import SwiftData

@Model
final class ConversationSD {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var userDefinedTitle: String?
    var isPinned: Bool
    var openAIThreadID: String?
    var backendType: String?
    var backendEntityId: UUID?
    var profileTypeRaw: String?

    @Relationship(deleteRule: .cascade, inverse: \ChatMessageSD.conversation)
    var messages: [ChatMessageSD] = []

    /// Workflow execution runs that happened in this conversation. Cascade-deleted
    /// with the conversation. Matches the `messages` pattern above — the to-many
    /// side declares the inverse keypath and the delete rule.
    @Relationship(deleteRule: .cascade, inverse: \WorkflowRunRecordSD.conversation)
    var workflowRuns: [WorkflowRunRecordSD] = []

    init(id: UUID = UUID(), timestamp: Date = Date(), userDefinedTitle: String? = nil,
         isPinned: Bool = false, openAIThreadID: String? = nil,
         backendType: String? = nil, backendEntityId: UUID? = nil,
         profileTypeRaw: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.userDefinedTitle = userDefinedTitle
        self.isPinned = isPinned
        self.openAIThreadID = openAIThreadID
        self.backendType = backendType
        self.backendEntityId = backendEntityId
        self.profileTypeRaw = profileTypeRaw
    }

    func toStruct() -> Conversation {
        Conversation(
            id: id,
            messages: messages.sorted(by: { $0.timestamp < $1.timestamp }).map { $0.toChatMessage() },
            timestamp: timestamp,
            userDefinedTitle: userDefinedTitle,
            isPinned: isPinned,
            openAIThreadID: openAIThreadID,
            backendType: backendType.flatMap { BackendType(rawValue: $0) },
            backendEntityId: backendEntityId
        )
    }
}

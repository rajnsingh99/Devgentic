//
//  ChatMessageSD.swift
//  Devgentic
//
//  Created by Raj Singh on 03/04/26.
//  SwiftData model replacing ChatMessageEntity (CoreData).
//

import Foundation
import SwiftData

@Model
final class ChatMessageSD {
    @Attribute(.unique) var id: UUID
    var conversationId: UUID
    var timestamp: Date
    var senderType: String
    var traceID: String?

    // Content stored as JSON Data — no ValueTransformer needed
    var contentData: Data
    var agentResponseData: Data?
    var timelineEventsData: Data?

    var conversation: ConversationSD?

    @Relationship(deleteRule: .cascade)
    var attachedTextFiles: [AttachedTextFileSD] = []

    @Relationship(deleteRule: .cascade)
    var attachedImageFiles: [AttachedImageFileSD] = []

    // MARK: - Mapping

    func toChatMessage() -> ChatMessage {
        let content = (try? JSONDecoder().decode(MessageContent.self, from: contentData))
            ?? .error(title: "Decode Error", details: "Could not decode message content.")

        let message = ChatMessage(
            id: id,
            conversationId: conversationId,
            timestamp: timestamp,
            sender: SenderRole(rawValue: senderType) ?? .user,
            content: content,
            attachedTextFiles: attachedTextFiles.isEmpty ? nil : attachedTextFiles.map { $0.toStruct() },
            attachedImageFiles: attachedImageFiles.isEmpty ? nil : attachedImageFiles.map { $0.toStruct() }
        )

        message.traceID = traceID

        if let data = agentResponseData {
            message.agentResponse = try? JSONDecoder().decode(AgentResponse.self, from: data)
        }

        if let data = timelineEventsData {
            message.timelineEvents = (try? JSONDecoder().decode([TimelineEvent].self, from: data)) ?? []
        }

        return message
    }

    static func from(_ message: ChatMessage) -> ChatMessageSD {
        let contentToEncode = message.currentAgentContent ?? message.content
        let contentData = (try? JSONEncoder().encode(contentToEncode)) ?? Data()
        let agentResponseData = message.agentResponse.flatMap { try? JSONEncoder().encode($0) }
        let timelineEventsData = message.timelineEvents.isEmpty
            ? nil
            : (try? JSONEncoder().encode(message.timelineEvents))

        let sd = ChatMessageSD(
            id: message.id,
            conversationId: message.conversationId,
            timestamp: message.timestamp,
            senderType: message.sender.rawValue,
            traceID: message.traceID,
            contentData: contentData,
            agentResponseData: agentResponseData,
            timelineEventsData: timelineEventsData
        )

        if let textFiles = message.attachedTextFiles {
            sd.attachedTextFiles = textFiles.map { AttachedTextFileSD.from($0) }
        }
        if let imageFiles = message.attachedImageFiles {
            sd.attachedImageFiles = imageFiles.map { AttachedImageFileSD.from($0) }
        }

        return sd
    }

    init(id: UUID, conversationId: UUID, timestamp: Date, senderType: String,
         traceID: String?, contentData: Data, agentResponseData: Data?,
         timelineEventsData: Data?) {
        self.id = id
        self.conversationId = conversationId
        self.timestamp = timestamp
        self.senderType = senderType
        self.traceID = traceID
        self.contentData = contentData
        self.agentResponseData = agentResponseData
        self.timelineEventsData = timelineEventsData
    }
}

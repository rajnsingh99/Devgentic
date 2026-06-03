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
    var profileTypeRaw: String?

    // Content stored as JSON Data — no ValueTransformer needed
    var contentData: Data
    var agentResponseData: Data?
    var timelineEventsData: Data?
    var tokenUsageData: Data?

    /// Terminal outcome of the agent run that produced this message.
    /// Stored as the rawValue of `ExecutionOutcome` so older rows decode as `nil`
    /// when the field didn't exist. Used by `EpisodicHistoryFormatter` to mark
    /// turns with the authoritative status (e.g. circuit-breaker abort) instead
    /// of inferring from action statuses, which mis-classify aborts as "completed"
    /// when all tool calls technically succeeded.
    var terminalOutcomeRaw: String?

    /// Optional human-readable reason accompanying `terminalOutcomeRaw`.
    /// Surfaced as a `<termination>` element in the next turn's episodic XML so
    /// the model gets explicit negative reinforcement after circuit-breaker aborts
    /// or iteration exhaustion, not just an opaque "failed" status.
    var terminalReason: String?

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
        message.profileType = profileTypeRaw.flatMap { ProfileType(rawValue: $0) }

        if let data = agentResponseData {
            message.agentResponse = try? JSONDecoder().decode(AgentResponse.self, from: data)
        }

        if let data = timelineEventsData {
            message.timelineEvents = (try? JSONDecoder().decode([TimelineEvent].self, from: data)) ?? []
        }

        if let data = tokenUsageData {
            message.tokenUsage = try? JSONDecoder().decode(TokenUsage.self, from: data)
        }

        message.terminalOutcome = terminalOutcomeRaw.flatMap { ExecutionOutcome(rawValue: $0) }
        message.terminalReason = terminalReason

        return message
    }

    static func from(_ message: ChatMessage) -> ChatMessageSD {
        let contentToEncode = message.currentAgentContent ?? message.content
        let contentData = (try? JSONEncoder().encode(contentToEncode)) ?? Data()
        let agentResponseData = message.agentResponse.flatMap { try? JSONEncoder().encode($0) }
        let timelineEventsData = message.timelineEvents.isEmpty
            ? nil
            : (try? JSONEncoder().encode(message.timelineEvents))
        let tokenUsageData = message.tokenUsage.flatMap { try? JSONEncoder().encode($0) }

        let sd = ChatMessageSD(
            id: message.id,
            conversationId: message.conversationId,
            timestamp: message.timestamp,
            senderType: message.sender.rawValue,
            traceID: message.traceID,
            profileTypeRaw: message.profileType?.rawValue,
            contentData: contentData,
            agentResponseData: agentResponseData,
            timelineEventsData: timelineEventsData,
            tokenUsageData: tokenUsageData,
            terminalOutcomeRaw: message.terminalOutcome?.rawValue,
            terminalReason: message.terminalReason
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
         traceID: String?, profileTypeRaw: String? = nil, contentData: Data,
         agentResponseData: Data?, timelineEventsData: Data?, tokenUsageData: Data? = nil,
         terminalOutcomeRaw: String? = nil, terminalReason: String? = nil) {
        self.id = id
        self.conversationId = conversationId
        self.timestamp = timestamp
        self.senderType = senderType
        self.traceID = traceID
        self.profileTypeRaw = profileTypeRaw
        self.contentData = contentData
        self.agentResponseData = agentResponseData
        self.timelineEventsData = timelineEventsData
        self.tokenUsageData = tokenUsageData
        self.terminalOutcomeRaw = terminalOutcomeRaw
        self.terminalReason = terminalReason
    }
}

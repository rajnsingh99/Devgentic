//
//  ChatMessageSD.swift
//  Devgentic
//
//  Created by Raj Singh on 03/04/26.
//  SwiftData model replacing ChatMessageEntity (CoreData).
//

import Foundation
import SwiftData

private let logger = DGLogger(category: "ChatMessageSD")

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

    // G1 Piece 1 — lifecycle + run-identity persistence. All optional, so legacy rows
    // (written before these columns existed) decode as nil → `MessageLifecycleState.restore`
    // maps that to `.final`. `parkedOperationID` is the message↔HITL join key for resume.
    var lifecycleStateRaw: String?
    var parkedOperationID: String?
    var apiProvider: String?
    var modelName: String?
    var modelDialect: String?

    var conversation: ConversationSD?

    @Relationship(deleteRule: .cascade)
    var attachedTextFiles: [AttachedTextFileSD] = []

    @Relationship(deleteRule: .cascade)
    var attachedImageFiles: [AttachedImageFileSD] = []

    // MARK: - Mapping

    func toChatMessage() -> ChatMessage {
        // [P6] Blob-decode failures used to degrade SILENTLY: content became a card
        // indistinguishable from an agent error, the timeline vanished, variants and
        // token usage disappeared — with no log line to say the STORE was the problem.
        // Every fallback below now states what was lost. NOTE the standing hazard:
        // a decoded fallback is what gets RE-ENCODED on the next save of this message,
        // overwriting the original (possibly recoverable) bytes — the log is the only
        // trace the original ever existed.
        let content: MessageContent
        do {
            content = try JSONDecoder().decode(MessageContent.self, from: contentData)
        } catch {
            logger.error("[DECODE] Message \(self.id.uuidString.prefix(8)): contentData UNDECODABLE (\(self.contentData.count) bytes, \(error.localizedDescription)) — showing a decode-error card in its place.")
            // Title is pinned by ChatMessageSDTests; details are honest about the cause
            // (deliberately unlocalized — persisted + RAG-fed, must stay stable).
            content = .error(title: "Decode Error", details: "This message's stored content couldn't be read (\(contentData.count) bytes). The rest of the conversation is unaffected.")
        }

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
            do {
                message.agentResponse = try JSONDecoder().decode(AgentResponse.self, from: data)
            } catch {
                logger.warning("[DECODE] Message \(self.id.uuidString.prefix(8)): agentResponseData undecodable (\(data.count) bytes, \(error.localizedDescription)) — response variants lost for this load.")
                // Explicit nil, matching the old `try?` assignment: ChatMessage.init
                // auto-creates a default response for agent messages, and the pinned
                // contract (testCorruptedAgentResponseDataIgnored) is that corrupt
                // stored data yields NO response, not the synthesized default.
                message.agentResponse = nil
            }
        }

        if let data = timelineEventsData {
            do {
                message.timelineEvents = try JSONDecoder().decode([TimelineEvent].self, from: data)
            } catch {
                logger.warning("[DECODE] Message \(self.id.uuidString.prefix(8)): timelineEventsData undecodable (\(data.count) bytes, \(error.localizedDescription)) — the run's timeline renders empty for this load.")
            }
        }

        if let data = tokenUsageData {
            do {
                message.tokenUsage = try JSONDecoder().decode(TokenUsage.self, from: data)
            } catch {
                logger.warning("[DECODE] Message \(self.id.uuidString.prefix(8)): tokenUsageData undecodable (\(data.count) bytes) — usage badge lost for this load.")
            }
        }

        message.terminalOutcome = terminalOutcomeRaw.flatMap { ExecutionOutcome(rawValue: $0) }
        message.terminalReason = terminalReason
        message.lifecycleState = .restore(
            rawKind: lifecycleStateRaw,
            parkedOperationID: parkedOperationID.flatMap { UUID(uuidString: $0) }
        )
        message.apiProvider = apiProvider
        message.modelName = modelName
        message.modelDialect = modelDialect

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
            terminalReason: message.terminalReason,
            lifecycleStateRaw: message.lifecycleState.rawKind,
            parkedOperationID: message.lifecycleState.parkedOperationID?.uuidString,
            apiProvider: message.apiProvider,
            modelName: message.modelName,
            modelDialect: message.modelDialect
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
         terminalOutcomeRaw: String? = nil, terminalReason: String? = nil,
         lifecycleStateRaw: String? = nil, parkedOperationID: String? = nil,
         apiProvider: String? = nil, modelName: String? = nil, modelDialect: String? = nil) {
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
        self.lifecycleStateRaw = lifecycleStateRaw
        self.parkedOperationID = parkedOperationID
        self.apiProvider = apiProvider
        self.modelName = modelName
        self.modelDialect = modelDialect
    }
}

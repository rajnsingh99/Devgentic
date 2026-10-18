// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatMessageSD.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData

private let logger = DGLogger(category: "ChatMessageSD")

@Model
final class ChatMessageSD {
    @Attribute(.unique) var id: UUID
    var conversationId: UUID
    var timestamp: Date

    // Why: SwiftData leaves indexes out of the model's version hash, so an existing store opens fine but never gains the index.
    /// Every hot read is 'this conversation's messages, by time'; the composite index serves the predicate and the sort.
    /// Only stores created by a build that declares it have it.
    #Index<ChatMessageSD>([\.conversationId, \.timestamp])
    var senderType: String
    var traceID: String?
    var profileTypeRaw: String?

    /// The rawValue of `MessageSource`: what caused this turn (typed here, Telegram, scheduler, background task).
    /// Optional so rows written before the column decode as nil, read as `.localUI`.
    var messageSourceRaw: String?

    /// True for a machine-authored stub that exists so the exchange pairs; see `ChatMessage.isSyntheticPrompt`.
    /// Optional so legacy rows decode as nil, read as false.
    var isSyntheticPrompt: Bool?

    // Content stored as JSON Data — no ValueTransformer needed
    var contentData: Data
    var agentResponseData: Data?
    var timelineEventsData: Data?
    var tokenUsageData: Data?

    /// Terminal outcome of the agent run, as the rawValue of `ExecutionOutcome`; nil for older rows.
    /// `EpisodicHistoryFormatter` uses it to mark turns with the authoritative status instead of inferring from action
    /// statuses.
    var terminalOutcomeRaw: String?

    /// Optional human-readable reason accompanying `terminalOutcomeRaw`.
    /// Surfaced as a `<termination>` element in the next turn's episodic XML, e.g. after circuit-breaker aborts.
    var terminalReason: String?

    // Lifecycle and run-identity persistence; all optional, so legacy rows decode as nil, which
    // `MessageLifecycleState.restore` maps to `.final`.
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

    /// - Parameter omittingImageBytes: true builds each attached image without its external-storage `binaryData`
    ///   (name, size, url and extension only). Off by default; only projections that never draw images (export) opt out.
    func toChatMessage(omittingImageBytes: Bool = false) -> ChatMessage {
        // Why: A decoded fallback is re-encoded on the next save and overwrites the original, possibly recoverable, bytes; the log
        // is the only trace.
        // Blob-decode failures are logged, each fallback stating what was lost.
        let content: MessageContent
        var decodeFailurePlaceholder: MessageContent?
        do {
            content = try JSONDecoder().decode(MessageContent.self, from: contentData)
        } catch {
            logger.error(
                "[DECODE] Message \(self.id.uuidString.prefix(8)): contentData UNDECODABLE "
                + "(\(self.contentData.count) bytes) — \(error). CONSEQUENCE: a decode-error card is "
                + "shown in its place, and the stored bytes are now PROTECTED from being overwritten "
                + "by that card; they are preserved for a build that can read them."
            )
            // Title is pinned by tests; details are deliberately unlocalized because they are persisted and fed to RAG.
            content = .error(title: "Decode Error", details: "This message's stored content couldn't be read (\(contentData.count) bytes). The rest of the conversation is unaffected.")
            decodeFailurePlaceholder = content
        }

        let message = ChatMessage(
            id: id,
            conversationId: conversationId,
            timestamp: timestamp,
            sender: SenderRole(rawValue: senderType) ?? .user,
            content: content,
            attachedTextFiles: attachedTextFiles.isEmpty ? nil : attachedTextFiles.map { $0.toStruct() },
            attachedImageFiles: attachedImageFiles.isEmpty ? nil : attachedImageFiles.map {
                omittingImageBytes ? $0.toStructOmittingBytes() : $0.toStruct()
            }
        )
        // Marks the message so neither writer can replace the unreadable bytes with the card.
        message.undecodableContentPlaceholder = decodeFailurePlaceholder

        message.traceID = traceID
        message.profileType = profileTypeRaw.flatMap { ProfileType(rawValue: $0) }
        // `?? .localUI` states that an unreadable or absent source is read as local, so a renamed `MessageSource` case degrades
        // to 'typed here' instead of crashing.
        message.messageSource = messageSourceRaw.flatMap { MessageSource(rawValue: $0) } ?? .localUI
        message.isSyntheticPrompt = isSyntheticPrompt ?? false

        if let data = agentResponseData {
            do {
                message.agentResponse = try JSONDecoder().decode(AgentResponse.self, from: data)
            } catch {
                // Marking the message is required: writers persist `agentResponse` as-is, so without the flag the next flush would
                // replace the stored bytes with NULL and lose the variants permanently.
                message.agentResponseDecodeFailed = true
                logger.error(
                    "[PERSISTENCE] [DECODE] Message \(self.id.uuidString.prefix(8)): agentResponseData "
                    + "UNDECODABLE (\(data.count) bytes) — \(error.localizedDescription). "
                    + "CONSEQUENCE: this message's response variants do not render on this load, and "
                    + "the stored bytes are now PROTECTED from being nulled by that empty state; they "
                    + "are preserved for a build that can read them."
                )
                // Explicit nil: `ChatMessage.init` auto-creates a default response for agent messages, but corrupt stored data yields
                // none.
                message.agentResponse = nil
            }
        }

        if let data = timelineEventsData {
            do {
                message.timelineEvents = try Self.decodeTimeline(from: data)
            } catch {
                // Marking the message is required: both writers null this column when the in-memory timeline is empty,
                // so without the flag the next flush would permanently erase the timeline.
                message.timelineDecodeFailed = true
                logger.error(
                    "[DECODE] Message \(self.id.uuidString.prefix(8)): timelineEventsData undecodable "
                    + "(\(data.count) bytes) — \(error). CONSEQUENCE: the run's timeline renders empty "
                    + "for this load, and the stored bytes are now PROTECTED from being overwritten "
                    + "by the empty value; they are preserved for a future build that can read them."
                )
            }
        }

        if let data = tokenUsageData {
            do {
                message.tokenUsage = try JSONDecoder().decode(TokenUsage.self, from: data)
            } catch {
                // Marked so neither writer turns the nil this produces into a NULL column.
                message.tokenUsageDecodeFailed = true
                logger.error(
                    "[PERSISTENCE] [DECODE] Message \(self.id.uuidString.prefix(8)): tokenUsageData "
                    + "UNDECODABLE (\(data.count) bytes) — \(error.localizedDescription). CONSEQUENCE: "
                    + "the usage badge and this message's share of the conversation's token and cost "
                    + "totals are missing on this load; the stored bytes are PROTECTED from being "
                    + "nulled by that empty state and kept for a build that can read them."
                )
            }
        }

        message.terminalOutcome = terminalOutcomeRaw.flatMap { ExecutionOutcome(rawValue: $0) }
        message.terminalReason = terminalReason
        message.lifecycleState = .restore(
            rawKind: lifecycleStateRaw,
            parkedOperationID: parkedOperationID.flatMap { UUID(uuidString: $0) }
        )

        // Why: Closing a parked run's dangling row would make a resumable park permanently unresumable.
        // Settles tool rows a crash or force-quit left `isExecuting == true`; decode is the one place every reader goes through.
        // `.streaming` only, not `isInterrupted`: a `.parkedHITL` run's dangling row identifies the parked tool for `resumeRun`.
        if case .streaming = message.lifecycleState {
            let stopped = DanglingToolRowCloser.markInterruptedByProcessDeath(&message.timelineEvents)
            if stopped > 0 {
                logger.warning("[DECODE] Message \(self.id.uuidString.prefix(8)): stopped \(stopped) spinning tool row(s) on a message persisted mid-stream (the app was force-quit or crashed before finalize). CONSEQUENCE: those rows stop animating; they keep no output and no verdict, because the tool's fate is genuinely unknown — which also keeps the resume engine able to recognise and drop them. A parked-HITL message is deliberately left alone so its Resume can still re-raise the tool.")
            }
        }
        message.apiProvider = apiProvider
        message.modelName = modelName
        message.modelDialect = modelDialect

        return message
    }

    // Why: Bump whenever `MessageContent`'s on-disk shape changes, so a reader can ask what it holds rather than guess.
    /// Current persisted shape of `contentData`: hand-written codec keyed on `type`, with `.unknown` preserving
    /// unrecognised cases.
    static let contentBlobVersion = 1

    /// Current persisted shape of `agentResponseData` (object root, inline key).
    /// Bump on any change to `AgentResponse` / `ResponseMessageVariant`'s persisted shape.
    static let agentResponseBlobVersion = 1

    /// Current persisted shape of `tokenUsageData` (`TokenUsage` → object root, inline key).
    static let tokenUsageBlobVersion = 1

    /// Current persisted shape of `timelineEventsData`: a versioned envelope, since a bare array has nowhere for a version
    /// key.
    /// The reader keeps accepting a bare array, because a row is only rewritten when its message is touched.
    static let timelineBlobVersion = 1

    /// Encodes message content, never emitting an empty blob.
    /// On an encode failure it falls back to a readable error: empty `Data` is itself undecodable and would turn a
    /// transient failure permanent.
    static func encodeContent(_ content: MessageContent, messageID: UUID) -> Data {
        do {
            // Stamped, not wrapped: `MessageContent` encodes to an object, so the version rides as a sibling key
            // and no type gains a `schemaVersion` property that a synthesized decoder would demand.
            return BlobVersioning.stamped(try JSONEncoder().encode(content), version: contentBlobVersion)
        } catch {
            logger.error(
                "[PERSISTENCE] Message \(messageID.uuidString.prefix(8)): content failed to ENCODE — "
                + "\(error). CONSEQUENCE: a readable error card is stored in its place rather than an "
                + "empty blob, which would have been undecodable on the next load."
            )
            let fallback = MessageContent.error(
                title: "Save Error",
                details: "This message's content could not be saved by this version of Devgentic."
            )
            // If even THAT fails the type system is beyond saving; an empty blob is the last resort
            // and is at least logged above.
            return (try? JSONEncoder().encode(fallback)) ?? Data()
        }
    }

    // Why: Distinguishes 'legitimately nil' from 'encoding threw'; collapsing them on an UPDATE sets the column to NULL and
    // loses good bytes.
    /// What to do with an optional auxiliary blob column after encoding its value.
    enum AuxiliaryBlobEncoding: Equatable {
        /// Encode succeeded, or the value really was nil. Safe to assign.
        case write(Data?)
        /// Encode threw. The caller MUST leave the column untouched.
        case preserveExisting

        // Why: Never use on an UPDATE: that is the collapse this enum exists to stop.
        /// The value to assign on an INSERT, where there is nothing to preserve.
        var dataToWrite: Data? {
            switch self {
            case .write(let data):   return data
            case .preserveExisting:  return nil
            }
        }
    }

    // Why: An empty timeline is deliberately stored as NULL; `canPersistTimeline` is built on that meaning.
    /// Wraps the timeline for persistence, or nil when there is nothing to write.
    static func wrappedTimeline(_ events: [TimelineEvent]) -> VersionedBlob<[TimelineEvent]>? {
        guard !events.isEmpty else { return nil }
        return VersionedBlob(schemaVersion: timelineBlobVersion, payload: events)
    }

    /// Reads the timeline envelope. Throws on any other shape, so the caller's catch classifies it
    /// as a real read failure rather than silently returning an empty timeline (which the writers
    /// would then persist).
    static func decodeTimeline(from data: Data) throws -> [TimelineEvent] {
        try JSONDecoder().decode(VersionedBlob<[TimelineEvent]>.self, from: data).payload
    }

    /// Encodes one of the optional auxiliary blobs, reporting an encode failure instead of laundering it into nil.
    /// - Parameter version: stamped into the blob so a reader can ask what shape it holds; object roots get an inline key.
    /// Array-rooted columns wrap their payload in `VersionedBlob` first, which makes the stamp an idempotent no-op.
    static func encodeAuxiliaryBlob<T: Encodable>(
        _ value: T?,
        column: String,
        messageID: UUID,
        version: Int
    ) -> AuxiliaryBlobEncoding {
        guard let value else { return .write(nil) }
        do {
            return .write(BlobVersioning.stamped(try JSONEncoder().encode(value), version: version))
        } catch {
            logger.error(
                "[PERSISTENCE] Message \(messageID.uuidString.prefix(8)): \(column) failed to ENCODE "
                + "— \(error). CONSEQUENCE: the column is left exactly as it was rather than being "
                + "nulled, so any previously-stored value survives; the newest in-memory value is not "
                + "on disk and will be missing after a reload until a later flush encodes cleanly."
            )
            return .preserveExisting
        }
    }

    static func from(_ message: ChatMessage) -> ChatMessageSD {
        let contentToEncode = message.currentAgentContent ?? message.content
        // Never emit an empty blob: on an encode failure fall back to a readable error, since empty data is undecodable.
        let contentData = Self.encodeContent(contentToEncode, messageID: message.id)
        // On a fresh INSERT there are no prior bytes, but routing through the helper still logs a failure.
        // `canPersistAgentResponse` also applies: this path is reached for messages rebuilt from a load.
        let agentResponseData: Data? = message.canPersistAgentResponse
            ? Self.encodeAuxiliaryBlob(
                message.agentResponse, column: "agentResponseData", messageID: message.id,
                version: Self.agentResponseBlobVersion
              ).dataToWrite
            : nil
        // `canPersistTimeline` is false only when the timeline is empty because the stored blob could not be decoded;
        // honoured here too since this path is reached for messages rebuilt from a load.
        let timelineEventsData: Data? = message.canPersistTimeline
            ? Self.encodeAuxiliaryBlob(
                Self.wrappedTimeline(message.timelineEvents),
                column: "timelineEventsData", messageID: message.id,
                version: Self.timelineBlobVersion
              ).dataToWrite
            : nil
        // `canPersistTokenUsage`, for the same rebuilt-from-a-load reason as the two above.
        let tokenUsageData: Data? = message.canPersistTokenUsage
            ? Self.encodeAuxiliaryBlob(
                message.tokenUsage, column: "tokenUsageData", messageID: message.id,
                version: Self.tokenUsageBlobVersion
              ).dataToWrite
            : nil

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
            modelDialect: message.modelDialect,
            messageSourceRaw: message.messageSource.rawValue,
            isSyntheticPrompt: message.isSyntheticPrompt
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
         apiProvider: String? = nil, modelName: String? = nil, modelDialect: String? = nil,
         messageSourceRaw: String? = nil, isSyntheticPrompt: Bool? = nil) {
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
        self.messageSourceRaw = messageSourceRaw
        self.isSyntheticPrompt = isSyntheticPrompt
    }
}

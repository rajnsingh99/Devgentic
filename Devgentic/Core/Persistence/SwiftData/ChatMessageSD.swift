// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

    /// - Parameter omittingImageBytes: [mm-4] true to build each attached image WITHOUT its
    ///   external-storage `binaryData` (name, size, url and extension only). Every other field
    ///   decodes exactly as before. Off by default: the transcript renders images from these
    ///   bytes; only projections that never draw them (export) opt out.
    func toChatMessage(omittingImageBytes: Bool = false) -> ChatMessage {
        // [P6] Blob-decode failures used to degrade SILENTLY: content became a card
        // indistinguishable from an agent error, the timeline vanished, variants and
        // token usage disappeared — with no log line to say the STORE was the problem.
        // Every fallback below now states what was lost. NOTE the standing hazard:
        // a decoded fallback is what gets RE-ENCODED on the next save of this message,
        // overwriting the original (possibly recoverable) bytes — the log is the only
        // trace the original ever existed.
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
            // Title is pinned by ChatMessageSDTests; details are honest about the cause
            // (deliberately unlocalized — persisted + RAG-fed, must stay stable).
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

        if let data = agentResponseData {
            do {
                message.agentResponse = try JSONDecoder().decode(AgentResponse.self, from: data)
            } catch {
                // ⚠️ Marking the message is not cosmetic — same reasoning as the timeline below.
                // The writers persist `agentResponse` as-is, and nil is what this branch produces,
                // so WITHOUT the flag the next flush of the enclosing conversation replaced the
                // stored bytes with NULL and the variants were gone permanently rather than merely
                // unrendered for this load.
                message.agentResponseDecodeFailed = true
                logger.error(
                    "[PERSISTENCE] [DECODE] Message \(self.id.uuidString.prefix(8)): agentResponseData "
                    + "UNDECODABLE (\(data.count) bytes) — \(error.localizedDescription). "
                    + "CONSEQUENCE: this message's response variants do not render on this load, and "
                    + "the stored bytes are now PROTECTED from being nulled by that empty state; they "
                    + "are preserved for a build that can read them."
                )
                // Explicit nil, matching the old `try?` assignment: ChatMessage.init
                // auto-creates a default response for agent messages, and the pinned
                // contract (testCorruptedAgentResponseDataIgnored) is that corrupt
                // stored data yields NO response, not the synthesized default.
                message.agentResponse = nil
            }
        }

        if let data = timelineEventsData {
            do {
                message.timelineEvents = try Self.decodeTimeline(from: data)
            } catch {
                // ⚠️ Marking the message is not cosmetic. Both writers null this column whenever the
                // in-memory timeline is empty, so WITHOUT this flag the next flush of the enclosing
                // conversation would replace the bytes with nil and the run's whole timeline would
                // be gone — not just unrendered. The previous wording here ("renders empty for this
                // load") understated that: the loss was permanent from the next save.
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
                logger.warning("[DECODE] Message \(self.id.uuidString.prefix(8)): tokenUsageData undecodable (\(data.count) bytes) — usage badge lost for this load.")
            }
        }

        message.terminalOutcome = terminalOutcomeRaw.flatMap { ExecutionOutcome(rawValue: $0) }
        message.terminalReason = terminalReason
        message.lifecycleState = .restore(
            rawKind: lifecycleStateRaw,
            parkedOperationID: parkedOperationID.flatMap { UUID(uuidString: $0) }
        )

        // [CF-44] Settle tool rows the process never got to close.
        //
        // `flushInFlight` persists the in-flight message at every tool boundary, so a crash or
        // force-quit mid-tool leaves `isExecuting == true` on disk. The only repair was
        // `closeDanglingToolRows`, whose sole caller is `ActiveStreamManager.finalizeMessage` —
        // a path a force-quit never reaches — so the row rendered an animating spinner forever,
        // with no output, no failure badge, and permanently non-disclosable (`isDisclosable`
        // requires `!isExecuting`). Decode is the one place every reader goes through.
        //
        // ⚠️ `.streaming` ONLY — deliberately NOT `lifecycleState.isInterrupted`, which is also
        // true for `.parkedHITL`. A parked run's dangling row is LOAD-BEARING: `resumeRun` calls
        // `TimelineTurnReconstructor.reconstruct`, which identifies the parked tool by exactly
        // `data.isExecuting || data.output == nil` and hands it back as `parkedTool`; resume then
        // REFUSES ("The interrupted state is incomplete and can't be resumed") when that is nil.
        // Closing the row here would therefore turn a resumable park into a permanently
        // unresumable one — strictly worse than the spinner this fixes. A `.streaming` resume
        // passes `dropDanglingTool: true` and wants the row gone, so closing it changes nothing
        // it depends on.
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

    /// Current persisted shape of `contentData`.
    ///
    /// ⚠️ BUMP THIS whenever `MessageContent`'s on-disk shape changes — a renamed key, a
    /// restructured case payload, a changed discriminator. That is what lets a future reader ASK
    /// what it is holding instead of trying shapes until one decodes (G19). A guess that succeeds
    /// incorrectly is silent data loss, and JSON decoding succeeds incorrectly all the time.
    ///
    /// Version 1 = the shape as of 2026-08-05: hand-written codec keyed on `type`, with
    /// `.unknown(type:payload:)` preserving anything it does not recognise.
    static let contentBlobVersion = 1

    /// Current persisted shape of `agentResponseData` (`AgentResponse` → object root, inline key).
    /// ⚠️ Bump on any change to `AgentResponse` / `ResponseMessageVariant`'s persisted shape.
    static let agentResponseBlobVersion = 1

    /// Current persisted shape of `tokenUsageData` (`TokenUsage` → object root, inline key).
    static let tokenUsageBlobVersion = 1

    /// Current persisted shape of `timelineEventsData`.
    ///
    /// ⚠️ ENVELOPE, not an inline key: the payload is a bare `[TimelineEvent]` ARRAY, and an array has
    /// nowhere to put a sibling key. Written as `VersionedBlob<[TimelineEvent]>`; the reader must keep
    /// accepting a bare array for as long as unwrapped rows can exist — which is indefinitely, since a
    /// row is only rewritten when its message is touched.
    static let timelineBlobVersion = 1

    /// Encodes message content, never emitting an empty blob.
    ///
    /// ⚠️ The previous `(try? encode(x)) ?? Data()` turned a transient ENCODE failure into a
    /// PERMANENT one: empty `Data` is itself undecodable, so the next load produced a Decode Error
    /// card. Falling back to a readable error keeps the row legible and says what happened.
    static func encodeContent(_ content: MessageContent, messageID: UUID) -> Data {
        do {
            // Stamped, not wrapped: `MessageContent` encodes to an OBJECT, so the version rides as a
            // sibling key. The blob keeps its shape, every existing reader still parses it, and no
            // type gains a `schemaVersion` property (which would be the G13 trap — a synthesized
            // decoder demands the key and every already-persisted blob would throw `keyNotFound`).
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

    /// What to do with an optional auxiliary blob column after trying to encode its value.
    ///
    /// ⚠️ Exists to distinguish "this value is legitimately nil" from "encoding THREW", which
    /// `try? JSONEncoder().encode(x)` collapses into the same `nil`. On an UPDATE that collapse is
    /// data loss: the column is set to NULL and the previously-good bytes are gone, silently.
    enum AuxiliaryBlobEncoding: Equatable {
        /// Encode succeeded, or the value really was nil. Safe to assign.
        case write(Data?)
        /// Encode threw. The caller MUST leave the column untouched.
        case preserveExisting

        /// The value to assign on an INSERT, where there is nothing to preserve either way.
        /// ⚠️ Never use this on an UPDATE — that is precisely the collapse this enum exists to stop.
        var dataToWrite: Data? {
            switch self {
            case .write(let data):   return data
            case .preserveExisting:  return nil
            }
        }
    }

    /// Encodes one of the optional auxiliary blobs (`agentResponse`, `tokenUsage`, `timelineEvents`),
    /// reporting an encode failure instead of laundering it into `nil`.
    ///
    /// The read side of these columns is already guarded (`canPersistContent`, `canPersistTimeline`);
    /// this closes the matching write side, which was still `try?` → `nil` (G21).
    /// Wraps the timeline for persistence, or nil when there is nothing to write.
    ///
    /// ⚠️ The empty→nil collapse is deliberate and pre-existing: an empty timeline is stored as NULL,
    /// not as an empty array. Keep it — `canPersistTimeline` is built on exactly that meaning.
    static func wrappedTimeline(_ events: [TimelineEvent]) -> VersionedBlob<[TimelineEvent]>? {
        guard !events.isEmpty else { return nil }
        return VersionedBlob(schemaVersion: timelineBlobVersion, payload: events)
    }

    /// Reads the timeline from either shape.
    ///
    /// ⚠️ The bare-array fallback is load-bearing, not defensive. Every timeline row written before
    /// 2026-08-05 is a bare array, and a row is only rewritten when its message is touched — so
    /// unwrapped blobs persist indefinitely. Dropping this path would erase them.
    static func decodeTimeline(from data: Data) throws -> [TimelineEvent] {
        if let result = VersionedBlob<[TimelineEvent]>.decode(from: data) { return result.payload }
        // Neither shape decoded — let the caller's catch classify it as a real read failure rather
        // than silently returning an empty timeline (which the writers would then persist).
        return try JSONDecoder().decode([TimelineEvent].self, from: data)
    }

    /// - Parameter version: stamped into the encoded blob (G19) so a future reader can ASK what shape
    ///   it is holding rather than trying shapes until one decodes. Object roots get an inline key;
    ///   non-object roots pass through untouched, which is why array-rooted columns wrap their
    ///   payload in `VersionedBlob` BEFORE calling this — the wrapper is itself an object, and its
    ///   `schemaVersion` makes the stamp below an idempotent no-op.
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
        // ⚠️ The old `?? Data()` wrote an EMPTY blob when encoding failed — which is itself
        // undecodable, so it turned a transient encode failure into a permanent Decode Error card.
        // Fall back to a readable error instead, and never emit empty.
        let contentData = Self.encodeContent(contentToEncode, messageID: message.id)
        // On a fresh INSERT there are no prior bytes, so `.preserveExisting` and `.write(nil)` both
        // mean "leave it null" — but routing through the helper still gets the failure LOGGED, which
        // the bare `try?` never did.
        //
        // `canPersistAgentResponse` is honoured here too: this path is also reached for messages
        // REBUILT from a load, where an unreadable response blob must not be written back as nil.
        let agentResponseData: Data? = message.canPersistAgentResponse
            ? Self.encodeAuxiliaryBlob(
                message.agentResponse, column: "agentResponseData", messageID: message.id,
                version: Self.agentResponseBlobVersion
              ).dataToWrite
            : nil
        // `canPersistTimeline` is false only when the timeline is empty BECAUSE the stored blob
        // could not be decoded. On a fresh insert there is nothing to protect, but this path is
        // also reached for messages rebuilt from a load, so honour it here too.
        let timelineEventsData: Data? = message.canPersistTimeline
            ? Self.encodeAuxiliaryBlob(
                Self.wrappedTimeline(message.timelineEvents),
                column: "timelineEventsData", messageID: message.id,
                version: Self.timelineBlobVersion
              ).dataToWrite
            : nil
        let tokenUsageData = Self.encodeAuxiliaryBlob(
            message.tokenUsage, column: "tokenUsageData", messageID: message.id,
            version: Self.tokenUsageBlobVersion
        ).dataToWrite

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

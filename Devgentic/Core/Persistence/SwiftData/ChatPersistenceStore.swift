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

private let logger = DGLogger(category: "ChatPersistenceStore")

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
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String)
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

    /// [P4] Last `ChatMessage.timelineRevision` whose timeline blob was encoded, per
    /// message — lets the streaming flush skip re-encoding an unchanged timeline.
    /// Bounded: pruned wholesale past 512 entries (worst case after a prune is ONE
    /// redundant encode per live message, never a missed write).
    private var lastEncodedTimelineRevision: [UUID: UInt64] = [:]

    /// [IMG-PERSIST] Per-message count of upserts that carried image attachments. Purely
    /// diagnostic: a value > 1 means an image-bearing row was re-persisted — the delete+
    /// reinsert `@Attribute(.externalStorage)` clone hazard path (a second upsert is the
    /// ONLY way `reconcileAttachmentChildren`'s delete/insert arms run for an image row).
    /// Pruned wholesale alongside the timeline skip-cache below.
    private var imageUpsertCounts: [UUID: Int] = [:]

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

        // [P4] Bound the skip cache — a wholesale prune costs at most one redundant
        // encode per live message afterwards, never a missed write.
        if lastEncodedTimelineRevision.count > 512 {
            logger.debug("[P4] Timeline-revision skip cache pruned (\(self.lastEncodedTimelineRevision.count) entries).")
            lastEncodedTimelineRevision.removeAll(keepingCapacity: true)
            // Same bound for the diagnostic image-upsert counter — after a prune the worst
            // case is one image row's count restarting at 1, i.e. a missed "SECOND+" warning,
            // never a wrong persist.
            imageUpsertCounts.removeAll(keepingCapacity: true)
        }

        let conversation = getConversation(withId: conversationId)

        for message in messages {
            // Upsert: check if message already exists
            let messageId = message.id
            var descriptor = FetchDescriptor<ChatMessageSD>(
                predicate: #Predicate { $0.id == messageId }
            )
            descriptor.fetchLimit = 1

            let existing = try? context.fetch(descriptor).first

            // [IMG-PERSIST] Decisive branch/count/bytes trace for image-bearing rows. An
            // image blob is the schema's only `@Attribute(.externalStorage)` attribute, so it
            // is the sole thing that can raise "Failed to clone external data reference …
            // .interim doesn't exist". This line lets an on-device run prove INSERT-vs-UPDATE
            // for the image write and catch any (unexpected) SECOND upsert of an image row —
            // the only path by which the delete+reinsert clone hazard could re-appear.
            if let images = message.attachedImageFiles, !images.isEmpty {
                imageUpsertCounts[messageId, default: 0] += 1
                let upsertNo = imageUpsertCounts[messageId] ?? 1
                let bytes = images.reduce(0) { $0 + $1.binaryData.count }
                let ids = images.map { $0.id.uuidString.prefix(8) }.joined(separator: ",")
                logger.info("[IMG-PERSIST] \(existing == nil ? "INSERT" : "UPDATE") msg=\(messageId.uuidString.prefix(8)) conv=\(conversationId.uuidString.prefix(8)) sender=\(message.sender.rawValue) images=\(images.count) bytes=\(bytes) ids=[\(ids)] upsert#=\(upsertNo)")
                if upsertNo > 1 {
                    logger.warning("[IMG-PERSIST] msg=\(messageId.uuidString.prefix(8)) upserted \(upsertNo)× while carrying images (branch=\(existing == nil ? "INSERT" : "UPDATE")) — the delete+reinsert external-clone hazard path; reconcile must SKIP the blob rewrite when the id set is unchanged.")
                }
            }

            if let existing {
                // Update existing message in-place
                let contentToEncode = message.currentAgentContent ?? message.content
                existing.contentData = (try? JSONEncoder().encode(contentToEncode)) ?? Data()
                existing.agentResponseData = message.agentResponse.flatMap { try? JSONEncoder().encode($0) }
                // [P4] The timeline is the heavyweight blob (up to 500 events) and it
                // changes far less often than content — yet every in-flight flush
                // (~2s during streaming) re-encoded ALL of it on the MainActor,
                // quadratic over a run. Skip when the revision says nothing changed;
                // the random per-instance seed makes cross-instance aliasing (reload,
                // regenerate) impossible, so a real change can never be skipped.
                if lastEncodedTimelineRevision[messageId] != message.timelineRevision {
                    existing.timelineEventsData = message.timelineEvents.isEmpty
                        ? nil
                        : (try? JSONEncoder().encode(message.timelineEvents))
                    lastEncodedTimelineRevision[messageId] = message.timelineRevision
                }
                existing.traceID = message.traceID
                existing.senderType = message.sender.rawValue
                // Terminal status — set late in the run by the executor's `.executionFinished`
                // event, so almost every persistence write here happens AFTER the field is
                // populated. Update on every upsert to keep disk in sync with the in-memory
                // ChatMessage that ActiveStreamManager mutates.
                existing.terminalOutcomeRaw = message.terminalOutcome?.rawValue
                existing.terminalReason = message.terminalReason

                // [P2] `.tokenUsage` arrives at end-of-stream, AFTER the first in-flight
                // flush has already INSERTed the row — so finalize always lands on this
                // UPDATE branch. Without this line the badge and conversation totals were
                // visible live but gone on every reload (INSERT was the only writer).
                existing.tokenUsageData = message.tokenUsage.flatMap { try? JSONEncoder().encode($0) }

                // [G1] Resume lifecycle + run-identity stamp. `ChatMessageSD.from` writes these on
                // first INSERT, but the in-flight flush path upserts an already-inserted row: the
                // `.toolCall` flush creates the row as `.streaming` BEFORE the HITL park can stamp
                // `.parkedHITL`, so they must be re-applied on every UPDATE too — otherwise the
                // parked marker + operationID never reach disk and a parked run wrongly reloads as
                // `.streaming` and resumes via the drop-dangling path instead of re-raising the HITL.
                existing.lifecycleStateRaw = message.lifecycleState.rawKind
                existing.parkedOperationID = message.lifecycleState.parkedOperationID?.uuidString
                existing.apiProvider = message.apiProvider
                existing.modelName = message.modelName
                existing.modelDialect = message.modelDialect

                // [IMG-PERSIST] Reconcile attachment children IN PLACE by id instead of the
                // old delete-then-recreate. For image rows that anti-pattern re-cloned an
                // immutable `@Attribute(.externalStorage)` blob on every upsert (needless
                // MB-scale I/O) and staged the SAME content-addressed external file for a
                // double-unlink (explicit `context.delete` + `.cascade` orphan) while a
                // re-insert tried to clone it back from a `.interim` the same save had
                // already removed — the intermittent "Failed to clone external data reference
                // … .interim doesn't exist" signature. Kept ids keep their existing row (and
                // its blob) untouched; only removed ids are deleted and only genuinely-new ids
                // inserted. A no-op when the id set is unchanged — which is every case today:
                // the agent finalize/flush re-upserts carry no images, and no path re-persists
                // an image-bearing row. `nil` return means "unchanged — do not touch the
                // relationship" so the external blob is never re-marked dirty.
                if let reconciledText = reconcileAttachmentChildren(
                    existing: existing.attachedTextFiles,
                    incoming: message.attachedTextFiles ?? [],
                    incomingID: { $0.id }, existingID: { $0.id },
                    make: { AttachedTextFileSD.from($0) },
                    context: context, kind: "textFiles", messageID: messageId
                ) {
                    existing.attachedTextFiles = reconciledText
                }

                if let reconciledImages = reconcileAttachmentChildren(
                    existing: existing.attachedImageFiles,
                    incoming: message.attachedImageFiles ?? [],
                    incomingID: { $0.id }, existingID: { $0.id },
                    make: { AttachedImageFileSD.from($0) },
                    context: context, kind: "imageFiles", messageID: messageId
                ) {
                    existing.attachedImageFiles = reconciledImages
                }
            } else {
                // Insert new message
                let sd = ChatMessageSD.from(message)
                sd.conversation = conversation
                context.insert(sd)
                conversation?.messages.append(sd)
                // [P4] `ChatMessageSD.from` just encoded this revision's timeline.
                lastEncodedTimelineRevision[messageId] = message.timelineRevision
            }
        }

        // Update conversation timestamp
        conversation?.timestamp = Date()
        saveContext()
        logger.debug("Upserted \(messages.count) messages for conversation \(conversationId.uuidString).")

        // [Conversation memory] Index USER turns here — the one persistence funnel
        // every surface flows through (main chat, ChatOps, QuickAccess, scheduler) —
        // replacing per-coordinator hooks that missed the latter two surfaces.
        // Assistant turns are indexed in ActiveStreamManager.finalizeMessage once
        // streaming finishes (this upsert also runs mid-stream with partial
        // content, hence the sender filter). Re-adds (resume/replay/restore) are
        // idempotent: replace-on-reindex keys off the message id. Fire-and-forget —
        // persistence never waits on chunking/embedding.
        let userMessages = messages.filter { $0.sender == .user }
        if !userMessages.isEmpty {
            Task.detached(priority: .background) {
                for message in userMessages {
                    await RAGIndexingService.shared.indexSingleMessage(message)
                }
            }
        }
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

    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {
        guard let conversation = getConversation(withId: conversationId) else {
            logger.warning("Attempted to update profileType for non-existent conversation: \(conversationId.uuidString)")
            return
        }
        conversation.profileTypeRaw = profileTypeRaw
        saveContext()
        logger.info("Updated conversation \(conversationId.uuidString) with profileType: \(profileTypeRaw).")
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

    /// [IMG-PERSIST] Reconcile a to-many attachment relationship in place by id, replacing the
    /// legacy delete-then-recreate that re-cloned an immutable `@Attribute(.externalStorage)`
    /// image blob on every upsert (and staged the same external file for a double-unlink).
    ///
    /// - Returns `nil` when the incoming id set equals the existing id set — the caller must then
    ///   leave the relationship untouched, so an unchanged external blob is never re-marked dirty
    ///   (CoreData dirties a property on ASSIGNMENT, not on value change, and a dirtied external
    ///   attribute triggers a full interim→clone→promote cycle — precisely the race we're killing).
    /// - Otherwise deletes only the rows whose id vanished from `incoming`, reuses every existing
    ///   row whose id survives (its stored blob is kept verbatim — image bytes are immutable per
    ///   id), inserts only genuinely-new ids, and returns the array to assign.
    ///
    /// Correct for all three required cases: add an image (superset → insert new, keep prior),
    /// remove an image (subset → delete gone, keep rest), and image-free agent re-upserts
    /// (both sets empty → `nil`, total no-op).
    private func reconcileAttachmentChildren<SD: PersistentModel, Model>(
        existing: [SD],
        incoming: [Model],
        incomingID: (Model) -> UUID,
        existingID: (SD) -> UUID,
        make: (Model) -> SD,
        context: ModelContext,
        kind: String,
        messageID: UUID
    ) -> [SD]? {
        let incomingIDs = Set(incoming.map(incomingID))
        let existingIDs = Set(existing.map(existingID))

        guard incomingIDs != existingIDs else {
            if !incomingIDs.isEmpty {
                logger.debug("[IMG-PERSIST] \(kind) id set unchanged (\(incomingIDs.count)) for msg \(messageID.uuidString.prefix(8)) — SKIP rewrite; external blob(s) left untouched.")
            }
            return nil
        }

        let existingByID = Dictionary(existing.map { (existingID($0), $0) }, uniquingKeysWith: { first, _ in first })
        var deleted = 0
        for old in existing where !incomingIDs.contains(existingID(old)) {
            context.delete(old)
            deleted += 1
        }
        // Reuse the existing SD row for surviving ids (blob untouched); build fresh only for new ids.
        let reconciled = incoming.map { existingByID[incomingID($0)] ?? make($0) }
        let inserted = incomingIDs.subtracting(existingIDs).count
        logger.info("[IMG-PERSIST] \(kind) reconciled for msg \(messageID.uuidString.prefix(8)) — existing=\(existing.count) incoming=\(incoming.count) inserted=\(inserted) deleted=\(deleted) kept=\(existing.count - deleted).")
        return reconciled
    }

    private func saveContext() {
        guard let context = mainContext else { return }
        do {
            try context.save()
        } catch {
            logger.error("Failed to save chat context: \(error.localizedDescription)")
        }
    }
}

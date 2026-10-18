// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatPersistenceStore.swift
//  Devgentic
//
//  Created by Raj Singh.
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
    // Why: a protocol requirement, not an extension default: `BackendHistoryResolver` holds the protocol type.
    /// Returns the newest `limit` messages, newest-first, for model context, decoded off the main actor.
    /// `omittingImageBytes` keeps each image's name, extension and size but not its bytes (for callers that only count).
    func fetchContextHistory(for conversationId: UUID, limit: Int, omittingImageBytes: Bool) async -> [ChatMessage]
    /// Saves a rename or first-message title through the store.
    /// Requirements rather than extension methods, for the same dispatch reason as `fetchContextHistory`.
    func setTitle(_ title: String?, for conversationId: UUID)
    func setTitleIfUntitled(_ title: String, for conversationId: UUID)
    func deleteConversation(with id: UUID)
    func updateBackendForConversation(id: UUID, backendEntityId: UUID?)
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String)
    /// Records the project folder a Code conversation runs in. See `ConversationSD.projectPath`.
    func updateProjectPath(for conversationId: UUID, projectPath: String)
    func togglePinStatus(for conversationId: UUID)

    // MARK: Code Viewer source-link fallbacks
    // Lets the viewer fall back to the store when a source message has scrolled out of the loaded page.
    // Defaulted in an extension so lightweight conformers need not implement them.
    func fetchMessage(withId id: UUID) async -> ChatMessage?
    func fetchUserMessagesWithAttachedTextFiles(for conversationId: UUID) async -> [ChatMessage]

    /// The find-in-conversation corpus, projected down to the text search needs, for up to `limit` rows.
    /// Avoids `fetchMessages`, which decodes the timeline and token blobs and every attached image's `binaryData`.
    func fetchSearchDocuments(for conversationId: UUID, limit: Int) async -> [SearchDocument]

    /// The export projection: the newest `limit` messages, fully decoded except that attached images carry no `binaryData`.
    /// `isTruncated` is true when the conversation holds more than `limit` messages, decided by a count.
    func fetchMessagesForExport(for conversationId: UUID, limit: Int) async -> (messages: [ChatMessage], isTruncated: Bool)

    /// Returns the `limit` most-recent non-empty conversations, newest first, for a recents menu.
    /// Returns rows rather than a container so callers get data instead of a database to query.
    func recentConversations(limit: Int) -> [(id: UUID, title: String)]

    /// Every background/foreground task card saved in this conversation's timelines, oldest first.
    /// The task list's history after a relaunch — the registry behind the live list is memory only.
    func fetchBackgroundTaskRows(for conversationId: UUID) async -> [BackgroundTaskData]
}

extension ChatPersistenceProtocol {
    func fetchMessage(withId id: UUID) async -> ChatMessage? { nil }
    func setTitle(_ title: String?, for conversationId: UUID) {}
    func setTitleIfUntitled(_ title: String, for conversationId: UUID) {}
    /// Test doubles keep their `fetchMessages` behaviour; only the SwiftData store reads off-main.
    func fetchContextHistory(for conversationId: UUID, limit: Int, omittingImageBytes: Bool) async -> [ChatMessage] {
        await fetchMessages(for: conversationId, offset: 0, limit: limit)
    }
    func fetchUserMessagesWithAttachedTextFiles(for conversationId: UUID) async -> [ChatMessage] { [] }
    func fetchSearchDocuments(for conversationId: UUID, limit: Int) async -> [SearchDocument] { [] }
    func fetchMessagesForExport(for conversationId: UUID, limit: Int) async -> (messages: [ChatMessage], isTruncated: Bool) {
        let messages = await fetchMessages(for: conversationId, offset: 0, limit: limit)
        let isTruncated = !(await fetchMessages(for: conversationId, offset: limit, limit: 1)).isEmpty
        return (messages, isTruncated)
    }
    func recentConversations(limit: Int) -> [(id: UUID, title: String)] { [] }
    func updateProjectPath(for conversationId: UUID, projectPath: String) {}
    func fetchBackgroundTaskRows(for conversationId: UUID) async -> [BackgroundTaskData] { [] }
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

    /// Last `ChatMessage.timelineRevision` whose timeline blob was encoded, per message, so a flush skips an unchanged one.
    /// Pruned wholesale past 512 entries; the worst case is one redundant encode per live message.
    private var lastEncodedTimelineRevision: [UUID: UInt64] = [:]

    /// Per-message count of upserts that carried image attachments; diagnostic only.
    /// A value above 1 means an image-bearing row was re-persisted. Pruned with the timeline skip-cache.
    private var imageUpsertCounts: [UUID: Int] = [:]

    /// How stale `ConversationSD.timestamp` may get from updates alone before an upsert moves it.
    /// Sidebar order and its Today/Yesterday grouping are accurate to this.
    static let activityTimestampResolution: TimeInterval = 60

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
            backendEntityId: conversation.backendEntityId
        )

        for message in conversation.messages {
            let messageSD = ChatMessageSD.from(message)
            messageSD.conversation = sd
            sd.messages.append(messageSD)
        }

        context.insert(sd)
        if saveContext("add conversation \(conversation.id.uuidString.prefix(8))") {
            logger.info(
                "[PERSISTENCE] Added conversation \(conversation.id.uuidString) with "
                + "\(conversation.messages.count) message(s)."
            )
        } else {
            logger.error(
                "[PERSISTENCE] Conversation \(conversation.id.uuidString) was NOT persisted "
                + "(\(conversation.messages.count) message(s)). CONSEQUENCE: it appears in the sidebar "
                + "for this session and is gone after relaunch."
            )
        }
    }

    enum ConversationListingError: Error { case containerUnavailable }

    /// Returns every conversation id in the store.
    /// Throws rather than returning an empty set: the launch orphan sweep deletes memory for every id not in the result.
    func liveConversationIDs() throws -> Set<UUID> {
        guard let context = mainContext else { throw ConversationListingError.containerUnavailable }
        var descriptor = FetchDescriptor<ConversationSD>()
        descriptor.propertiesToFetch = [\.id]
        return Set(try context.fetch(descriptor).map(\.id))
    }

    /// Whether a conversation has at least one message, via one count on the indexed `conversationId` column.
    /// Throws rather than answering "empty", because an empty conversation is reusable by `/new`.
    static func hasMessages(conversationID: UUID, in context: ModelContext) throws -> Bool {
        let id = conversationID
        var descriptor = FetchDescriptor<ChatMessageSD>(predicate: #Predicate { $0.conversationId == id })
        descriptor.fetchLimit = 1
        return try context.fetchCount(descriptor) > 0
    }

    func getConversation(withId id: UUID) -> ConversationSD? {
        guard let context = mainContext else { return nil }

        var descriptor = FetchDescriptor<ConversationSD>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        // Not `try?`: callers read nil as "deleted" and abort the send, so a thrown fetch is logged to say which case it was.
        do {
            return try context.fetch(descriptor).first
        } catch {
            logger.error("[PERSISTENCE] Looking up conversation \(id.uuidString.prefix(8)) FAILED: \(error.localizedDescription). CONSEQUENCE: the caller sees 'no such conversation' although it may exist — a send, rename or settings change on it is abandoned this time.")
            return nil
        }
    }

    /// Single-message fetch by id — the Code Viewer's fallback when a snippet's source
    /// message has scrolled out of the loaded page window.
    func fetchMessage(withId id: UUID) async -> ChatMessage? {
        guard let context = mainContext else {
            logger.error("[CodeViewer] fetchMessage(withId:) before container configured — returning nil.")
            return nil
        }
        var descriptor = FetchDescriptor<ChatMessageSD>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        do {
            let message = try context.fetch(descriptor).first?.toChatMessage()
            logger.info("[CodeViewer] Source-message fallback fetch for \(id.uuidString.prefix(8)): \(message != nil ? "HIT" : "MISS — message no longer exists").")
            return message
        } catch {
            logger.error("[CodeViewer] Source-message fallback fetch failed for \(id.uuidString.prefix(8)): \(error.localizedDescription)")
            return nil
        }
    }

    /// Returns user messages carrying attached text files, newest first, for the Code Viewer's filename linking.
    /// Scans at most the newest 500 messages.
    func fetchUserMessagesWithAttachedTextFiles(for conversationId: UUID) async -> [ChatMessage] {
        guard let context = mainContext else {
            logger.error("[CodeViewer] fetchUserMessagesWithAttachedTextFiles before container configured — returning [].")
            return []
        }
        var descriptor = FetchDescriptor<ChatMessageSD>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        do {
            let matches = try context.fetch(descriptor)
                .map { $0.toChatMessage() }
                .filter { $0.sender == .user && !($0.attachedTextFiles ?? []).isEmpty }
            logger.info("[CodeViewer] Attachment-source fallback scan for \(conversationId.uuidString.prefix(8)): \(matches.count) user message(s) with text files.")
            return matches
        } catch {
            logger.error("[CodeViewer] Attachment-source fallback scan failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Returns the `limit` most-recent non-empty conversations for the recents menu.
    /// Emptiness is filtered in Swift over a fetch bounded at `limit * 6`, so the menu can under-fill.
    func recentConversations(limit: Int) -> [(id: UUID, title: String)] {
        guard let context = modelContainer?.mainContext else {
            // Silent-empty otherwise: the recents menu simply renders nothing and looks like a
            // user with no history, which is indistinguishable from a store that never came up.
            logger.error("[HISTORY] Recents menu requested before the SwiftData container was configured — returning 0 conversations. CONSEQUENCE: the QuickAccess recents list renders EMPTY and is indistinguishable from a genuinely empty history; the panel offers no way to reach an existing conversation until the container is up.")
            return []
        }
        var descriptor = FetchDescriptor<ConversationSD>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = limit * 6
        let rows: [ConversationSD]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            logger.error("[HISTORY] Recents menu fetch FAILED: \(error.localizedDescription). CONSEQUENCE: the QuickAccess recents list renders EMPTY and is indistinguishable from a genuinely empty history; the panel offers no way to reach an existing conversation this session.")
            return []
        }
        // `displayTitle` is the sidebar title (user-defined or "New Conversation"), without the first-message fallback.
        // Emptiness comes from the indexed count; a failed count falls back to the relationship for that row.
        return rows.lazy.filter { row in
            do {
                return try Self.hasMessages(conversationID: row.id, in: context)
            } catch {
                logger.error("[HISTORY] Recents: message count for conversation \(row.id.uuidString.prefix(8)) FAILED: \(error.localizedDescription). CONSEQUENCE: that row's emptiness is read from its messages relationship instead (slower, same answer).")
                return !row.messages.isEmpty
            }
        }.prefix(limit).map { (id: $0.id, title: $0.displayTitle) }
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

    /// Model-context history, decoded on a background `ModelContext`.
    /// Reads committed rows only; callers merge their in-memory rows over the result via `BackendHistoryResolver.merge`.
    func fetchContextHistory(for conversationId: UUID, limit: Int, omittingImageBytes: Bool) async -> [ChatMessage] {
        guard let container = modelContainer else {
            logger.error("[HISTORY] Context history for \(conversationId.uuidString.prefix(8)) requested before the container was configured — returning 0 messages. CONSEQUENCE: the request carries no prior turns and the context gauge reads empty.")
            return []
        }
        let started = ContinuousClock.now
        do {
            let messages = try await Self.readOffMain(container) { context in
                var descriptor = FetchDescriptor<ChatMessageSD>(
                    predicate: #Predicate { $0.conversationId == conversationId },
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
                descriptor.fetchLimit = limit
                return try context.fetch(descriptor).map { $0.toChatMessage(omittingImageBytes: omittingImageBytes) }
            }
            let elapsed = ContinuousClock.now - started
            logger.debug("[HISTORY] Context history for \(conversationId.uuidString.prefix(8)): \(messages.count) message(s) decoded off the main actor in \(elapsed)\(omittingImageBytes ? " (image bytes omitted)" : "").")
            return messages
        } catch {
            logger.error("[HISTORY] Context history fetch for \(conversationId.uuidString.prefix(8)) FAILED: \(error.localizedDescription). CONSEQUENCE: the request carries only the in-memory turns (no stored history) and the context gauge under-reads.")
            return []
        }
    }

    /// Runs `body` on a fresh `ModelContext` off the main actor and returns its Sendable result.
    /// A `ModelContext` is confined to its task, so fetched `@Model` rows never leave `body`; only Sendable projections do.
    nonisolated private static func readOffMain<T: Sendable>(
        _ container: ModelContainer,
        _ body: @escaping @Sendable (ModelContext) throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            #if DEBUG
            ChatPersistenceStore.offMainReadObserver?(Thread.isMainThread)
            #endif
            return try body(ModelContext(container))
        }.value
    }

    #if DEBUG
    /// Test hook: called with `Thread.isMainThread` for every background read, to prove reads stay off the main thread.
    nonisolated(unsafe) static var offMainReadObserver: (@Sendable (_ onMainThread: Bool) -> Void)?
    #endif

    /// Same predicate, sort and limit as `fetchMessages`, except every attached image's `binaryData` is empty.
    /// Runs on the main actor, so a long conversation still decodes its JSON blobs here.
    func fetchMessagesForExport(for conversationId: UUID, limit: Int) async -> (messages: [ChatMessage], isTruncated: Bool) {
        guard let context = mainContext else {
            logger.error("[EXPORT] Fetch for \(conversationId.uuidString.prefix(8)) before the container was configured — exporting NOTHING. CONSEQUENCE: the file will hold only the header.")
            return ([], false)
        }

        var descriptor = FetchDescriptor<ChatMessageSD>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        do {
            let entities = try context.fetch(descriptor)
            let messages = entities.map { $0.toChatMessage(omittingImageBytes: true) }
            let total = try context.fetchCount(
                FetchDescriptor<ChatMessageSD>(predicate: #Predicate { $0.conversationId == conversationId })
            )
            let isTruncated = total > limit
            let images = messages.reduce(0) { $0 + ($1.attachedImageFiles?.count ?? 0) }
            logger.info("[EXPORT] Fetched \(messages.count) of \(total) message(s) for \(conversationId.uuidString.prefix(8)) (cap \(limit)\(isTruncated ? ", TRUNCATED" : "")); \(images) attached image(s) projected WITHOUT their bytes.")
            return (messages, isTruncated)
        } catch {
            logger.error("[EXPORT] Fetch for \(conversationId.uuidString.prefix(8)) FAILED: \(error.localizedDescription). CONSEQUENCE: the export holds only the header.")
            return ([], false)
        }
    }

    /// Corpus projection: reads only `id`, `timestamp`, `senderType` and `contentData`, and never calls `toChatMessage()`.
    /// Same predicate, sort and limit as `fetchMessages`; runs on the main actor.
    func fetchSearchDocuments(for conversationId: UUID, limit: Int) async -> [SearchDocument] {
        guard let context = mainContext else {
            logger.warning("[SEARCH] Corpus projection skipped for \(conversationId.uuidString.prefix(8)) — no ModelContext. CONSEQUENCE: search reaches only the resident scroll window; older messages report no results.")
            return []
        }

        var descriptor = FetchDescriptor<ChatMessageSD>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        do {
            let entities = try context.fetch(descriptor)
            var undecodable = 0
            // One document per row ALWAYS, even with no units — callers index the corpus
            // positionally and compare its count against the resident window.
            let documents = entities.map { entity -> SearchDocument in
                let sender = SenderRole(rawValue: entity.senderType) ?? .user
                guard let content = try? JSONDecoder().decode(MessageContent.self, from: entity.contentData) else {
                    undecodable += 1
                    return SearchDocument(id: entity.id, timestamp: entity.timestamp, units: [])
                }
                let blocks: [ContentBlock]?
                if case .markdownText(let text) = content, !text.isEmpty {
                    // Pure free function — writes no cache on any ChatMessage, so the corpus
                    // cannot repopulate the caches `trimMarkdownCachesOutsideWindow` releases.
                    blocks = parseMarkdown(text)
                } else {
                    blocks = nil
                }
                return SearchDocument(
                    id: entity.id,
                    timestamp: entity.timestamp,
                    units: ChatSearchDecomposition.units(sender: sender, content: content, blocks: blocks)
                )
            }
            if undecodable > 0 {
                logger.warning("[SEARCH] \(undecodable) of \(documents.count) message(s) in \(conversationId.uuidString.prefix(8)) had UNDECODABLE contentData. CONSEQUENCE: they are in the corpus but contribute no searchable text, so their content cannot be found.")
            }
            logger.debug("[SEARCH] Projected \(documents.count) search document(s) for \(conversationId.uuidString.prefix(8)) — no timeline or image blobs decoded.")
            return documents
        } catch {
            logger.error("[SEARCH] Corpus projection FAILED for \(conversationId.uuidString.prefix(8)): \(error.localizedDescription). CONSEQUENCE: search reaches only the resident scroll window.")
            return []
        }
    }

    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {
        await addMessages([message], toConversation: conversationId)
    }

    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {
        // Log rather than return silently: the turn is already on screen, so a dropped write would show as missing turns later.
        guard let context = mainContext else {
            logger.error(
                "[PERSISTENCE] addMessages(\(messages.count) messages → conversation "
                + "\(conversationId.uuidString.prefix(8))) called before the ModelContainer was "
                + "configured. CONSEQUENCE: these messages are NOT written to disk — they stay "
                + "visible in the running session and are GONE after relaunch."
            )
            return
        }

        // [P4] Bound the skip cache — a wholesale prune costs at most one redundant
        // encode per live message afterwards, never a missed write.
        if lastEncodedTimelineRevision.count > 512 {
            logger.debug("[P4] Timeline-revision skip cache pruned (\(self.lastEncodedTimelineRevision.count) entries).")
            lastEncodedTimelineRevision.removeAll(keepingCapacity: true)
            // Same bound for the diagnostic image-upsert counter; a prune can only miss a warning, never cause a wrong persist.
            imageUpsertCounts.removeAll(keepingCapacity: true)
        }

        // No conversation, no write: a conversation deleted mid-stream still finalizes here, and inserting would orphan the row.
        // A fetch that throws also refuses the write, since it cannot prove the conversation exists.
        let conversation: ConversationSD
        do {
            var lookup = FetchDescriptor<ConversationSD>(predicate: #Predicate { $0.id == conversationId })
            lookup.fetchLimit = 1
            guard let found = try context.fetch(lookup).first else {
                logger.notice(
                    "[PERSISTENCE] \(messages.count) message(s) for conversation "
                    + "\(conversationId.uuidString.prefix(8)) NOT written — the conversation no longer exists "
                    + "(deleted while its run was finishing). CONSEQUENCE: nothing is stored or indexed for it, "
                    + "which is what deleting it asked for."
                )
                return
            }
            conversation = found
        } catch {
            logger.error(
                "[PERSISTENCE] Could not look up conversation \(conversationId.uuidString.prefix(8)) "
                + "(\(error.localizedDescription)); \(messages.count) message(s) NOT written. CONSEQUENCE: "
                + "they stay visible this session and are missing after relaunch — writing them without "
                + "a conversation would leave orphan rows that are never cleaned up."
            )
            return
        }

        var insertedAny = false
        for message in messages {
            // Upsert: check if message already exists
            let messageId = message.id
            var descriptor = FetchDescriptor<ChatMessageSD>(
                predicate: #Predicate { $0.id == messageId }
            )
            descriptor.fetchLimit = 1

            // Not `try?`: a thrown lookup would read as "not stored yet" and insert a duplicate row.
            // Skip instead; the next flush or finalize re-upserts the message.
            let existing: ChatMessageSD?
            do {
                existing = try context.fetch(descriptor).first
            } catch {
                logger.error("[PERSISTENCE] Looking up message \(messageId.uuidString.prefix(8)) before upsert FAILED: \(error.localizedDescription). CONSEQUENCE: this message is NOT written in this save (inserting blind could duplicate it); the next upsert of it — a later flush or the finalize — retries.")
                continue
            }

            // Traces branch, count and bytes for image-bearing rows, to catch a second upsert of an image row.
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
                // Update the existing message in place.
                // `canPersistContent` stops a "Decode Error" card from overwriting a possibly recoverable message.
                if message.canPersistContent {
                    let contentToEncode = message.currentAgentContent ?? message.content
                    existing.contentData = ChatMessageSD.encodeContent(contentToEncode, messageID: messageId)
                } else {
                    logger.error(
                        "[PERSISTENCE] Refusing to overwrite unreadable contentData for message "
                        + "\(messageId.uuidString.prefix(8)): the stored content failed to decode on "
                        + "load and the caller is handing back the decode-error placeholder. "
                        + "CONSEQUENCE: the original bytes are preserved for a build that can read "
                        + "them; this message renders as a decode-error card until then."
                    )
                }
                // Two guards on one column: `canPersistAgentResponse` skips a blob that failed to decode (nil would null it),
                // and `.write` vs `.preserveExisting` separates "value is nil" from "encoding threw".
                if message.canPersistAgentResponse {
                    if case .write(let data) = ChatMessageSD.encodeAuxiliaryBlob(
                        message.agentResponse, column: "agentResponseData", messageID: messageId,
                        version: ChatMessageSD.agentResponseBlobVersion
                    ) {
                        existing.agentResponseData = data
                    }
                } else {
                    logger.error(
                        "[PERSISTENCE] Refusing to null agentResponseData for message "
                        + "\(messageId.uuidString.prefix(8)): the stored blob failed to decode on load "
                        + "and nothing has replaced it, so this write would erase the response "
                        + "variants. CONSEQUENCE: the original bytes are preserved for a build that "
                        + "can read them; this message shows no variant picker until then."
                    )
                }
                // The revision check is only a performance skip (a freshly loaded message always looks changed);
                // `canPersistTimeline` is the separate safety check against nulling an undecodable blob.
                if lastEncodedTimelineRevision[messageId] != message.timelineRevision {
                    if message.canPersistTimeline {
                        // Cache the revision only after a successful write; otherwise the skip suppresses every retry after a transient failure.
                        switch ChatMessageSD.encodeAuxiliaryBlob(
                            ChatMessageSD.wrappedTimeline(message.timelineEvents),
                            column: "timelineEventsData", messageID: messageId,
                            version: ChatMessageSD.timelineBlobVersion
                        ) {
                        case .write(let data):
                            existing.timelineEventsData = data
                            lastEncodedTimelineRevision[messageId] = message.timelineRevision
                        case .preserveExisting:
                            break  // helper logged it; leave the revision uncached so a later flush retries
                        }
                    } else {
                        // Read failure must not become a write failure. Leave the bytes alone and do
                        // NOT cache the revision, so a later flush carrying real events still writes.
                        logger.error(
                            "[PERSISTENCE] Refusing to null timelineEventsData for message "
                            + "\(messageId.uuidString.prefix(8)): the stored blob failed to decode on "
                            + "load and nothing has been appended since, so this write would replace "
                            + "the run's timeline with nothing. CONSEQUENCE: the original bytes are "
                            + "preserved for a build that can read them; the timeline renders empty "
                            + "until then."
                        )
                    }
                }
                existing.traceID = message.traceID
                existing.senderType = message.sender.rawValue
                // Written on every upsert, not only on insert: surfaces stamp `messageSource` after the stream starts,
                // so the first flush can reach disk while it still reads `.localUI`.
                existing.messageSourceRaw = message.messageSource.rawValue
                existing.isSyntheticPrompt = message.isSyntheticPrompt
                // Terminal status is set late in the run, so update it on every upsert to keep disk in step with the in-memory message.
                existing.terminalOutcomeRaw = message.terminalOutcome?.rawValue
                existing.terminalReason = message.terminalReason

                // `.tokenUsage` arrives after the first flush has inserted the row, so finalize lands on this update branch;
                // `canPersistTokenUsage` skips a blob that failed to decode so a nil never erases stored usage.
                if message.canPersistTokenUsage {
                    if case .write(let data) = ChatMessageSD.encodeAuxiliaryBlob(
                        message.tokenUsage, column: "tokenUsageData", messageID: messageId,
                        version: ChatMessageSD.tokenUsageBlobVersion
                    ) {
                        existing.tokenUsageData = data
                    }
                } else {
                    logger.error("[PERSISTENCE] Message \(messageId.uuidString.prefix(8)): tokenUsageData was unreadable on load and nothing has replaced it — the stored bytes are LEFT IN PLACE. CONSEQUENCE: usage/cost for this message stays missing on this build but is not erased.")
                }

                // Re-apply the resume lifecycle and run-identity stamp on every update: the row is created as `.streaming`
                // before a HITL park stamps `.parkedHITL`, so these must reach disk on update too.
                existing.lifecycleStateRaw = message.lifecycleState.rawKind
                existing.parkedOperationID = message.lifecycleState.parkedOperationID?.uuidString
                existing.apiProvider = message.apiProvider
                existing.modelName = message.modelName
                existing.modelDialect = message.modelDialect

                // Reconcile attachment children in place by id: kept ids keep their row and blob, only removed ids are deleted
                // and new ids inserted. A nil result means unchanged, so the external blob is not re-marked dirty.
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
                conversation.messages.append(sd)
                // [P4] `ChatMessageSD.from` just encoded this revision's timeline.
                lastEncodedTimelineRevision[messageId] = message.timelineRevision
                insertedAny = true
            }
        }

        // Last activity: not moved on every write, since each streaming flush would invalidate the sidebar query.
        // A new row re-sorts at once; an update moves it at most once per `activityTimestampResolution`.
        let now = Date()
        if insertedAny || now.timeIntervalSince(conversation.timestamp) >= Self.activityTimestampResolution {
            conversation.timestamp = now
        }
        // `.info`, not `.debug`: DGLogger never routes `.debug` to the ring buffer, so bug bundles would miss this line.
        if saveContext("upsert \(messages.count) message(s) → conv \(conversationId.uuidString.prefix(8))") {
            logger.info(
                "[PERSISTENCE] Upserted \(messages.count) message(s) for conversation "
                + "\(conversationId.uuidString)."
            )
        } else {
            logger.error(
                "[PERSISTENCE] \(messages.count) message(s) for conversation "
                + "\(conversationId.uuidString) were NOT persisted. CONSEQUENCE: the turn is on screen "
                + "but not on disk; it stays pending and goes out with the next successful save — if "
                + "saving keeps failing, it disappears on relaunch."
            )
        }

        // Index user turns here, the one persistence funnel every surface uses; assistant turns are indexed at finalize.
        // Fire-and-forget, with snapshots taken on the main actor because the indexer runs detached.
        let userMessages = messages.filter { $0.sender == .user }.map { IndexableMessage($0) }
        if !userMessages.isEmpty {
            Task.detached(priority: .background) {
                for message in userMessages {
                    await RAGIndexingService.shared.indexSingleMessage(message)
                }
            }
        }
    }

    func deleteConversation(with id: UUID) {
        guard let context = mainContext,
              let conversation = getConversation(withId: id) else {
            logger.warning("Tried to delete conversation \(id.uuidString), but it was not found.")
            return
        }
        // Counted before the delete: afterwards the relationships are gone and the cascade's effect cannot be stated.
        let messageCount = conversation.messages.count
        let attachmentCount = conversation.messages.reduce(0) {
            $0 + $1.attachedTextFiles.count + $1.attachedImageFiles.count
        }
        let runCount = conversation.workflowRuns.count

        context.delete(conversation)
        // Never report a destructive cascade before it commits; a failed save would otherwise look like a resurrection bug.
        if saveContext("delete conversation \(id.uuidString.prefix(8))") {
            logger.notice(
                "[PERSISTENCE] Conversation \(id.uuidString.prefix(8)) deleted — cascaded "
                + "\(messageCount) message(s), \(attachmentCount) attachment(s), \(runCount) workflow run(s)."
            )
            // Generated images go only after the delete has committed; a failed save brings the conversation back, images included.
            Task.detached(priority: .utility) {
                await MediaStore.shared.evict(conversationID: id)
            }
        } else {
            logger.error(
                "[PERSISTENCE] Delete of conversation \(id.uuidString.prefix(8)) was NOT persisted "
                + "(\(messageCount) message(s), \(attachmentCount) attachment(s), \(runCount) workflow "
                + "run(s) still on disk). CONSEQUENCE: it disappears from the sidebar now; the delete "
                + "stays pending and goes out with the next successful save — if saving keeps failing, "
                + "it RETURNS on the next launch."
            )
        }
    }

    func updateBackendForConversation(id: UUID, backendEntityId: UUID?) {
        guard let conversation = getConversation(withId: id) else {
            logger.warning("Attempted to update backend for non-existent conversation: \(id.uuidString)")
            return
        }
        // Called on every send, so an unchanged value skips the save.
        guard conversation.backendEntityId != backendEntityId else { return }
        conversation.backendEntityId = backendEntityId
        if saveContext("profile of conv \(id.uuidString.prefix(8))") {
            logger.info("[PERSISTENCE] Updated conversation \(id.uuidString) profile: \(backendEntityId?.uuidString ?? "none").")
        } else {
            logger.error(
                "[PERSISTENCE] Backend change for conversation \(id.uuidString) was NOT persisted. "
                + "CONSEQUENCE: the conversation reverts to its previous backend on relaunch."
            )
        }
    }

    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {
        guard let conversation = getConversation(withId: conversationId) else {
            logger.warning("Attempted to update profileType for non-existent conversation: \(conversationId.uuidString)")
            return
        }
        // Called on every Code send, so an unchanged value skips the save.
        guard conversation.profileTypeRaw != profileTypeRaw else { return }
        conversation.profileTypeRaw = profileTypeRaw
        if saveContext("profile type of conv \(conversationId.uuidString.prefix(8))") {
            logger.info("[PERSISTENCE] Updated conversation \(conversationId.uuidString) profileType: \(profileTypeRaw).")
        } else {
            logger.error(
                "[PERSISTENCE] profileType change for conversation \(conversationId.uuidString) was NOT "
                + "persisted. CONSEQUENCE: it reverts on relaunch."
            )
        }
    }

    // Why: runs on every conversation open and is unbounded, so keep it off the main actor.
    /// Returns background-task rows for a conversation, reading only the timeline blob off the main actor.
    /// The blob is decoded only when its bytes contain the key of `KnownTimelineEvent.backgroundTask`.
    func fetchBackgroundTaskRows(for conversationId: UUID) async -> [BackgroundTaskData] {
        guard let container = modelContainer else { return [] }
        do {
            return try await Self.readOffMain(container) { context in
                var descriptor = FetchDescriptor<ChatMessageSD>(
                    predicate: #Predicate { $0.conversationId == conversationId },
                    sortBy: [SortDescriptor(\.timestamp, order: .forward)]
                )
                descriptor.propertiesToFetch = [\.timelineEventsData]
                let marker = Data("\"backgroundTask\"".utf8)
                var rows: [BackgroundTaskData] = []
                for entity in try context.fetch(descriptor) {
                    guard let blob = entity.timelineEventsData, blob.range(of: marker) != nil else { continue }
                    do {
                        for event in try ChatMessageSD.decodeTimeline(from: blob) {
                            if case .backgroundTask(let data) = event { rows.append(data) }
                        }
                    } catch {
                        logger.error("[BGTASK] Task history: message \(entity.id.uuidString.prefix(8)) has an undecodable timeline (\(error.localizedDescription)). CONSEQUENCE: its task cards are missing from the task list's history; the message itself renders with its own decode-failure placeholder.")
                    }
                }
                return rows
            }
        } catch {
            logger.error("[BGTASK] Task history fetch failed for conversation \(conversationId.uuidString.prefix(8)): \(error.localizedDescription). CONSEQUENCE: the task list shows only tasks from this launch.")
            return []
        }
    }

    func updateProjectPath(for conversationId: UUID, projectPath: String) {
        guard let conversation = getConversation(withId: conversationId) else {
            logger.warning("[PERSISTENCE] Attempted to record a project folder for non-existent conversation \(conversationId.uuidString). CONSEQUENCE: nothing is recorded; the conversation does not exist to be reopened.")
            return
        }
        guard conversation.projectPath != projectPath else { return }
        conversation.projectPath = projectPath
        if saveContext("project folder of conv \(conversationId.uuidString.prefix(8))") {
            logger.info("[PERSISTENCE] Conversation \(conversationId.uuidString) runs in project '\(URL(fileURLWithPath: projectPath).lastPathComponent)'.")
        } else {
            logger.error(
                "[PERSISTENCE] Project folder for conversation \(conversationId.uuidString) was NOT persisted. "
                + "CONSEQUENCE: after relaunch it lists under 'No project' and reopening it keeps whatever folder is open."
            )
        }
    }

    /// Applies the user's rename and saves it (nil or blank clears the title).
    func setTitle(_ title: String?, for conversationId: UUID) {
        guard let conversation = getConversation(withId: conversationId) else {
            logger.warning("[PERSISTENCE] Rename of non-existent conversation \(conversationId.uuidString.prefix(8)). CONSEQUENCE: nothing to rename.")
            return
        }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard conversation.userDefinedTitle != newTitle else { return }
        conversation.userDefinedTitle = newTitle
        if !saveContext("title of conv \(conversationId.uuidString.prefix(8))") {
            logger.error("[PERSISTENCE] Rename of conversation \(conversationId.uuidString.prefix(8)) was NOT persisted. CONSEQUENCE: the sidebar shows the new title; it reverts on relaunch unless a later save succeeds.")
        }
    }

    /// The first-message auto-title: sets `title` only when the conversation has none, and saves it like `setTitle`.
    func setTitleIfUntitled(_ title: String, for conversationId: UUID) {
        guard let conversation = getConversation(withId: conversationId),
              conversation.userDefinedTitle?.isEmpty ?? true else { return }
        conversation.userDefinedTitle = title
        if saveContext("auto-title of conv \(conversationId.uuidString.prefix(8))") {
            logger.info("[PERSISTENCE] Auto-titled conversation \(conversationId.uuidString.prefix(8)).")
        } else {
            logger.error("[PERSISTENCE] Auto-title of conversation \(conversationId.uuidString.prefix(8)) was NOT persisted. CONSEQUENCE: it shows this session; after relaunch the conversation reads 'New Conversation' unless a later save succeeds.")
        }
    }

    func togglePinStatus(for conversationId: UUID) {
        guard let conversation = getConversation(withId: conversationId) else {
            logger.warning("Attempted to toggle pin for non-existent conversation: \(conversationId.uuidString)")
            return
        }
        conversation.isPinned.toggle()
        if saveContext("pin of conv \(conversationId.uuidString.prefix(8))") {
            logger.info("[PERSISTENCE] Pin for conversation \(conversationId.uuidString) → \(conversation.isPinned).")
        } else {
            logger.error(
                "[PERSISTENCE] Pin toggle for conversation \(conversationId.uuidString) was NOT "
                + "persisted. CONSEQUENCE: the sidebar shows the new state until relaunch, then reverts."
            )
        }
    }

    // MARK: - Private

    /// Reconciles a to-many attachment relationship in place by id, deleting vanished ids and inserting new ones.
    /// Returns nil when the incoming id set equals the existing one, so the caller leaves the relationship untouched
    /// (assignment dirties an external-storage attribute even when the value is unchanged).
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

    // Why: `@discardableResult` is deliberately absent so callers cannot report a failed save as done.
    /// Commits the pending changes. Returns whether they actually reached disk.
    /// Callers log success only on a true result.
    private func saveContext(_ label: @autoclosure () -> String) -> Bool {
        guard let context = mainContext else {
            logger.error(
                "[PERSISTENCE] saveContext called before the ModelContainer was configured. "
                + "CONSEQUENCE: every pending chat change — new messages, edits, timeline blobs — "
                + "is lost when the app quits."
            )
            return false
        }
        do {
            try SharedContextSave.save(context, "chat: \(label())")
            return true
        } catch {
            logger.error(
                "[PERSISTENCE] Failed to save the chat context: \(error). CONSEQUENCE: everything "
                + "written since the last successful save — new messages, edits, deletions, timeline "
                + "blobs — is still only in memory and is LOST when the app quits. The UI will keep "
                + "showing it until the next relaunch, which is why this reads as data 'disappearing' "
                + "rather than as a save failure."
            )
            return false
        }
    }
}

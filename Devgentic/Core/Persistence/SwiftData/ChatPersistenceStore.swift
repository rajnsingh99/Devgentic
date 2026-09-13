// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

    // MARK: Code Viewer source-link fallbacks
    // The viewer's diff/apply/linking resolve attachment sources against the LOADED page
    // of messages; these let it fall back to the store when the source message has
    // scrolled out of that window. Defaulted in an extension so lightweight conformers
    // (test stubs) aren't forced to implement them.
    func fetchMessage(withId id: UUID) async -> ChatMessage?
    func fetchUserMessagesWithAttachedTextFiles(for conversationId: UUID) async -> [ChatMessage]

    /// The find-in-conversation corpus, projected down to just the text search needs.
    ///
    /// Deliberately NOT `fetchMessages`: that runs `toChatMessage()` per row, which decodes the
    /// timeline and token blobs and materialises EVERY attached image's full `binaryData` — for
    /// up to 1000 rows, on the main actor, triggered by pressing ⌘F. The corpus never reads any
    /// of that. Defaulted so lightweight test conformers aren't forced to implement it.
    func fetchSearchDocuments(for conversationId: UUID, limit: Int) async -> [SearchDocument]

    /// [mm-4] The export projection: the newest `limit` messages, fully decoded EXCEPT that
    /// attached images carry no `binaryData` — the export lists them by name and size and never
    /// embeds them, and the image blob is the schema's only `@Attribute(.externalStorage)` field,
    /// i.e. the dominant cost of `fetchMessages` (the same cost `fetchSearchDocuments` exists to
    /// avoid). `isTruncated` is true when the conversation holds MORE than `limit` messages,
    /// decided by a count rather than by decoding one message past the cap. Defaulted to the
    /// full fetch plus the old probe so lightweight conformers stay honest rather than empty.
    func fetchMessagesForExport(for conversationId: UUID, limit: Int) async -> (messages: [ChatMessage], isTruncated: Bool)

    /// The `limit` most-recent NON-EMPTY conversations, newest first, for a recents menu.
    ///
    /// ⚠️ On the protocol rather than at the caller because QuickAccess used to reach through
    /// `persistence.modelContainer?.mainContext` and run its own `FetchDescriptor` — the one use
    /// that pinned it to the concrete `ChatPersistenceStore` and made the whole panel
    /// untestable. Handing back rows instead of a container is the same shape as
    /// `fetchUserMessagesWithAttachedTextFiles` and `fetchSearchDocuments`, and for the same
    /// reason: a caller that needs data should be given data, not a database to query.
    /// Defaulted so lightweight test conformers aren't forced to implement it.
    func recentConversations(limit: Int) -> [(id: UUID, title: String)]
}

extension ChatPersistenceProtocol {
    func fetchMessage(withId id: UUID) async -> ChatMessage? { nil }
    func fetchUserMessagesWithAttachedTextFiles(for conversationId: UUID) async -> [ChatMessage] { [] }
    func fetchSearchDocuments(for conversationId: UUID, limit: Int) async -> [SearchDocument] { [] }
    func fetchMessagesForExport(for conversationId: UUID, limit: Int) async -> (messages: [ChatMessage], isTruncated: Bool) {
        let messages = await fetchMessages(for: conversationId, offset: 0, limit: limit)
        let isTruncated = !(await fetchMessages(for: conversationId, offset: limit, limit: 1)).isEmpty
        return (messages, isTruncated)
    }
    func recentConversations(limit: Int) -> [(id: UUID, title: String)] { [] }
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
        if saveContext() {
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

    func getConversation(withId id: UUID) -> ConversationSD? {
        guard let context = mainContext else { return nil }

        var descriptor = FetchDescriptor<ConversationSD>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        return try? context.fetch(descriptor).first
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

    /// User messages of a conversation that carry attached text files, newest first —
    /// the Code Viewer's fallback source for filename→attachment linking when the
    /// attaching message has scrolled out of the loaded window. Capped at the newest 500
    /// messages scanned; attachment-bearing user messages are sparse, so the cap is a
    /// pathological-conversation guard, not a practical limit.
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

    /// [QA revival P2c] The N most-recent NON-empty conversations for the recents menu.
    ///
    /// Moved here from `QuickAccessSessionViewModel` (2026-09-07): the panel held a `FetchDescriptor`
    /// against `modelContainer.mainContext`, which forced it to depend on this concrete class
    /// rather than `ChatPersistenceProtocol`. A direct descriptor is still right — `@Query` cannot
    /// run in the panel's `NSHostingView` (no `modelContext` in its environment) — it just belongs
    /// on the store.
    ///
    /// `messages.isEmpty` is not reliable inside a `#Predicate`, so emptiness is filtered in Swift
    /// and the fetch is bounded at `limit * 6` rather than scanning the table. That can
    /// occasionally under-fill when the newest rows are mostly empty, which is acceptable for a
    /// menu and is why the bound is a multiple rather than `limit`.
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
            // The sibling arms of this method's guard chain log; this one used to swallow.
            logger.error("[HISTORY] Recents menu fetch FAILED: \(error.localizedDescription). CONSEQUENCE: the QuickAccess recents list renders EMPTY and is indistinguishable from a genuinely empty history; the panel offers no way to reach an existing conversation this session.")
            return []
        }
        // ⚠️ `ConversationSD.displayTitle` is the SIDEBAR extension: `userDefinedTitle` or the
        // literal "New Conversation". It has no first-message fallback, unlike the `Conversation`
        // struct's version reached via `toRowStruct()`, which derives a title from the first
        // non-empty message. So an untitled conversation reads "New Conversation" here and its
        // derived title everywhere else. Pre-existing (this expression moved here verbatim from
        // QuickAccess); recorded rather than changed, because changing it changes what the menu
        // shows and that is a product call.
        return rows.lazy.filter { !$0.messages.isEmpty }.prefix(limit).map { (id: $0.id, title: $0.displayTitle) }
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

    /// [mm-4] See the protocol doc. Same predicate/sort/limit as `fetchMessages`; the ONLY
    /// difference in what comes back is that every attached image's `binaryData` is empty.
    ///
    /// Still main-actor (the store is `@MainActor`), so a long conversation still decodes its
    /// four JSON blobs per message here — but no longer tens of MB of sidecar image files, and,
    /// since the exporter now presents the save panel FIRST, only after the user has picked a
    /// destination rather than before anything appears on screen.
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

    /// Corpus projection: reads ONLY `id`, `timestamp`, `senderType` and `contentData`, and
    /// decodes the content blob alone. Never calls `toChatMessage()`, so the timeline/token
    /// blobs and — the dominant cost — every attached image's external-storage bytes are never
    /// touched. Same predicate/sort/limit as `fetchMessages`.
    ///
    /// Still main-actor (the store is `@MainActor` and this app has no background
    /// `ModelContext`), so this shrinks the ⌘F stall rather than eliminating it.
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
        // ⚠️ This was a bare `guard let context = mainContext else { return }` (G53). It is the
        // worst-placed silent return in the app: the caller has already streamed a full assistant
        // turn and shown it on screen, so dropping the write here means the conversation reads
        // normally until relaunch and then comes back missing turns, with nothing anywhere saying
        // why. The write cannot be recovered from here — but it must not vanish unrecorded.
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
                // ⚠️ A read failure must not become a write failure — and `contentData` IS the
                // conversation, so this is the most consequential of the guards. When the stored
                // bytes could not be decoded, the caller is holding the "Decode Error" card we
                // issued; writing it back would replace a possibly-recoverable message with the
                // card, permanently. A real value (a live agent writing content, a deliberate
                // replacement) still writes normally.
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
                // ⚠️ TWO guards, closing two different holes on the same column.
                //
                // `canPersistAgentResponse` is the READ side (G91): a blob that failed to decode
                // yielded `agentResponse == nil`, and nil is exactly what this line persists — so an
                // unreadable response was nulled on the first flush after the failed load.
                //
                // `.write` vs `.preserveExisting` is the ENCODE side (G21): `flatMap { try? … }`
                // collapsed "value is nil" and "encoding threw" into the same nil.
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
                // [P4] The timeline is the heavyweight blob (up to 500 events) and it
                // changes far less often than content — yet every in-flight flush
                // (~2s during streaming) re-encoded ALL of it on the MainActor,
                // quadratic over a run. Skip when the revision says nothing changed;
                // the random per-instance seed makes cross-instance aliasing (reload,
                // regenerate) impossible, so a real change can never be skipped.
                // ⚠️ The revision check is a PERFORMANCE skip, not a safety net — the opposite, in
                // fact. `timelineRevision` is seeded randomly per instance so two instances of the
                // same persisted message can never alias, which means a freshly-loaded message
                // ALWAYS looks changed and this branch always fires on the first flush after a load.
                // That is precisely when an undecodable blob would be nulled, so the safety check
                // has to be its own condition.
                if lastEncodedTimelineRevision[messageId] != message.timelineRevision {
                    if message.canPersistTimeline {
                        // ⚠️ Cache the revision only on a successful write. The old form nulled the
                        // column on an encode failure AND stamped the revision, so the skip above
                        // suppressed every later retry — one transient failure permanently deleted
                        // the run's timeline (G21).
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
                if case .write(let data) = ChatMessageSD.encodeAuxiliaryBlob(
                    message.tokenUsage, column: "tokenUsageData", messageID: messageId,
                    version: ChatMessageSD.tokenUsageBlobVersion
                ) {
                    existing.tokenUsageData = data
                }

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
        // ⚠️ .info, not .debug: DGLogger never routes .debug to the ring buffer, so the only
        // positive confirmation that the app's MAIN WRITE PATH ran was absent from every exported
        // bug bundle.
        if saveContext() {
            logger.info(
                "[PERSISTENCE] Upserted \(messages.count) message(s) for conversation "
                + "\(conversationId.uuidString)."
            )
        } else {
            logger.error(
                "[PERSISTENCE] \(messages.count) message(s) for conversation "
                + "\(conversationId.uuidString) were NOT persisted. CONSEQUENCE: the turn is on screen "
                + "but not on disk — it disappears on relaunch."
            )
        }

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
        if saveContext() {
            logger.info("[PERSISTENCE] Updated conversation \(conversationId.uuidString) with OpenAI thread ID.")
        } else {
            logger.error(
                "[PERSISTENCE] OpenAI thread ID for conversation \(conversationId.uuidString) was NOT "
                + "persisted. CONSEQUENCE: the assistant thread is re-created on the next launch and "
                + "server-side history for this conversation is orphaned."
            )
        }
    }

    func deleteConversation(with id: UUID) {
        guard let context = mainContext,
              let conversation = getConversation(withId: id) else {
            logger.warning("Tried to delete conversation \(id.uuidString), but it was not found.")
            return
        }
        // Counted BEFORE the delete: afterwards the relationships are gone and there is
        // no way to state what the cascade actually removed. "Deleted conversation X" on
        // its own can't distinguish a clean teardown from a cascade that silently did
        // nothing, which is exactly the question a user asks after deleting.
        let messageCount = conversation.messages.count
        let attachmentCount = conversation.messages.reduce(0) {
            $0 + $1.attachedTextFiles.count + $1.attachedImageFiles.count
        }
        let runCount = conversation.workflowRuns.count

        context.delete(conversation)
        // Code-viewer sessions are no longer counted here: the entity was retired 2026-08-04 and
        // tabs are in-memory only, so there is nothing left for the cascade to remove.
        //
        // ⚠️ A destructive cascade must never be reported before it commits. This claimed 42 messages
        // deleted on a save that could have thrown — and the conversation reappearing on relaunch
        // then looks like a resurrection bug rather than a failed delete.
        if saveContext() {
            logger.notice(
                "[PERSISTENCE] Conversation \(id.uuidString.prefix(8)) deleted — cascaded "
                + "\(messageCount) message(s), \(attachmentCount) attachment(s), \(runCount) workflow run(s)."
            )
        } else {
            logger.error(
                "[PERSISTENCE] Delete of conversation \(id.uuidString.prefix(8)) was NOT persisted "
                + "(\(messageCount) message(s), \(attachmentCount) attachment(s), \(runCount) workflow "
                + "run(s) still on disk). CONSEQUENCE: it disappears from the sidebar now and RETURNS "
                + "on the next launch."
            )
        }
    }

    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {
        guard let conversation = getConversation(withId: id) else {
            logger.warning("Attempted to update backend for non-existent conversation: \(id.uuidString)")
            return
        }
        conversation.backendType = backendType?.rawValue
        conversation.backendEntityId = backendEntityId
        if saveContext() {
            logger.info("[PERSISTENCE] Updated conversation \(id.uuidString) backend: \(backendType?.rawValue ?? "none").")
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
        conversation.profileTypeRaw = profileTypeRaw
        if saveContext() {
            logger.info("[PERSISTENCE] Updated conversation \(conversationId.uuidString) profileType: \(profileTypeRaw).")
        } else {
            logger.error(
                "[PERSISTENCE] profileType change for conversation \(conversationId.uuidString) was NOT "
                + "persisted. CONSEQUENCE: it reverts on relaunch."
            )
        }
    }

    func togglePinStatus(for conversationId: UUID) {
        guard let conversation = getConversation(withId: conversationId) else {
            logger.warning("Attempted to toggle pin for non-existent conversation: \(conversationId.uuidString)")
            return
        }
        conversation.isPinned.toggle()
        if saveContext() {
            logger.info("[PERSISTENCE] Pin for conversation \(conversationId.uuidString) → \(conversation.isPinned).")
        } else {
            logger.error(
                "[PERSISTENCE] Pin toggle for conversation \(conversationId.uuidString) was NOT "
                + "persisted. CONSEQUENCE: the sidebar shows the new state until relaunch, then reverts."
            )
        }
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

    /// Commits the pending changes. Returns whether they actually reached disk.
    ///
    /// ⚠️ `@discardableResult` is deliberately ABSENT. This used to return `Void` and swallow its
    /// error, and around it sat a dozen call sites logging "Added conversation X" / "Upserted N
    /// messages" / "removed — cascaded 42 message(s)" as accomplished facts. On a save failure every
    /// one of those lines asserted something that never happened, so a support log positively
    /// confirmed writes that were gone after relaunch — pointing any investigation at the load path
    /// instead of the save. Callers must now decide what to say based on what happened.
    private func saveContext() -> Bool {
        guard let context = mainContext else {
            logger.error(
                "[PERSISTENCE] saveContext called before the ModelContainer was configured. "
                + "CONSEQUENCE: every pending chat change — new messages, edits, timeline blobs — "
                + "is lost when the app quits."
            )
            return false
        }
        do {
            try context.save()
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

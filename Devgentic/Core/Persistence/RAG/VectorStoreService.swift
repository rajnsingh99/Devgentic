// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  VectorStoreService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import ObjectBox
import os

// MARK: - Retrieval Result

// Why: A value copied out of the entity: retrieval runs off the main actor, and `ParentDocumentEntity` is a non-Sendable
// ObjectBox class.
/// A retrieval hit: the parent document plus the best-matching chunk that surfaced it, so callers can window text
/// around the match.
struct RetrievedDocument: Sendable {
    let parentID: Id
    let sourceMessageID: UUID
    let sourceIdentifier: String
    let timestamp: Date
    let fullTextContent: String
    /// Text of the closest chunk — the anchor for centered injection windows.
    let bestChunkText: String
    /// Raw cosine distance of the best chunk — the pure semantic signal. Hybrid
    /// BM25 fusion reorders results but never mutates this value.
    let distance: Double

    init(parent: ParentDocumentEntity, bestChunkText: String, distance: Double) {
        self.parentID = parent.id
        self.sourceMessageID = parent.sourceMessageID
        self.sourceIdentifier = parent.sourceIdentifier
        self.timestamp = parent.timestamp
        self.fullTextContent = parent.fullTextContent
        self.bestChunkText = bestChunkText
        self.distance = distance
    }
}

// MARK: - Vector Store Service

/// Manages the vector database using ObjectBox with a native HNSW index, configured for the 384-dimensional
/// All-MiniLM-L6-v2 space.
/// See `ChildChunkEntity` for the index hyperparameters.
final class VectorStoreService: @unchecked Sendable {

    // MARK: - Singleton Instance
    static let shared = VectorStoreService()

    // MARK: - Private Properties
    /// The three ObjectBox handles, held together so availability is one decision.
    /// Optional on purpose: a corrupt or unwritable vector-db disables retrieval (logged once) instead of refusing to launch.
    private struct Backing {
        let store: Store
        let parentBox: Box<ParentDocumentEntity>
        let childBox: Box<ChildChunkEntity>
    }
    private let backing: Backing?

    // Why: Concurrent `runInTransaction` calls on one ObjectBox `Store` deadlock nondeterministically on Swift-concurrency
    // threads.
    /// Serialises every write to the store; ObjectBox admits one writer at a time anyway, so this costs no throughput.
    private let writeLock = NSLock()

    // Why: A write that hits the cap takes ~13 s inside ObjectBox while holding `writeLock`; latching makes later writes refuse
    // instantly.
    /// Latched by a `dbFull` write; cleared by a delete that frees space. Guarded by `writeLock`.
    private var storeIsFull = false

    /// Conversations deleted this session, guarded by `writeLock` and checked inside it by every write,
    /// so no write can land after its conversation's delete. Orphans from a crash are collected by
    /// `removeOrphanedConversations`.
    private var deletedConversations: Set<String> = []

    /// False when the vector store could not be opened. Retrieval is disabled; everything else works.
    var isAvailable: Bool { backing != nil }
    private let logger = DGLogger(category: "VectorStoreService")

    // MARK: - HNSW Search Constants

    /// Cosine distance threshold (= 1 − cosine_similarity).
    /// L2-normalised vectors from EmbeddingService ensure cosine_distance = 1 − dot_product.
    /// Equivalent to the previous similarity threshold of 0.3 (distance ≤ 0.7 → similarity ≥ 0.3).
    private let maximumCosineDistance: Double = 0.7

    /// On-disk ceiling for the vector store, in KB; ObjectBox's 1 GiB default makes every write throw `dbFull` at the cap.
    /// Sized for ~1M chunks (~4 KB each including the HNSW graph); LMDB maps address space, not memory.
    static let maxDatabaseSizeKB: UInt64 = 4 * 1024 * 1024

    // MARK: - Schema Versioning

    /// Current on-disk schema generation. Bump only for representational changes ObjectBox cannot auto-migrate.
    /// 1 = native [Float] embedding with an HNSW index.
    static let currentSchemaVersion = 1

    // Why: A UserDefaults flag lives beside the data and can desynchronize from it, silently wiping a healthy database.
    /// Marker file inside the vector-db directory; the wipe decision keys on it, not on preferences.
    /// Internal so tests can assert against the same filename the migration and schema gate use.
    static let schemaMarkerFilename = "schema-version"

    /// What init should do about the on-disk schema. Pure — extracted for tests.
    enum SchemaGateAction: Equatable {
        /// Marker matches the current schema: open, touch nothing.
        case openAsIs
        /// Fresh directory: write the marker, wipe nothing.
        case stampOnly
        /// Unreadable OLDER (or unmarked) schema: set aside and rebuild — the only lossy path, and
        /// it's loud.
        case wipeAndStamp
        // Why: Never wipe a newer store on downgrade: quarantining it into the single superseded slot would replace the original.
        /// A newer build's store: open nothing and touch nothing; retrieval is off for this launch.
        case leaveNewerUntouched
    }

    /// - Parameter storedEmbeddingModel: the `embeddingModelFilename` record; nil when absent
    ///   (a store from before it existed — accepted as the current model and stamped).
    static func schemaGateAction(markerVersion: Int?, databaseExists: Bool, storedEmbeddingModel: String? = nil) -> SchemaGateAction {
        if let markerVersion, markerVersion > currentSchemaVersion { return .leaveNewerUntouched }
        if markerVersion == currentSchemaVersion {
            // Same schema, different embedding model means incomparable vectors: set aside, never mix.
            if databaseExists, let stored = storedEmbeddingModel, stored != EmbeddingService.modelIdentifier {
                return .wipeAndStamp
            }
            return .openAsIs
        }
        return databaseExists ? .wipeAndStamp : .stampOnly
    }

    /// Records `EmbeddingService.modelIdentifier` beside the schema marker.
    static let embeddingModelFilename = "embedding-model"

    /// Thrown out of `init` for `.leaveNewerUntouched`, so the ordinary degrade path runs.
    struct NewerSchemaOnDisk: Error, CustomStringConvertible {
        let version: Int
        var description: String {
            "the vector-db was written by a NEWER build (schema v\(version), this build reads v\(VectorStoreService.currentSchemaVersion)); it is left untouched"
        }
    }

    // MARK: - Initialization

    /// The on-disk vector-db directory.
    /// Static because the failure path must name this path when `init` did not complete.
    static func storeDirectoryURL() throws -> URL {
        #if DEBUG
        // Why: The user's LMDB store has no reindex-from-transcripts path, so a second process taking its lock is unacceptable.
        // Redirected, not refused: RAG tests open a store, but a test host must never open the user's store.
        // Keyed per process so two stores in one test run share a path; DEBUG-only so a shipped app cannot be pointed elsewhere.
        if TestHost.isRunning {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("devgentic-vectorstore-testhost", isDirectory: true)
                .appendingPathComponent("vector-db-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        #endif

        guard let bundleID = Bundle.main.bundleIdentifier else {
            throw VectorStoreLocationError.bundleIdentifierUnavailable
        }
        return try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
            .appendingPathComponent(bundleID)
            .appendingPathComponent("vector-db")
    }

    /// Display/reveal form. Empty string when even the location cannot be resolved — callers use it
    /// for a Reveal-in-Finder affordance, where an empty path simply reveals nothing.
    static var storeDirectoryPath: String { (try? storeDirectoryURL())?.path ?? "" }

    /// Private initializer that sets up the ObjectBox store and entity box.
    /// A large pre-existing dataset compiles the full HNSW graph on first open (O(N log N)); for >100k vectors move it to a
    /// background task.
    private init() {
        do {
            let appSupport = try Self.storeDirectoryURL()

            // Schema gate: the destroy decision keys on a version marker stored with the data, so it cannot disagree with it.
            let markerURL = appSupport.appendingPathComponent(Self.schemaMarkerFilename)
            let existingContents = (try? FileManager.default.contentsOfDirectory(atPath: appSupport.path)) ?? []
            let modelURL = appSupport.appendingPathComponent(Self.embeddingModelFilename)
            let databaseExists = existingContents.contains { $0 != Self.schemaMarkerFilename && $0 != Self.embeddingModelFilename }
            let markerVersion = (try? String(contentsOf: markerURL, encoding: .utf8))
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let storedModel = (try? String(contentsOf: modelURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            switch Self.schemaGateAction(markerVersion: markerVersion, databaseExists: databaseExists, storedEmbeddingModel: storedModel) {
            case .openAsIs, .stampOnly:
                break
            case .leaveNewerUntouched:
                throw NewerSchemaOnDisk(version: markerVersion ?? 0)
            case .wipeAndStamp:
                Self.quarantineSupersededStore(
                    at: appSupport,
                    previousVersion: markerVersion,
                    logger: logger,
                    reason: markerVersion == Self.currentSchemaVersion
                        ? "it was embedded by a different model ('\(storedModel ?? "?")', this build uses '\(EmbeddingService.modelIdentifier)') — its vectors are not comparable"
                        : nil
                )
            }

            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true, attributes: nil)

            if storedModel != EmbeddingService.modelIdentifier || markerVersion != Self.currentSchemaVersion {
                do {
                    try EmbeddingService.modelIdentifier.write(to: modelURL, atomically: true, encoding: .utf8)
                } catch {
                    logger.error("[RAG] Vector store: failed recording the embedding model (\(error.localizedDescription)). CONSEQUENCE: a later model swap could not be detected for this store, and its vectors would be mixed with incomparable ones.")
                }
            }
            if markerVersion != Self.currentSchemaVersion {
                do {
                    try String(Self.currentSchemaVersion).write(to: markerURL, atomically: true, encoding: .utf8)
                } catch {
                    logger.error("[RAG] Vector store: failed writing schema marker (\(error.localizedDescription)). CONSEQUENCE: the next launch finds a database with no marker and sets it aside as an unreadable schema, starting an empty index.")
                }
            }

            let store = try Store(directoryPath: appSupport.path, maxDbSizeInKByte: Self.maxDatabaseSizeKB)
            self.backing = Backing(
                store: store,
                parentBox: store.box(for: ParentDocumentEntity.self),
                childBox: store.box(for: ChildChunkEntity.self)
            )

            logger.info("[RAG] Vector store open (HNSW). DB path: \(appSupport.path)")
        } catch {
            // Degrade, do not trap: this runs on the cold launch path, and the vector index is a secondary store
            // whose failure must not take the whole app down.
            self.backing = nil
            logger.critical(
                "[STARTUP] VectorStoreService FAILED to initialize — \(error). CONSEQUENCE: semantic "
                + "retrieval (RAG over conversation memory and knowledge sources) is DISABLED for this "
                + "launch and every query returns no matches; chats, profiles, tools and workflows are "
                + "unaffected. The on-disk vector-db was NOT deleted. Previously this crashed the app "
                + "at launch."
            )
        }
    }

    #if DEBUG
    /// Test-only: a private store at `directory` with its own size cap, so the store-full path can be driven without
    /// filling the shared store. No schema gate, no marker.
    init(testDirectory directory: URL, maxDatabaseSizeKB: UInt64) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try Store(directoryPath: directory.path, maxDbSizeInKByte: maxDatabaseSizeKB)
        self.backing = Backing(store: store,
                               parentBox: store.box(for: ParentDocumentEntity.self),
                               childBox: store.box(for: ChildChunkEntity.self))
    }

    /// Test-only: whether a `dbFull` has latched writes off.
    var isLatchedFullForTesting: Bool { writeLock.withLock { storeIsFull } }

    /// Test-only: the parent rows for one source in one conversation, as (id, text) — so a test can
    /// tell WHICH copy of a source survived a replace.
    func parentTextsForTesting(sourceIdentifier: String, conversationID: UUID) throws -> [String] {
        guard let backing else { return [] }
        return try backing.parentBox.query { ParentDocumentEntity.sourceIdentifier == sourceIdentifier }
            .build().find()
            .filter { $0.conversationID == conversationID }
            .map(\.fullTextContent)
    }
    #endif

    // Why: Never `removeItem` here: the store's semantic memory cannot be rebuilt and a silent launch-time delete is
    // irreversible.
    /// Moves a superseded vector-db aside instead of deleting it; static so it is testable without the singleton.
    /// Exactly one superseded generation is kept under a fixed `-superseded` name, bounding disk usage.
    static func quarantineSupersededStore(at storeURL: URL, previousVersion: Int?, logger: DGLogger, reason: String? = nil) {
        let fileManager = FileManager.default
        let supersededURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent(storeURL.lastPathComponent + "-superseded", isDirectory: true)
        let bytes = directorySize(at: storeURL)

        do {
            if fileManager.fileExists(atPath: supersededURL.path) {
                try fileManager.removeItem(at: supersededURL)
            }
            if fileManager.fileExists(atPath: storeURL.path) {
                try fileManager.moveItem(at: storeURL, to: supersededURL)
            }
            let why = reason ?? "its schema (\(previousVersion.map(String.init) ?? "unmarked")) is not v\(currentSchemaVersion)"
            logger.warning(
                "[RAG] The on-disk vector store cannot be used: \(why) — moved \(bytes) bytes ASIDE to "
                + "\(supersededURL.lastPathComponent) and starting a fresh index. CONSEQUENCE: semantic "
                + "recall of existing turns is gone until they are re-indexed by new activity, and "
                + "there is no reindex-from-transcripts mechanism — but the old index is on disk, not "
                + "deleted, and one superseded generation is retained."
            )
        } catch {
            // Falling back to a delete would give up the irreversibility guarantee, so refuse and leave the old index in place.
            // Opening it under the new schema may then fail, which degrades rather than traps.
            logger.error(
                "[RAG] Could not move the superseded vector-db aside (\(error)). CONSEQUENCE: the old "
                + "index is left in place and NOT deleted; opening it under the new schema may fail, "
                + "in which case retrieval is disabled for this launch."
            )
        }
    }

    /// Total bytes under a directory, for the quarantine log line. Best-effort: a failure to
    /// enumerate reports 0 rather than blocking the launch path.
    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: - Public API

    /// Outcome of writing one source's vectors.
    enum WriteOutcome: Equatable {
        case written
        /// The store is at its size cap. Nothing changed — a replace keeps the PRIOR vectors.
        case storeFull
        /// The conversation was deleted this session — writing would resurrect its memory.
        case conversationDeleted
        case storeUnavailable
        case failed
    }

    // Why: Add first, then remove: the reverse order loses the previous vectors when a full store fails the write.
    /// Writes one source's vectors (a message or attached file), replacing any earlier copy in the same conversation, in
    /// one transaction.
    /// Prior copies are found by id only (`findIds` plus the indexed relation), never by loading parents.
    @discardableResult
    func replaceSemanticDocument(parent: ParentDocumentEntity, children: [ChildChunkEntity]) -> WriteOutcome {
        let conversationKey = parent.conversationID.uuidString
        let source = parent.sourceIdentifier
        let tag = "conv \(conversationKey.prefix(8)) source \(source.isEmpty ? "(none)" : String(source.suffix(40)))"
        guard let backing else {
            logger.warning(
                "[RAG] Skipping index of \(children.count) chunk(s) for \(tag): the vector store is unavailable. "
                + "CONSEQUENCE: this content will not be retrievable by semantic search, and there is "
                + "no reindex-from-transcripts mechanism, so it stays unindexed until it is written "
                + "again on a launch where the store opens."
            )
            return .storeUnavailable
        }
        for child in children {
            child.parentDocument.target = parent
            child.conversationID = conversationKey
        }
        enum Gate { case full, deleted, written(parents: Int, chunks: UInt64) }
        do {
            // ONE lock acquisition decides and writes: the full latch, the tombstone and the
            // transaction cannot be separated by a delete.
            let gate: Gate = try writeLock.withLock {
                if storeIsFull { return .full }
                if deletedConversations.contains(conversationKey) { return .deleted }
                let replaced: (parents: Int, chunks: UInt64) = try backing.store.runInTransaction {
                // Prior copies of THIS source in THIS conversation — ids only.
                var priorParentIDs: [EntityId<ParentDocumentEntity>] = []
                if !source.isEmpty {
                    let sameSource = try backing.parentBox.query {
                        ParentDocumentEntity.sourceIdentifier == source
                    }.build().findIds()
                    if !sameSource.isEmpty {
                        let priorChunks = try backing.childBox.query {
                            ChildChunkEntity.conversationID == conversationKey
                                && Self.parentRelation.isIn(sameSource.map(\.value))
                        }.build().find()
                        priorParentIDs = Array(Set(priorChunks.compactMap { $0.parentDocument.targetId }))
                    }
                }
                try backing.childBox.put(children)
                guard !priorParentIDs.isEmpty else { return (0, 0) }
                let removedChunks = try backing.childBox.query {
                    Self.parentRelation.isIn(priorParentIDs.map(\.value))
                }.build().remove()
                try backing.parentBox.remove(priorParentIDs)
                return (priorParentIDs.count, removedChunks)
                }
                return .written(parents: replaced.parents, chunks: replaced.chunks)
            }
            let replaced: (parents: Int, chunks: UInt64)
            switch gate {
            case .full:
                logger.warning(
                    "[RAG] Vector store is FULL — \(children.count) chunk(s) for \(tag) refused without a write attempt. "
                    + "CONSEQUENCE: this content is not searchable; deleting conversations frees space and re-enables indexing."
                )
                return .storeFull
            case .deleted:
                logger.notice(
                    "[RAG] Not indexing \(children.count) chunk(s) for \(tag): the conversation was DELETED this session. "
                    + "CONSEQUENCE: none — its memory stays deleted (this write raced the delete and lost, as it must)."
                )
                return .conversationDeleted
            case .written(let parents, let chunks):
                replaced = (parents, chunks)
            }
            logger.debug("[RAG] Indexed \(children.count) chunk(s) for \(tag)\(replaced.parents > 0 ? " — replaced \(replaced.parents) prior copy(ies), \(replaced.chunks) chunk(s)" : "").")
            return .written
        } catch ObjectBoxError.dbFull(let message) {
            writeLock.withLock { storeIsFull = true }
            logger.error(
                "[RAG] Vector store FULL (cap \(Self.maxDatabaseSizeKB / 1024) MB) — \(children.count) chunk(s) for \(tag) NOT written: \(message). "
                + "CONSEQUENCE: new conversation memory and attachments are no longer searchable until space is freed; "
                + "the source's PREVIOUS vectors were kept (the replace is one transaction)."
            )
            Self.adviseStoreFull(conversationID: parent.conversationID)
            return .storeFull
        } catch {
            logger.error(
                "[RAG] Failed to index \(children.count) chunk(s) for \(tag): \(error.localizedDescription). "
                + "CONSEQUENCE: this content is not retrievable by semantic search; the source's previous "
                + "vectors, if any, were kept (the replace is one transaction)."
            )
            return .failed
        }
    }

    /// The chunk→parent relation as a QUERY property. Typed explicitly: inside a query closure
    /// `ChildChunkEntity.parentDocument` resolves to the instance `ToOne`, not the generated
    /// static property of the same name.
    private static var parentRelation: Property<ChildChunkEntity, Id, ParentDocumentEntity> {
        Property<ChildChunkEntity, Id, ParentDocumentEntity>.parentDocument
    }

    /// The store-full notice. Process-wide condition, surfaced in the conversation that hit it.
    private static func adviseStoreFull(conversationID: UUID) {
        Task { @MainActor in
            AdvisoryCenter.shared.post(Advisory(
                conversationID: conversationID,
                category: .knowledgeStoreFull,
                message: "Conversation memory is full — new messages and attached files are no longer "
                    + "being added to search. Delete old conversations to free space.",
                actionLabel: "Show Index",
                action: .revealInFinder(path: VectorStoreService.storeDirectoryPath),
                dedupeKey: "\(conversationID.uuidString)|knowledgeStoreFull"
            ))
        }
    }

    /// Finds the most relevant parent documents via the native HNSW index, closest first.
    /// `exclusion` parents are skipped during collection so they never occupy limit slots.
    /// Returns at most `limit` unique parents, scoped to `conversationID` when set.
    func findNearest(to queryEmbedding: [Float], queryText: String? = nil, limit: Int, conversationID: UUID?, exclusion: RetrievalExclusion = .none) -> [RetrievedDocument] {
        // Conversation-scoped retrieval is an exact scan, not the HNSW index: ObjectBox applies property
        // conditions after `nearestNeighbors` picks candidates, so foreign chunks could crowd them out.
        if let convID = conversationID {
            return findNearestInConversation(queryEmbedding: queryEmbedding, queryText: queryText, limit: limit, conversationID: convID, exclusion: exclusion)
        }

        guard let backing else {
            // Logged at error level here — this is the user-visible outage (a query silently
            // returning nothing), and it is the one call site a user action reaches directly.
            logger.error(
                "[RAG] Semantic search returned no results because the vector store is unavailable "
                + "for this launch. CONSEQUENCE: the agent answers without retrieved context, which "
                + "reads as forgetfulness rather than as an error."
            )
            return []
        }
        let childBox = backing.childBox

        do {
            // Global (unscoped) search keeps the HNSW graph — O(log N) over the corpus.
            let candidateCount = max(50, limit * 10)
            let query = try childBox.query {
                ChildChunkEntity.embedding.nearestNeighbors(
                    queryVector: queryEmbedding,
                    maxCount: candidateCount
                )
            }.build()

            // findWithScores() returns ObjectWithScore instances sorted ascending by cosine distance.
            // score = 0.0 → identical vectors; score = 2.0 → maximally dissimilar.
            let results: [ObjectWithScore<ChildChunkEntity>] = try query.findWithScores()

            if results.isEmpty {
                logger.debug("[RAG] HNSW search returned no candidates.")
                return []
            }

            var hits: [RetrievedDocument] = []
            var seenParentIDs: Set<Id> = []
            var scoresSummary: [String] = []

            for result in results {
                guard hits.count < limit else { break }

                // Early exit: results are sorted ascending, so once distance exceeds the threshold
                // every subsequent result will also fail.
                guard result.score <= maximumCosineDistance else { break }

                guard let parentID = result.object.parentDocument.targetId?.value,
                      seenParentIDs.insert(parentID).inserted,
                      let parent = result.object.parentDocument.target,
                      !exclusion.excludes(parent) else { continue }
                hits.append(RetrievedDocument(parent: parent, bestChunkText: result.object.chunkText, distance: result.score))
                scoresSummary.append(String(format: "d=%.3f", result.score))
            }

            logger.info("[RAG] HNSW: \(hits.count) documents retrieved ([\(scoresSummary.joined(separator: ", "))], maxDist: \(self.maximumCosineDistance)).")
            return hits

        } catch {
            logger.error("[RAG] HNSW vector search failed: \(error.localizedDescription). CONSEQUENCE: this search returns nothing.")
            return []
        }
    }

    /// Exact conversation-scoped search: fetch the conversation's chunks via the
    /// denormalised String key (an indexed property query, no vector work in the
    /// engine), then rank them in Swift. See `findNearest` for why this is NOT HNSW.
    private func findNearestInConversation(queryEmbedding: [Float], queryText: String?, limit: Int, conversationID: UUID, exclusion: RetrievalExclusion) -> [RetrievedDocument] {
        guard let backing else { return [] }   // `findNearest` already logged the outage once.
        let childBox = backing.childBox
        do {
            let chunks = try childBox.query {
                ChildChunkEntity.conversationID == conversationID.uuidString
            }.build().find()

            // This scan (fetch, dense, BM25, RRF) is synchronous and grows with the conversation, so it must not run on the main
            // thread.
            let onMainThread = Thread.isMainThread
            if onMainThread {
                logger.warning("[RAG] Conversation-memory scan ran on the MAIN thread — conv \(conversationID.uuidString.prefix(8)), \(chunks.count) chunk(s). CONSEQUENCE: the UI is frozen for the whole scan. Call `findNearest` from a nonisolated context.")
            }
            #if DEBUG
            Self.scanThreadObserver?(onMainThread)
            #endif

            guard !chunks.isEmpty else {
                logger.debug("[RAG] Conversation \(conversationID.uuidString.prefix(8)) has no indexed chunks.")
                return []
            }

            let hits = Self.rankConversationChunks(
                chunks,
                against: queryEmbedding,
                queryText: queryText,
                limit: limit,
                maximumDistance: maximumCosineDistance,
                exclusion: exclusion
            )
            logger.info("[RAG] Scoped scan (conv \(conversationID.uuidString.prefix(8))): \(hits.count) document(s) from \(chunks.count) chunk(s) (maxDist: \(self.maximumCosineDistance)).")
            return hits
        } catch {
            logger.error("[RAG] Scoped scan FAILED (conv \(conversationID.uuidString.prefix(8))): \(error.localizedDescription). CONSEQUENCE: no conversation memory this turn; the request goes out without it.")
            return []
        }
    }

    #if DEBUG
    /// Test-only totals, so a test can prove a delete removed PARENTS too — not just the chunks a
    /// conversation-scoped search would show.
    func documentCountsForTesting() throws -> (parents: Int, chunks: Int) {
        guard let backing else { return (0, 0) }
        return (try backing.parentBox.count(), try backing.childBox.count())
    }

    /// Test hook: called with `Thread.isMainThread` for every conversation-scoped scan, to prove the send path keeps it off
    /// the main thread.
    nonisolated(unsafe) static var scanThreadObserver: (@Sendable (_ onMainThread: Bool) -> Void)?
    #endif

    // MARK: - Ranking (hybrid: dense + BM25, fused by rank)

    /// BM25 term-frequency saturation (k1) and length normalization (b) — the
    /// standard Robertson/Lucene defaults.
    static let bm25K1 = 1.2
    static let bm25B = 0.75

    /// RRF dampening constant (Cormack et al.). Flattens the reciprocal curve so
    /// rank 1 doesn't crush rank 4 — a chunk that's decent in BOTH engines beats
    /// one that tops a single list while being absent from the other.
    static let rrfK = 60.0

    private static let rankingLogger = DGLogger(category: "VectorStoreService")

    /// Ranks a conversation's chunks with hybrid retrieval: cosine distance fused with BM25 via Reciprocal Rank Fusion.
    /// Ranks, not raw scores, are fused; the router stays dense-only when the query has no distinctive lexical signal.
    /// The distance threshold stays the sanity gate, except a verbatim identifier-token hit admits a chunk past it.
    static func rankConversationChunks(
        _ chunks: [ChildChunkEntity],
        against queryEmbedding: [Float],
        queryText: String? = nil,
        limit: Int,
        maximumDistance: Double,
        exclusion: RetrievalExclusion = .none,
        resolveParent: (ChildChunkEntity) -> ParentDocumentEntity? = { $0.parentDocument.target }
    ) -> [RetrievedDocument] {
        // Dense engine — always on.
        var candidates: [(chunk: ChildChunkEntity, distance: Double)] = []
        candidates.reserveCapacity(chunks.count)
        for chunk in chunks {
            guard let embedding = chunk.embedding, embedding.count == queryEmbedding.count else { continue }
            candidates.append((chunk, 1.0 - Double(VectorMath.dotProduct(embedding, queryEmbedding))))
        }
        guard !candidates.isEmpty else { return [] }

        // Lexical engine + fusion router.
        let query = queryText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lexical = query.isEmpty
            ? (scores: [Double](repeating: 0, count: candidates.count), distinctive: false)
            : bm25Analysis(queryText: query, documents: candidates.map { bm25Document(stored: $0.chunk) })

        let ordered: [(index: Int, distance: Double, bm25: Double)]
        if lexical.distinctive {
            ordered = fuseByRRF(distances: candidates.map(\.distance), bm25: lexical.scores)
            let top = ordered.prefix(3)
                .map { String(format: "d=%.3f bm25=%.2f", $0.distance, $0.bm25) }
                .joined(separator: " | ")
            rankingLogger.info("Hybrid rank: BM25 fusion ON — top [\(top)]")
        } else {
            ordered = candidates.indices
                .sorted { candidates[$0].distance < candidates[$1].distance }
                .map { ($0, candidates[$0].distance, 0.0) }
        }

        // Injection gate + identifier exception lane (see doc above).
        let identifierWords = lexical.distinctive ? lexicalTokens(from: query).filter(isIdentifierLike) : []

        var hits: [RetrievedDocument] = []
        // Every parent is decided once, keyed by id: resolving `parentDocument.target` decodes the whole
        // `fullTextContent`, so a per-candidate resolve would re-decode a large attachment.
        var decidedParentIDs: Set<Id> = []
        for entry in ordered {
            guard hits.count < limit else { break }
            let candidate = candidates[entry.index]
            if candidate.distance > maximumDistance {
                // Dense-only order is ascending by distance and has no exception lane, so
                // nothing after the first past-threshold candidate can pass either.
                guard lexical.distinctive else { break }
                guard !identifierWords.isEmpty,
                      lexicalBoost(tokens: identifierWords, chunkText: candidate.chunk.chunkText) >= 0.7
                else { continue }
            }
            guard let parentID = candidate.chunk.parentDocument.targetId?.value,
                  decidedParentIDs.insert(parentID).inserted,
                  let parent = resolveParent(candidate.chunk) else { continue }
            // Excluded parents (carried in full, this turn's files, or after a Redo boundary) are skipped here, before they can
            // claim a limit slot.
            guard !exclusion.excludes(parent) else { continue }
            hits.append(RetrievedDocument(parent: parent, bestChunkText: candidate.chunk.chunkText, distance: candidate.distance))
        }
        return hits
    }

    /// A chunk's BM25 view: its tokens space-delimited with a leading and trailing space (so a
    /// whole-token match is the byte search `" term "`), and its token count.
    struct BM25Document: Sendable, Equatable {
        let terms: String
        let length: Int
    }

    /// Tokenises once — at chunk construction (`ChildChunkEntity.bm25Terms`), not per send.
    static func bm25Document(for text: String) -> BM25Document {
        let tokens = bm25Tokens(from: text)
        return BM25Document(terms: tokens.isEmpty ? "" : " " + tokens.joined(separator: " ") + " ",
                            length: tokens.count)
    }

    /// The stored view, or — for a row written before `bm25Terms` existed — one computed now.
    static func bm25Document(stored chunk: ChildChunkEntity) -> BM25Document {
        if chunk.bm25Terms.isEmpty, !chunk.chunkText.isEmpty { return bm25Document(for: chunk.chunkText) }
        return BM25Document(terms: chunk.bm25Terms, length: chunk.bm25Length)
    }

    /// BM25 scores for each chunk against the query, plus the fusion-router verdict.
    /// Document frequencies come from the ranked set. A distinctive lexical signal means a query word occurs in the
    /// corpus and is identifier-like or rare (in at most 25% of chunks).
    static func bm25Analysis(queryText: String, chunkTexts: [String]) -> (scores: [Double], distinctive: Bool) {
        bm25Analysis(queryText: queryText, documents: chunkTexts.map(bm25Document(for:)))
    }

    /// Counts only the query's terms in each chunk: BM25 needs only per-chunk term frequency, document frequency and lengths,
    /// so scores equal the full-tokenising version at a fraction of the cost.
    static func bm25Analysis(queryText: String, documents: [BM25Document]) -> (scores: [Double], distinctive: Bool) {
        var scores = [Double](repeating: 0, count: documents.count)
        guard !documents.isEmpty else { return (scores, false) }

        let queryTokens = Set(bm25Tokens(from: queryText)).sorted()
        let routerWords = lexicalTokens(from: queryText)
        // Every term whose frequencies are needed: the scored tokens and the router's words.
        let terms = Array(Set(queryTokens).union(routerWords.map { $0.lowercased() }))
        let needles = terms.map { Array(" \($0) ".utf8) }

        // frequencies[d][t] = occurrences of terms[t] in documents[d]
        var frequencies = [[Int]](repeating: [Int](repeating: 0, count: terms.count), count: documents.count)
        var documentFrequency = [Int](repeating: 0, count: terms.count)
        for (d, document) in documents.enumerated() where document.length > 0 {
            var haystack = document.terms
            haystack.withUTF8 { bytes in
                for (t, needle) in needles.enumerated() {
                    let count = occurrences(of: needle, in: bytes)
                    frequencies[d][t] = count
                    if count > 0 { documentFrequency[t] += 1 }
                }
            }
        }

        let corpusSize = Double(documents.count)
        let averageLength = max(1.0, Double(documents.reduce(0) { $0 + $1.length }) / corpusSize)
        let termIndex = Dictionary(uniqueKeysWithValues: terms.enumerated().map { ($1, $0) })

        if !queryTokens.isEmpty {
            var idf: [Int: Double] = [:]
            for term in queryTokens {
                let t = termIndex[term]!
                guard documentFrequency[t] > 0 else { continue }
                let df = Double(documentFrequency[t])
                idf[t] = log(1.0 + (corpusSize - df + 0.5) / (df + 0.5))
            }
            for (d, document) in documents.enumerated() where document.length > 0 {
                let lengthNorm = 1.0 - bm25B + bm25B * Double(document.length) / averageLength
                var score = 0.0
                for term in queryTokens {
                    let t = termIndex[term]!
                    guard let weight = idf[t], frequencies[d][t] > 0 else { continue }
                    let frequency = Double(frequencies[d][t])
                    score += weight * (frequency * (bm25K1 + 1.0)) / (frequency + bm25K1 * lengthNorm)
                }
                scores[d] = score
            }
        }

        let distinctive = routerWords.contains { word in
            guard let t = termIndex[word.lowercased()] else { return false }
            let df = documentFrequency[t]
            return df >= 1 && (isIdentifierLike(word) || isRare(documentFrequency: df, corpusSize: documents.count))
        }
        return (scores, distinctive)
    }

    /// Fewest chunks for which 'in at most 25% of them' means anything; below it every word in one chunk would count as rare.
    /// Identifier-like tokens still fuse at any size.
    static let minimumCorpusForRarity = 8

    static func isRare(documentFrequency df: Int, corpusSize: Int) -> Bool {
        corpusSize >= minimumCorpusForRarity && 4 * df <= corpusSize
    }

    /// Non-overlapping-safe count of `needle` (`" term "`) in `haystack`. Consecutive tokens
    /// share a delimiter (`" a a "` holds `" a "` twice), so the search resumes ON the match's
    /// trailing space.
    static func occurrences(of needle: [UInt8], in haystack: UnsafeBufferPointer<UInt8>) -> Int {
        guard let base = haystack.baseAddress, needle.count > 0, haystack.count >= needle.count else { return 0 }
        return needle.withUnsafeBytes { (needleBytes: UnsafeRawBufferPointer) -> Int in
            let start = UnsafeRawPointer(base)
            var count = 0
            var offset = 0
            while offset <= haystack.count - needle.count {
                guard let hit = memmem(start + offset, haystack.count - offset,
                                       needleBytes.baseAddress, needle.count) else { break }
                count += 1
                let matchAt: Int = start.distance(to: UnsafeRawPointer(hit))
                offset = matchAt + needle.count - 1
            }
            return count
        }
    }

    /// Lowercased BM25 token stream: whole words plus camelCase/snake_case sub-parts, so partial-term queries still match.
    /// No stopword list: IDF is the stopword filter.
    static func bm25Tokens(from text: String) -> [String] {
        var tokens: [String] = []
        for word in text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }) {
            guard word.count >= 2 else { continue }
            tokens.append(word.lowercased())
            let parts = identifierParts(of: String(word))
            if parts.count > 1 {
                for part in parts where part.count >= 2 { tokens.append(part.lowercased()) }
            }
        }
        return tokens
    }

    /// Splits an identifier at underscores and camel humps: "FileSystemItem" →
    /// File/System/Item, "num_ctx" → num/ctx, "JSONValue" → JSON/Value.
    static func identifierParts(of word: String) -> [String] {
        var parts: [String] = []
        var current = ""
        let characters = Array(word)
        for (index, character) in characters.enumerated() {
            if character == "_" {
                if !current.isEmpty { parts.append(current); current = "" }
                continue
            }
            if !current.isEmpty, character.isUppercase {
                let previous = characters[index - 1]
                let nextIsLowercase = index + 1 < characters.count && characters[index + 1].isLowercase
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && nextIsLowercase) {
                    parts.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Reciprocal Rank Fusion: score(chunk) = sum over engines of 1/(rrfK + rank); a chunk absent from the lexical list
    /// adds one term.
    /// Ties break toward lexical strength, then semantic distance.
    static func fuseByRRF(distances: [Double], bm25: [Double]) -> [(index: Int, distance: Double, bm25: Double)] {
        var denseRank: [Int: Int] = [:]
        for (rank, index) in distances.indices.sorted(by: { distances[$0] < distances[$1] }).enumerated() {
            denseRank[index] = rank
        }
        var lexicalRank: [Int: Int] = [:]
        for (rank, index) in bm25.indices.filter({ bm25[$0] > 0 }).sorted(by: { bm25[$0] > bm25[$1] }).enumerated() {
            lexicalRank[index] = rank
        }

        var fusedScores = [Double](repeating: 0, count: distances.count)
        for index in distances.indices {
            var score = 1.0 / (rrfK + Double(denseRank[index]! + 1))
            if let lexical = lexicalRank[index] {
                score += 1.0 / (rrfK + Double(lexical + 1))
            }
            fusedScores[index] = score
        }
        return distances.indices
            .sorted {
                if fusedScores[$0] != fusedScores[$1] { return fusedScores[$0] > fusedScores[$1] }
                if bm25[$0] != bm25[$1] { return bm25[$0] > bm25[$1] }
                return distances[$0] < distances[$1]
            }
            .map { ($0, distances[$0], bm25[$0]) }
    }

    /// Query words worth exact-matching: identifier characters only, ≥4 chars,
    /// minus filler words that would light up every chunk.
    static func lexicalTokens(from query: String) -> [String] {
        let stopwords: Set<String> = [
            "what", "tell", "about", "this", "that", "explain", "method", "function",
            "file", "code", "does", "mean", "show", "where", "when", "which", "with",
            "from", "have", "attached", "please", "describe"
        ]
        return query
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
            .map(String.init)
            .filter { $0.count >= 4 && !stopwords.contains($0.lowercased()) }
    }

    /// True for tokens that look like source identifiers (camelCase hump, underscore,
    /// or a digit) — an exact hit on one of these is a very strong relevance signal.
    static func isIdentifierLike(_ token: String) -> Bool {
        guard token.count >= 6 else { return false }
        return token.contains("_")
            || token.dropFirst().contains(where: \.isUppercase)
            || token.contains(where: \.isNumber)
    }

    /// Strongest single-token containment signal in 0...1: identifier-like tokens score 1.0 (0.7 case-insensitive), plain
    /// words 0.35.
    /// Serves the threshold exception lane: `rankConversationChunks` admits a past-threshold chunk at 0.7 or more.
    static func lexicalBoost(tokens: [String], chunkText: String) -> Double {
        var best = 0.0
        var chunkLower: String?
        for token in tokens {
            let strength = isIdentifierLike(token) ? 1.0 : 0.35
            guard strength > best else { continue }
            if chunkText.contains(token) {
                best = strength
                continue
            }
            if chunkLower == nil { chunkLower = chunkText.lowercased() }
            if chunkLower?.contains(token.lowercased()) == true {
                best = max(best, strength * 0.7)
            }
        }
        return best
    }

    // MARK: - Deletion (store hygiene)

    /// Removes one conversation's chunks and their parents. Call inside a write transaction.
    private static func removeRows(ofConversation key: String, childBox: Box<ChildChunkEntity>,
                                   parentBox: Box<ParentDocumentEntity>) throws -> (chunks: UInt64, parents: UInt64) {
        let childQuery = try childBox.query { ChildChunkEntity.conversationID == key }.build()
        // Derive parents from the denormalised children: `parent.conversationID` is a converted UUID (stored as String),
        // so querying the plain-String child key avoids the converter.
        let children = try childQuery.find()
        guard !children.isEmpty else { return (0, 0) }
        // Parent ids, never parents: `target` decodes each parent's whole text once per chunk.
        let parentIDs = Set(children.compactMap { $0.parentDocument.targetId?.value })
        let removedChildren = try childQuery.remove()
        let removedParents = try parentBox.remove(Array(parentIDs))
        return (removedChildren, removedParents)
    }

    // Why: An empty `liveConversationIDs` is refused: it more likely means a store that did not load than a user who deleted
    // everything.
    /// Removes conversation memory whose conversation is gone (crash between the two deletes, or a write that raced a
    /// delete).
    /// Destructive: the launch sweep runs it only when the schema is unchanged. Returns the number of conversations removed.
    @discardableResult
    func removeOrphanedConversations(liveConversationIDs: Set<UUID>) -> Int {
        guard let backing else { return 0 }
        guard !liveConversationIDs.isEmpty else {
            logger.warning("[RAG] Orphan sweep SKIPPED — the conversation list is empty. CONSEQUENCE: none now; vectors of conversations deleted without cleanup (if any) stay on disk until a launch that sees at least one conversation.")
            return 0
        }
        let live = Set(liveConversationIDs.map(\.uuidString))
        do {
            let swept: (conversations: Int, chunks: UInt64, parents: UInt64) = try writeLock.withLock {
                try backing.store.runInTransaction {
                    let stored = try backing.childBox.query().build()
                        .property(ChildChunkEntity.conversationID).distinct().findStrings()
                    let orphans = stored.filter { !live.contains($0) }
                    var chunks: UInt64 = 0, parents: UInt64 = 0
                    for key in orphans {
                        deletedConversations.insert(key)
                        let removed = try Self.removeRows(ofConversation: key, childBox: backing.childBox, parentBox: backing.parentBox)
                        chunks += removed.chunks
                        parents += removed.parents
                    }
                    return (orphans.count, chunks, parents)
                }
            }
            if swept.conversations > 0 {
                logger.notice("[RAG] Orphan sweep removed memory of \(swept.conversations) deleted conversation(s): \(swept.chunks) chunk(s), \(swept.parents) parent(s). CONSEQUENCE: their content can no longer be retrieved by any search.")
            } else {
                logger.info("[RAG] Orphan sweep: every indexed conversation still exists (\(live.count) live).")
            }
            return swept.conversations
        } catch {
            logger.error("[RAG] Orphan sweep FAILED: \(error.localizedDescription). CONSEQUENCE: memory of deleted conversations, if any, stays on disk until the next sweep.")
            return 0
        }
    }

    /// Deletes all vector data belonging to a conversation (child chunks and parent documents), called when the
    /// conversation is deleted.
    func deleteDocuments(forConversation conversationID: UUID) {
        guard let backing else {
            logger.warning(
                "[RAG] Cannot delete indexed documents for conversation "
                + "\(conversationID.uuidString.prefix(8)): the vector store is unavailable. "
                + "CONSEQUENCE: the conversation's vectors REMAIN on disk after it was deleted, and "
                + "will be retrievable again on a launch where the store opens."
            )
            return
        }
        let childBox = backing.childBox
        let parentBox = backing.parentBox
        do {
            let convIDString = conversationID.uuidString
            // One transaction, behind the write lock (see `writeLock`): a delete racing an
            // indexer is exactly the concurrent-writer shape that deadlocked.
            let removed: (chunks: UInt64, parents: UInt64) = try writeLock.withLock {
                // Tombstone first, under the same lock every write checks.
                deletedConversations.insert(convIDString)
                return try backing.store.runInTransaction {
                    try Self.removeRows(ofConversation: convIDString, childBox: childBox, parentBox: parentBox)
                }
            }
            guard removed.chunks > 0 else { return }
            let wasFull = writeLock.withLock { () -> Bool in
                defer { storeIsFull = false }
                return storeIsFull
            }
            if wasFull {
                logger.notice("[RAG] Vector store had been FULL — a conversation delete freed space, so indexing is re-enabled. (conv \(convIDString.prefix(8)))")
            }
            logger.info("[RAG] Deleted conversation memory (conv \(convIDString.prefix(8))): \(removed.chunks) chunk(s) + \(removed.parents) parent(s).")
        } catch {
            logger.error("[RAG] Deleting conversation memory FAILED (conv \(conversationID.uuidString.prefix(8))): \(error.localizedDescription). CONSEQUENCE: its vectors stay on disk — the next launch's orphan sweep removes them once the conversation itself is gone; it is tombstoned, so nothing new is written for it this launch.")
        }
    }

}

/// Failures resolving the vector store's location, before ObjectBox is involved.
enum VectorStoreLocationError: LocalizedError {
    case bundleIdentifierUnavailable

    var errorDescription: String? {
        switch self {
        case .bundleIdentifierUnavailable:
            return "The application bundle identifier could not be read, so the search index location cannot be resolved."
        }
    }
}

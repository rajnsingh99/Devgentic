//
//  VectorStoreService.swift
//  Devgentic
//
//  Created by Raj Singh on 13/07/25.
//

import Foundation
import ObjectBox
import os

// MARK: - Retrieval Result

/// A retrieval hit: the parent document plus the best-matching chunk that surfaced
/// it. Callers window the injected text AROUND the matched chunk instead of blindly
/// taking the document head — a whole-file parent clamped to its first 8K chars
/// loses any match past that point (the exact failure seen in manual testing:
/// symbols in a file's first ~8K chars answered fine, later ones "not found").
struct RetrievedDocument {
    let parent: ParentDocumentEntity
    /// Text of the closest chunk — the anchor for centered injection windows.
    let bestChunkText: String
    /// Raw cosine distance of the best chunk — the pure semantic signal. Hybrid
    /// BM25 fusion reorders results but never mutates this value.
    let distance: Double
}

// MARK: - Vector Store Service

/// A service for managing the vector database using ObjectBox with a native HNSW index.
///
/// Search complexity is reduced from O(N) brute-force cosine similarity to O(log N) via ObjectBox's
/// probabilistic Hierarchical Navigable Small World graph, configured for the 384-dimensional
/// All-MiniLM-L6-v2 embedding space.  See `ChildChunkEntity` for index hyperparameter rationale.
final class VectorStoreService: @unchecked Sendable {

    // MARK: - Singleton Instance
    static let shared = VectorStoreService()

    // MARK: - Private Properties
    private let store: Store
    private let parentBox: Box<ParentDocumentEntity>
    private let childBox: Box<ChildChunkEntity>
    private let logger = DGLogger(category: "VectorStoreService")

    // MARK: - HNSW Search Constants

    /// Cosine distance threshold (= 1 − cosine_similarity).
    /// L2-normalised vectors from EmbeddingService ensure cosine_distance = 1 − dot_product.
    /// Equivalent to the previous similarity threshold of 0.3 (distance ≤ 0.7 → similarity ≥ 0.3).
    private let maximumCosineDistance: Double = 0.7

    // MARK: - Schema Versioning

    /// Current on-disk schema generation. Bump ONLY for representational changes
    /// ObjectBox cannot auto-migrate (additive property changes need no bump —
    /// `sourceIdentifier` was added without one). 3 = native [Float] embedding +
    /// HNSW index (the "Phase 3" schema).
    static let currentSchemaVersion = 3

    /// Marker file INSIDE the vector-db directory. The wipe decision keys on this,
    /// not on preferences: a UserDefaults flag lives beside the data and can
    /// desynchronize from it (defaults reset, partial backup restore) — a lost
    /// flag silently WIPED a healthy database. Tolerable when this store was a
    /// disposable cache; not now that it holds every conversation's memory.
    private static let schemaMarkerFilename = "schema-version"

    /// Legacy UserDefaults gates, superseded by the marker. Read ONCE so existing
    /// installs (already on the v3 schema, proven by the Phase-3 flag) get stamped
    /// WITHOUT wiping; removed only after the marker is safely on disk.
    private static let legacyPhase2Key = "Phase2_VectorDB_Wiped"
    private static let legacyPhase3Key = "Phase3_HNSW_Schema_Migrated"

    /// What init should do about the on-disk schema. Pure — extracted for tests.
    enum SchemaGateAction: Equatable {
        /// Marker matches the current schema: open, touch nothing.
        case openAsIs
        /// Fresh directory, or a legacy-flagged install already on the current
        /// schema: write the marker, wipe nothing.
        case stampOnly
        /// Unreadable schema (older, unmarked-and-unflagged, or from a NEWER
        /// build): destroy and rebuild — the only lossy path, and it's loud.
        case wipeAndStamp
    }

    static func schemaGateAction(markerVersion: Int?, databaseExists: Bool, legacyPhase3Flag: Bool) -> SchemaGateAction {
        if markerVersion == currentSchemaVersion { return .openAsIs }
        guard databaseExists else { return .stampOnly }
        return (markerVersion == nil && legacyPhase3Flag) ? .stampOnly : .wipeAndStamp
    }

    // MARK: - Initialization

    /// Private initializer to set up the ObjectBox store and entity box.
    ///
    /// ⚠️ HNSW migration note: If migrating a large pre-existing dataset, the ObjectBox engine
    /// compiles the full HNSW graph on first open (O(N·log N) complexity). For >100k vectors this
    /// should be moved to a background Task with a "Optimizing database…" UI gate to avoid an
    /// iOS Jetsam watchdog kill. For fresh installs (and after the Phase 3 wipe below) the DB
    /// is empty so graph compilation is instantaneous.
    private init() {
        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
                .appendingPathComponent(Bundle.main.bundleIdentifier!)
                .appendingPathComponent("vector-db")

            // --- SCHEMA GATE (in-directory marker, not preferences) ---
            // Replaces the Phase 2/3 UserDefaults-gated wipes: the destroy decision
            // now keys on a version marker stored WITH the data, so it physically
            // cannot disagree with it. Existing installs (already on the current
            // schema, proven by the legacy Phase-3 flag) are stamped without wiping.
            let markerURL = appSupport.appendingPathComponent(Self.schemaMarkerFilename)
            let existingContents = (try? FileManager.default.contentsOfDirectory(atPath: appSupport.path)) ?? []
            let databaseExists = existingContents.contains { $0 != Self.schemaMarkerFilename }
            let markerVersion = (try? String(contentsOf: markerURL, encoding: .utf8))
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

            switch Self.schemaGateAction(
                markerVersion: markerVersion,
                databaseExists: databaseExists,
                legacyPhase3Flag: UserDefaults.standard.bool(forKey: Self.legacyPhase3Key)
            ) {
            case .openAsIs:
                break
            case .stampOnly:
                if databaseExists {
                    logger.info("Vector store: current-schema database predates the marker (legacy flag verified) — stamping v\(Self.currentSchemaVersion), no wipe.")
                }
            case .wipeAndStamp:
                // The only lossy path — and it's loud: conversation memory for
                // existing turns is gone and repopulates from new activity only
                // (there is no reindex-from-transcripts mechanism).
                logger.warning("Vector store: on-disk schema (\(markerVersion.map(String.init) ?? "unmarked")) is not v\(Self.currentSchemaVersion) — wiping vector-db for rebuild.")
                if FileManager.default.fileExists(atPath: appSupport.path) {
                    try FileManager.default.removeItem(at: appSupport)
                }
            }

            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true, attributes: nil)

            if markerVersion != Self.currentSchemaVersion {
                do {
                    try String(Self.currentSchemaVersion).write(to: markerURL, atomically: true, encoding: .utf8)
                    // Superseded — removed only now that the marker is safely on
                    // disk, so a failed write can never strand an install both
                    // flagless AND markerless (which would wipe it next launch).
                    UserDefaults.standard.removeObject(forKey: Self.legacyPhase2Key)
                    UserDefaults.standard.removeObject(forKey: Self.legacyPhase3Key)
                } catch {
                    logger.error("Vector store: failed writing schema marker (\(error.localizedDescription)); keeping legacy flags as the fallback gate.")
                }
            }

            self.store = try Store(directoryPath: appSupport.path)
            self.parentBox = self.store.box(for: ParentDocumentEntity.self)
            self.childBox = self.store.box(for: ChildChunkEntity.self)

            logger.info("VectorStoreService (HNSW) initialized. DB path: \(appSupport.path)")
        } catch {
            logger.critical("Failed to initialize VectorStoreService: \(error.localizedDescription)")
            fatalError("Could not initialize ObjectBox store: \(error)")
        }
    }

    // MARK: - Public API

    /// Adds a semantic parent document and its associated child chunks to the vector database.
    ///
    /// The child's `conversationID` is denormalised from the parent here so that HNSW result
    /// post-filtering can scope by conversation without an additional relation traversal per result.
    func addSemanticDocument(parent: ParentDocumentEntity, children: [ChildChunkEntity]) {
        do {
            let convIDString = parent.conversationID.uuidString
            for child in children {
                child.parentDocument.target = parent
                child.conversationID = convIDString
            }
            try childBox.put(children)
            logger.debug("Indexed \(children.count) HNSW child chunks for parent \(parent.sourceMessageID.uuidString).")
        } catch {
            logger.error("Failed to add semantic document to vector store: \(error.localizedDescription)")
        }
    }

    /// Finds the most semantically relevant parent documents using the native ObjectBox HNSW index.
    ///
    /// The HNSW graph reduces search from O(N) linear scan to O(log N) graph traversal.
    /// Results are returned in ascending distance order (ObjectBox guarantee); the first result
    /// is the closest match.  The search is optionally scoped to a single conversation via
    /// post-filtering on the denormalised `conversationID` field.
    ///
    /// - Parameters:
    ///   - queryEmbedding: L2-normalised 384-D vector from `EmbeddingService`.
    ///   - limit: Maximum number of unique parent documents to return.
    ///   - conversationID: If set, only chunks belonging to this conversation are considered.
    ///   - excludedParentMessageIDs: Parents with these sourceMessageIDs are skipped
    ///     DURING collection — they must not occupy limit slots. Post-filtering after
    ///     the cap starved a real turn to zero injected documents while an injectable
    ///     file chunk sat at rank 4: history ranks high precisely because BM25 loves
    ///     the query's own recent phrasing.
    /// - Returns: Relevant `ParentDocumentEntity` objects, ordered by semantic proximity.
    func findNearest(to queryEmbedding: [Float], queryText: String? = nil, limit: Int, conversationID: UUID?, excludedParentMessageIDs: Set<UUID> = []) -> [RetrievedDocument] {
        // Conversation-scoped retrieval (the only production path) uses an EXACT scan
        // over the conversation's own chunks, NOT the HNSW index. ObjectBox applies
        // property conditions AFTER `nearestNeighbors` selects its maxCount candidates
        // (pinned by VectorStoreHygieneTests), so a combined query inherits the same
        // crowd-out as the old Swift post-filter — foreign conversations' closer chunks
        // can push in-scope chunks out of the window entirely. A conversation's chunk
        // count is small (hundreds to low thousands), so the exact scan is fast, immune
        // to crowding by construction, and skips HNSW's approximation error.
        if let convID = conversationID {
            return findNearestInConversation(queryEmbedding: queryEmbedding, queryText: queryText, limit: limit, conversationID: convID, excludedParentMessageIDs: excludedParentMessageIDs)
        }

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
                logger.debug("HNSW search returned no candidates.")
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

                if let parent = result.object.parentDocument.target, !seenParentIDs.contains(parent.id) {
                    seenParentIDs.insert(parent.id)
                    guard !excludedParentMessageIDs.contains(parent.sourceMessageID) else { continue }
                    hits.append(RetrievedDocument(parent: parent, bestChunkText: result.object.chunkText, distance: result.score))
                    scoresSummary.append(String(format: "d=%.3f", result.score))
                }
            }

            logger.info("HNSW: \(hits.count) documents retrieved ([\(scoresSummary.joined(separator: ", "))], maxDist: \(self.maximumCosineDistance)).")
            return hits

        } catch {
            logger.error("HNSW vector search failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Exact conversation-scoped search: fetch the conversation's chunks via the
    /// denormalised String key (an indexed property query, no vector work in the
    /// engine), then rank them in Swift. See `findNearest` for why this is NOT HNSW.
    private func findNearestInConversation(queryEmbedding: [Float], queryText: String?, limit: Int, conversationID: UUID, excludedParentMessageIDs: Set<UUID>) -> [RetrievedDocument] {
        do {
            let chunks = try childBox.query {
                ChildChunkEntity.conversationID == conversationID.uuidString
            }.build().find()

            guard !chunks.isEmpty else {
                logger.debug("Scoped search: conversation has no indexed chunks.")
                return []
            }

            let hits = Self.rankConversationChunks(
                chunks,
                against: queryEmbedding,
                queryText: queryText,
                limit: limit,
                maximumDistance: maximumCosineDistance,
                excludedSourceMessageIDs: excludedParentMessageIDs
            )
            logger.info("Scoped scan: \(hits.count) documents from \(chunks.count) conversation chunks (maxDist: \(self.maximumCosineDistance)).")
            return hits
        } catch {
            logger.error("Scoped vector search failed: \(error.localizedDescription)")
            return []
        }
    }

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

    /// Ranks a conversation's chunks with HYBRID retrieval: cosine distance (dense
    /// engine) fused with BM25 (lexical engine) via Reciprocal Rank Fusion. Ranks —
    /// not raw scores — are fused: cosine distance ([0,2]) and BM25 ([0,∞)) are
    /// incomparable units, and rank-mixing needs none of the calibration that
    /// score-mixing would.
    ///
    /// The fusion router keeps the dense-only path when the query carries no
    /// distinctive lexical signal (no query word is rare or identifier-like within
    /// this conversation): BM25 over exclusively-common words is IDF-muted noise,
    /// and skipping fusion removes even the residual perturbation.
    ///
    /// The distance threshold stays the injection sanity gate, with one exception
    /// lane: a verbatim hit on an identifier-like query token admits a chunk past
    /// the threshold — symbol lookups are exact-match problems where the embedding
    /// is systematically wrong (MiniLM puts NL-question-vs-code pairs at sim 0.1–0.3).
    ///
    /// Pure ranking logic — static so tests can exercise it against a temp store's
    /// chunks directly. distance = 1 − dot product (embeddings are L2-normalised).
    static func rankConversationChunks(
        _ chunks: [ChildChunkEntity],
        against queryEmbedding: [Float],
        queryText: String? = nil,
        limit: Int,
        maximumDistance: Double,
        excludedSourceMessageIDs: Set<UUID> = []
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
            : bm25Analysis(queryText: query, chunkTexts: candidates.map { $0.chunk.chunkText })

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
        var seenParentIDs: Set<Id> = []
        for entry in ordered {
            guard hits.count < limit else { break }
            let candidate = candidates[entry.index]
            if candidate.distance > maximumDistance {
                guard !identifierWords.isEmpty,
                      lexicalBoost(tokens: identifierWords, chunkText: candidate.chunk.chunkText) >= 0.7
                else { continue }
            }
            if let parent = candidate.chunk.parentDocument.target, !seenParentIDs.contains(parent.id) {
                seenParentIDs.insert(parent.id)
                // Excluded (history/self) parents are skipped HERE, before they
                // can claim a limit slot — post-filtering after the cap let the
                // query's own echo + prior turns fill all three slots while the
                // injectable file chunk sat at rank 4 (2026-07-13 comparison log).
                guard !excludedSourceMessageIDs.contains(parent.sourceMessageID) else { continue }
                hits.append(RetrievedDocument(parent: parent, bestChunkText: candidate.chunk.chunkText, distance: candidate.distance))
            }
        }
        return hits
    }

    /// BM25 scores for each chunk against the query, plus the fusion-router
    /// verdict. Document frequencies are computed over the SAME candidate set
    /// being ranked — at conversation scale (hundreds of chunks) this costs
    /// ~a millisecond and needs no persisted term statistics.
    ///
    /// Router: the query has distinctive lexical signal when at least one query
    /// word actually occurs in the corpus AND is either identifier-like or rare
    /// (in ≤ 25% of chunks). "Rare" covers the chat case — proper nouns and
    /// codenames — that isIdentifierLike's shape rules can't see.
    static func bm25Analysis(queryText: String, chunkTexts: [String]) -> (scores: [Double], distinctive: Bool) {
        let chunkTermFrequencies: [[String: Int]] = chunkTexts.map { text in
            var frequencies: [String: Int] = [:]
            for token in bm25Tokens(from: text) { frequencies[token, default: 0] += 1 }
            return frequencies
        }
        var documentFrequency: [String: Int] = [:]
        for frequencies in chunkTermFrequencies {
            for term in frequencies.keys { documentFrequency[term, default: 0] += 1 }
        }
        let chunkLengths = chunkTermFrequencies.map { Double($0.values.reduce(0, +)) }
        let corpusSize = Double(chunkTexts.count)
        let averageLength = max(1.0, chunkLengths.reduce(0, +) / corpusSize)

        let queryTokens = Set(bm25Tokens(from: queryText)).sorted()
        var scores = [Double](repeating: 0, count: chunkTexts.count)
        guard !queryTokens.isEmpty else { return (scores, false) }

        var inverseDocumentFrequency: [String: Double] = [:]
        for term in queryTokens {
            guard let df = documentFrequency[term] else { continue }
            inverseDocumentFrequency[term] = log(1.0 + (corpusSize - Double(df) + 0.5) / (Double(df) + 0.5))
        }

        for (index, frequencies) in chunkTermFrequencies.enumerated() {
            guard chunkLengths[index] > 0 else { continue }
            let lengthNorm = 1.0 - bm25B + bm25B * chunkLengths[index] / averageLength
            var score = 0.0
            for term in queryTokens {
                guard let occurrences = frequencies[term], let idf = inverseDocumentFrequency[term] else { continue }
                let frequency = Double(occurrences)
                score += idf * (frequency * (bm25K1 + 1.0)) / (frequency + bm25K1 * lengthNorm)
            }
            scores[index] = score
        }

        let distinctive = lexicalTokens(from: queryText).contains { word in
            guard let df = documentFrequency[word.lowercased()], df >= 1 else { return false }
            return isIdentifierLike(word) || 4 * df <= max(4, chunkTexts.count)
        }
        return (scores, distinctive)
    }

    /// Lowercased BM25 token stream: whole words (split on non-identifier chars)
    /// PLUS camelCase/snake_case sub-parts — "addAttachedFiles" emits itself and
    /// add/attached/files, so partial-term queries still match while the intact
    /// identifier keeps its high-IDF dominance. No stopword list: IDF is the
    /// principled stopword filter (a term present in most chunks scores ≈ 0).
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

    /// Reciprocal Rank Fusion: score(chunk) = Σ over engines of 1/(rrfK + rank).
    /// A chunk absent from the lexical list (BM25 = 0) simply contributes one term.
    /// Perfectly crossed pairs tie by construction — ties break toward lexical
    /// strength (exact-match queries are why fusion exists), then semantic distance.
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

    /// Strongest single-token containment signal in 0...1: identifier-like tokens
    /// score 1.0 (0.7 case-insensitive), plain words 0.35. Since the BM25 fusion
    /// replaced score-blending, this serves the threshold EXCEPTION LANE only:
    /// rankConversationChunks admits a past-threshold chunk when an identifier
    /// token registers ≥ 0.7 here.
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

    /// Deletes ALL vector data belonging to a conversation — child chunks and their
    /// parent documents. Called when the conversation itself is deleted, so its
    /// memory dies with it. (Before this API the store was append-only: orphaned
    /// vectors survived conversation deletion forever, inflating every HNSW search.)
    func deleteDocuments(forConversation conversationID: UUID) {
        do {
            let convIDString = conversationID.uuidString
            let childQuery = try childBox.query {
                ChildChunkEntity.conversationID == convIDString
            }.build()

            // Derive parents from the denormalised children — parent.conversationID is
            // a converted UUID (stored as String), so going through the plain-String
            // child key avoids querying across the converter.
            let children = try childQuery.find()
            guard !children.isEmpty else { return }

            var parentsByID: [Id: ParentDocumentEntity] = [:]
            for child in children {
                if let parent = child.parentDocument.target {
                    parentsByID[parent.id] = parent
                }
            }

            let removedChildren = try childQuery.remove()
            try parentBox.remove(Array(parentsByID.values))
            logger.info("Vector cleanup: removed \(removedChildren) chunks + \(parentsByID.count) parents for conversation \(convIDString).")
        } catch {
            logger.error("Vector cleanup failed for conversation \(conversationID.uuidString): \(error.localizedDescription)")
        }
    }

    /// Deletes prior index entries for one source (a file path or message UUID) within
    /// a conversation — the replace-on-reindex primitive. Re-attaching a file or
    /// re-finalizing a message calls this before `addSemanticDocument`, so the same
    /// content never accumulates duplicate vectors that crowd the retrieval slots.
    /// Rows written before `sourceIdentifier` existed carry "" and are never matched.
    func removeDocuments(sourceIdentifier: String, conversationID: UUID) {
        guard !sourceIdentifier.isEmpty else { return }
        do {
            let matchingParents = try parentBox.query {
                ParentDocumentEntity.sourceIdentifier == sourceIdentifier
            }.build().find()
                .filter { $0.conversationID == conversationID }
            guard !matchingParents.isEmpty else { return }

            let parentIDs = Set(matchingParents.map(\.id))

            // Children carry the conversation key (plain String) — fetch the
            // conversation's chunks once and drop those pointing at the doomed parents.
            let conversationChildren = try childBox.query {
                ChildChunkEntity.conversationID == conversationID.uuidString
            }.build().find()
            let doomedChildren = conversationChildren.filter { child in
                guard let parent = child.parentDocument.target else { return false }
                return parentIDs.contains(parent.id)
            }

            try childBox.remove(doomedChildren)
            try parentBox.remove(matchingParents)
            logger.debug("Replace-on-reindex: removed \(matchingParents.count) prior parent(s) + \(doomedChildren.count) chunk(s) for source '\(sourceIdentifier)'.")
        } catch {
            logger.error("Replace-on-reindex removal failed for '\(sourceIdentifier)': \(error.localizedDescription)")
        }
    }
}

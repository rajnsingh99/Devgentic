// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  HybridRetrievalRankingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import ObjectBox
@testable import devgentic

final class HybridRetrievalRankingTests: XCTestCase {

    private var tempDir: URL!
    private var store: Store!
    private var childBox: Box<ChildChunkEntity>!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hybrid-ranking-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try Store(directoryPath: tempDir.path)
        childBox = store.box(for: ChildChunkEntity.self)
    }

    override func tearDownWithError() throws {
        store.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    /// A normalized 384-dim vector leaning off axis 0 by `lean` — larger lean =
    /// farther from the axis-0 query vector, in a controlled way.
    private func unitVector(lean: Float) -> [Float] {
        var v = [Float](repeating: 0, count: 384)
        v[0] = 1 - lean
        v[1] = lean
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / norm }
    }

    @discardableResult
    private func seed(conversation: UUID, embedding: [Float], text: String, sourceMessageID: UUID = UUID()) throws -> ChildChunkEntity {
        let parent = ParentDocumentEntity(
            sourceMessageID: sourceMessageID,
            conversationID: conversation,
            fullTextContent: text
        )
        let child = ChildChunkEntity(chunkText: text, embedding: embedding, chunkIndex: 0, conversationID: conversation.uuidString)
        child.parentDocument.target = parent
        try childBox.put(child)
        return child
    }

    private func conversationChunks(_ conversation: UUID) throws -> [ChildChunkEntity] {
        try childBox.query {
            ChildChunkEntity.conversationID == conversation.uuidString
        }.build().find()
    }

    // MARK: - 1. Tokenizer

    func testBM25Tokens_EmitsWholeIdentifierAndSubParts() {
        let tokens = VectorStoreService.bm25Tokens(from: "call addAttachedFiles with num_ctx")

        // Whole identifiers survive (lowercased) — their rarity is the high-IDF signal.
        XCTAssertTrue(tokens.contains("addattachedfiles"))
        XCTAssertTrue(tokens.contains("num_ctx"))
        // Sub-parts are also emitted so partial-term queries still match.
        for part in ["add", "attached", "files", "num", "ctx"] {
            XCTAssertTrue(tokens.contains(part), "missing sub-part token: \(part)")
        }
        // Everything is lowercased — matching is case-insensitive by construction.
        XCTAssertFalse(tokens.contains { $0 != $0.lowercased() })
    }

    func testIdentifierParts_CamelSnakeAndAcronymBoundaries() {
        XCTAssertEqual(VectorStoreService.identifierParts(of: "FileSystemItem"), ["File", "System", "Item"])
        XCTAssertEqual(VectorStoreService.identifierParts(of: "num_ctx"), ["num", "ctx"])
        XCTAssertEqual(VectorStoreService.identifierParts(of: "JSONValue"), ["JSON", "Value"])
        XCTAssertEqual(VectorStoreService.identifierParts(of: "plain"), ["plain"])
    }

    // MARK: - 2. BM25 ingredients

    func testBM25_RareTermOutweighsCommonTerm() {
        // "gadget" is in 1 of 6 chunks (high IDF); "file" is in 5 of 6 (low IDF).
        let chunks = [
            "gadget spec sheet",
            "file report file",
            "file summary notes",
            "file overview here",
            "file notes again",
            "file listing done"
        ]
        let scores = VectorStoreService.bm25Analysis(queryText: "gadget file", chunkTexts: chunks).scores

        let rareOnlyScore = scores[0]
        let bestCommonScore = scores.dropFirst().max() ?? 0
        XCTAssertGreaterThan(
            rareOnlyScore, bestCommonScore,
            "one hit on a rare term must outweigh hits on a corpus-common term"
        )
    }

    func testBM25_TermFrequencySaturatesSublinearly() {
        // Same length (10 tokens each); tf=5 vs tf=1 for the query term.
        let chunks = [
            "term a1 a2 a3 a4 a5 a6 a7 a8 a9",
            "term term term term term b1 b2 b3 b4 b5"
        ]
        let scores = VectorStoreService.bm25Analysis(queryText: "term", chunkTexts: chunks).scores

        XCTAssertGreaterThan(scores[1], scores[0], "more occurrences must still score higher")
        XCTAssertLessThan(scores[1], scores[0] * 2, "5× the occurrences must NOT score 5× (or even 2×) — saturation")
    }

    func testBM25_LengthNormalization_ShorterChunkScoresHigher() {
        // Same tf=1 for the query term; 2-token chunk vs 8-token chunk.
        let chunks = [
            "term alpha",
            "term beta gamma delta epsilon zeta eta theta"
        ]
        let scores = VectorStoreService.bm25Analysis(queryText: "term", chunkTexts: chunks).scores

        XCTAssertGreaterThan(scores[0], scores[1], "a hit in a short chunk must outrank the same hit in a long one")
    }

    // MARK: - 3. Fusion router

    func testRouter_CommonWordsOnly_NotDistinctive() {
        // "project" appears in every chunk — IDF-muted, no fusion signal.
        let chunks = ["project alpha", "project beta", "project gamma", "project delta"]
        let verdict = VectorStoreService.bm25Analysis(queryText: "tell me about the project", chunkTexts: chunks)
        XCTAssertFalse(verdict.distinctive, "a query of corpus-common words must keep the dense-only path")
    }

    func testRouter_RarePlainWord_Distinctive() {
        // The chat case: "sparkle" is no identifier, but it's rare (1 of 8 chunks).
        var chunks = ["sparkle framework update notes"]
        chunks += (1...7).map { "meeting recap number \($0) covering roadmap items" }
        let verdict = VectorStoreService.bm25Analysis(queryText: "what did we decide about sparkle", chunkTexts: chunks)
        XCTAssertTrue(verdict.distinctive, "a rare proper noun must enable fusion — shape rules can't see it, rarity can")
    }

    func testRouter_IdentifierAbsentFromCorpus_NotDistinctive() {
        // The symbol never occurs in this conversation: BM25 would rank on common
        // leftovers only — noise. The router must keep dense-only.
        let chunks = ["general prose about nothing much", "more filler text right here"]
        let verdict = VectorStoreService.bm25Analysis(queryText: "explain addAttachedFiles", chunkTexts: chunks)
        XCTAssertFalse(verdict.distinctive, "distinctive requires the token to actually occur in the corpus (df ≥ 1)")
    }

    // MARK: - 4. RRF fusion (the run-1 failure shape)

    func testHybridFusion_RescuesSymbolChunkIntoTopK() throws {
        let conv = UUID()
        let query = unitVector(lean: 0)

        // Dense ranks the three prose chunks 1-3 and the symbol chunk LAST —
        // the observed embedding failure for NL-question-vs-code pairs.
        try seed(conversation: conv, embedding: unitVector(lean: 0.10),
                 text: "we discussed how files are validated before attaching")
        try seed(conversation: conv, embedding: unitVector(lean: 0.20),
                 text: "the file size limits were checked during review")
        try seed(conversation: conv, embedding: unitVector(lean: 0.30),
                 text: "notes about file handling in general")
        try seed(conversation: conv, embedding: unitVector(lean: 0.35),
                 text: "completely unrelated theme discussion")
        try seed(conversation: conv, embedding: unitVector(lean: 0.45),
                 text: "func addAttachedFiles(items: [FileSystemItem]) { sizeCheck(items) }")

        let chunks = try conversationChunks(conv)

        // Precondition — dense-only top-3 misses the symbol chunk entirely.
        let denseOnly = VectorStoreService.rankConversationChunks(
            chunks, against: query, limit: 3, maximumDistance: 0.7
        )
        XCTAssertEqual(denseOnly.count, 3)
        XCTAssertFalse(
            denseOnly.contains { $0.bestChunkText.contains("addAttachedFiles") },
            "precondition: without fusion the symbol chunk must be outside the top-3"
        )

        // Hybrid — BM25 ranks the symbol chunk #1; RRF pulls it into the top-3.
        let hybrid = VectorStoreService.rankConversationChunks(
            chunks, against: query,
            queryText: "where does addAttachedFiles check file size",
            limit: 3, maximumDistance: 0.7
        )
        XCTAssertEqual(hybrid.count, 3)
        XCTAssertTrue(
            hybrid.contains { $0.bestChunkText.contains("addAttachedFiles") },
            "fusion must rescue the symbol chunk into the injected top-k"
        )
    }

    func testFusion_ReportedDistanceStaysRawCosine() throws {
        let conv = UUID()
        try seed(conversation: conv, embedding: unitVector(lean: 0.10),
                 text: "plain prose chunk about validation")
        try seed(conversation: conv, embedding: unitVector(lean: 0.45),
                 text: "func addAttachedFiles() { }")

        let chunks = try conversationChunks(conv)
        let raw = VectorStoreService.rankConversationChunks(
            chunks, against: unitVector(lean: 0), limit: 5, maximumDistance: 0.7
        )
        let fused = VectorStoreService.rankConversationChunks(
            chunks, against: unitVector(lean: 0),
            queryText: "explain addAttachedFiles",
            limit: 5, maximumDistance: 0.7
        )

        // Fusion reorders, but every reported distance must remain the pure
        // cosine value — downstream logging and windowing rely on it.
        let rawByText = Dictionary(uniqueKeysWithValues: raw.map { ($0.bestChunkText, $0.distance) })
        for hit in fused {
            XCTAssertEqual(
                hit.distance, rawByText[hit.bestChunkText] ?? -1, accuracy: 1e-9,
                "distance must be fusion-invariant for chunk: \(hit.bestChunkText)"
            )
        }
    }

    // MARK: - 5. Injection gate

    // MARK: - 6. In-ranker history exclusion (slot crowding)

    func testExclusion_HistoryParentsDoNotOccupyLimitSlots() throws {
        let conv = UUID()
        let query = unitVector(lean: 0)

        // The 2026-07-13 comparison-log shape that starved retrieval to zero:
        // the query's own indexed echo + the prior Q/A about the symbol rank
        // 1-3, the injectable file chunk sits at rank 4.
        let echoID = UUID(), priorQuestionID = UUID(), priorAnswerID = UUID()
        try seed(conversation: conv, embedding: unitVector(lean: 0.01),
                 text: "whats the code inside advancedCard", sourceMessageID: echoID)
        try seed(conversation: conv, embedding: unitVector(lean: 0.10),
                 text: "print full content for advancedCard", sourceMessageID: priorQuestionID)
        try seed(conversation: conv, embedding: unitVector(lean: 0.20),
                 text: "the advancedCard view shows nesting depth settings", sourceMessageID: priorAnswerID)
        try seed(conversation: conv, embedding: unitVector(lean: 0.40),
                 text: "private var advancedCard: some View { SettingsCard(title: \"Advanced\") }")

        let chunks = try conversationChunks(conv)
        let history: Set<UUID> = [echoID, priorQuestionID, priorAnswerID]

        // Precondition — without in-ranker exclusion, history fills every slot
        // and post-filtering would leave nothing to inject.
        let unexcluded = VectorStoreService.rankConversationChunks(
            chunks, against: query,
            queryText: "whats the code inside advancedCard",
            limit: 3, maximumDistance: 0.7
        )
        XCTAssertFalse(
            unexcluded.contains { $0.bestChunkText.contains("SettingsCard") },
            "precondition: the corpus doc must be crowded out of the top-3 for this test to mean anything"
        )

        // With exclusion applied DURING collection, the slots fill with
        // injectable documents only.
        let hits = VectorStoreService.rankConversationChunks(
            chunks, against: query,
            queryText: "whats the code inside advancedCard",
            limit: 3, maximumDistance: 0.7,
            exclusion: RetrievalExclusion(messageIDs: history)
        )
        XCTAssertTrue(
            hits.contains { $0.bestChunkText.contains("SettingsCard") },
            "excluded history parents must not occupy limit slots — the corpus doc fills the window"
        )
        XCTAssertFalse(hits.contains { history.contains($0.sourceMessageID) },
                       "no excluded parent may be returned")

        // Same guarantee on the dense-only path (fusion router off).
        let denseHits = VectorStoreService.rankConversationChunks(
            chunks, against: query,
            limit: 3, maximumDistance: 0.7,
            exclusion: RetrievalExclusion(messageIDs: history)
        )
        XCTAssertTrue(denseHits.contains { $0.bestChunkText.contains("SettingsCard") })
        XCTAssertFalse(denseHits.contains { history.contains($0.sourceMessageID) })
    }

    func testGate_PastThresholdChunkWithoutIdentifierHit_StaysExcluded() throws {
        let conv = UUID()
        // Near chunk carries the identifier (turns fusion ON).
        try seed(conversation: conv, embedding: unitVector(lean: 0.10),
                 text: "func addAttachedFiles() { attach() }")
        // Far chunk (distance ≈ 0.95 > 0.7) matches only the common word "files" —
        // BM25 > 0, but no identifier hit: the exception lane must NOT admit it.
        try seed(conversation: conv, embedding: unitVector(lean: 0.95),
                 text: "the files were mentioned here once")

        let hits = VectorStoreService.rankConversationChunks(
            try conversationChunks(conv), against: unitVector(lean: 0),
            queryText: "explain addAttachedFiles and files",
            limit: 5, maximumDistance: 0.7
        )

        XCTAssertTrue(hits.contains { $0.bestChunkText.contains("addAttachedFiles") })
        XCTAssertFalse(
            hits.contains { $0.bestChunkText.contains("mentioned here once") },
            "a common-word BM25 hit must not open the past-threshold exception lane"
        )
    }
}

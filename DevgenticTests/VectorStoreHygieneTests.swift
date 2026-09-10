// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  VectorStoreHygieneTests.swift
//  devgenticTests
//
//  Created on 11/07/26.
//
//  Pins the ObjectBox engine behavior the vector-store hygiene track relies on,
//  against a real (temp-dir) Store with the production entity model:
//  1. Scoped vector search: conversation predicate INSIDE the HNSW query makes
//     retrieval immune to foreign-conversation crowding (the old post-filter
//     design returned 0 docs when 50+ closer foreign chunks existed).
//  2. Query-based removal deletes exactly the conversation's chunks.
//  3. sourceIdentifier lookup matches for replace-on-reindex.
//

import XCTest
import ObjectBox
@testable import devgentic

final class VectorStoreHygieneTests: XCTestCase {

    private var tempDir: URL!
    private var store: Store!
    private var parentBox: Box<ParentDocumentEntity>!
    private var childBox: Box<ChildChunkEntity>!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vector-hygiene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try Store(directoryPath: tempDir.path)
        parentBox = store.box(for: ParentDocumentEntity.self)
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
    private func seed(
        conversation: UUID,
        embedding: [Float],
        text: String,
        source: String = ""
    ) throws -> ChildChunkEntity {
        let parent = ParentDocumentEntity(
            sourceMessageID: UUID(),
            conversationID: conversation,
            fullTextContent: text,
            sourceIdentifier: source
        )
        let child = ChildChunkEntity(chunkText: text, embedding: embedding, chunkIndex: 0, conversationID: conversation.uuidString)
        child.parentDocument.target = parent
        try childBox.put(child)
        return child
    }

    // MARK: - 1. Scoped vector search (the crowd-out fix)

    func testScopedVectorSearch_ImmuneToForeignConversationCrowding() throws {
        let convA = UUID()
        let convB = UUID()
        let query = unitVector(lean: 0)

        // 60 near-identical chunks in conversation A — enough to fill any 50-slot
        // global candidate window ahead of B's chunk.
        for i in 0..<60 {
            try seed(conversation: convA, embedding: unitVector(lean: 0.001 + Float(i) * 0.0001), text: "A-\(i)")
        }
        // One relevant-but-farther chunk in conversation B (cosine distance ~0.08,
        // comfortably inside the 0.7 threshold — but globally ranked ~61st).
        try seed(conversation: convB, embedding: unitVector(lean: 0.3), text: "B-target")

        // Precondition: the pre-fix shape (global HNSW, post-filterable window)
        // demonstrates the crowd-out — B never enters the unscoped top-50.
        let global = try childBox.query {
            ChildChunkEntity.embedding.nearestNeighbors(queryVector: query, maxCount: 50)
        }.build().findWithScores()
        XCTAssertFalse(
            global.contains { $0.object.chunkText == "B-target" },
            "precondition: B's chunk must be crowded out of the unscoped top-50 for this test to mean anything"
        )

        // Engine-semantics canary: ObjectBox applies property conditions AFTER
        // nearestNeighbors picks its maxCount candidates, so a combined query
        // inherits the crowding — it must NOT be used for scoping. If this ever
        // starts returning the chunk, ObjectBox gained pre-filtered vector search
        // and findNearest can switch back to HNSW for scoped retrieval.
        let combined = try childBox.query {
            ChildChunkEntity.embedding.nearestNeighbors(queryVector: query, maxCount: 50)
                && ChildChunkEntity.conversationID == convB.uuidString
        }.build().findWithScores()
        XCTAssertTrue(
            combined.isEmpty,
            "ObjectBox now pre-filters vector search — revisit findNearestInConversation, HNSW may be usable again"
        )

        // The production path: exact scan over the conversation's own chunks,
        // ranked by VectorStoreService.rankConversationChunks — immune to crowding
        // by construction.
        let convBChunks = try childBox.query {
            ChildChunkEntity.conversationID == convB.uuidString
        }.build().find()
        let ranked = VectorStoreService.rankConversationChunks(
            convBChunks,
            against: query,
            limit: 3,
            maximumDistance: 0.7
        )
        XCTAssertEqual(ranked.count, 1, "exact scoped scan must surface B's chunk despite 60 closer foreign chunks")
        XCTAssertEqual(ranked.first?.parent.fullTextContent, "B-target")
    }

    func testRankConversationChunks_RespectsThresholdLimitAndParentDedup() throws {
        let conv = UUID()
        // Two chunks under the same parent (dedup case), one distinct parent, one
        // beyond the 0.7 distance threshold.
        let sharedParent = ParentDocumentEntity(
            sourceMessageID: UUID(), conversationID: conv, fullTextContent: "shared-parent"
        )
        for i in 0..<2 {
            let child = ChildChunkEntity(chunkText: "shared-\(i)", embedding: unitVector(lean: 0.05 + Float(i) * 0.01), chunkIndex: i, conversationID: conv.uuidString)
            child.parentDocument.target = sharedParent
            try childBox.put(child)
        }
        try seed(conversation: conv, embedding: unitVector(lean: 0.2), text: "distinct-parent")
        // lean 0.95 → nearly orthogonal to axis 0 → distance ≈ 0.93 > 0.7 threshold.
        try seed(conversation: conv, embedding: unitVector(lean: 0.95), text: "past-threshold")

        let chunks = try childBox.query {
            ChildChunkEntity.conversationID == conv.uuidString
        }.build().find()
        let ranked = VectorStoreService.rankConversationChunks(
            chunks, against: unitVector(lean: 0), limit: 5, maximumDistance: 0.7
        )

        XCTAssertEqual(ranked.count, 2, "shared parent dedups to one, threshold drops the far chunk")
        XCTAssertEqual(ranked.first?.parent.fullTextContent, "shared-parent", "closest chunk's parent ranks first")
        XCTAssertEqual(ranked.last?.parent.fullTextContent, "distinct-parent")
        XCTAssertFalse(ranked.contains { $0.parent.fullTextContent == "past-threshold" })
    }

    // MARK: - 4. Lexical exact-match boost (symbol queries)

    func testLexicalBoost_RescuesAndRanksSymbolChunkBeyondCosineThreshold() throws {
        let conv = UUID()
        // Semantically-near chunk WITHOUT the symbol (distance ~0.68 — inside threshold).
        try seed(conversation: conv, embedding: unitVector(lean: 0.75), text: "some general prose about attachments and files")
        // Symbol-bearing chunk, semantically FAR (distance ~0.95 — dropped by cosine alone).
        try seed(conversation: conv, embedding: unitVector(lean: 0.95), text: "func addAttachedFiles(fileItems: [FileSystemItem]) { attach(fileItems) }")

        let chunks = try childBox.query {
            ChildChunkEntity.conversationID == conv.uuidString
        }.build().find()

        // Precondition: cosine alone drops the symbol chunk entirely.
        let semanticOnly = VectorStoreService.rankConversationChunks(
            chunks, against: unitVector(lean: 0), limit: 5, maximumDistance: 0.7
        )
        XCTAssertFalse(
            semanticOnly.contains { $0.parent.fullTextContent.contains("addAttachedFiles") },
            "precondition: without the boost the symbol chunk must be beyond the threshold"
        )

        // With the raw query: the exact identifier hit rescues it AND ranks it first —
        // the manual-test failure ("addAttachedFiles… does not contain") this fixes.
        let boosted = VectorStoreService.rankConversationChunks(
            chunks, against: unitVector(lean: 0),
            queryText: "Tell me about addAttachedFiles method",
            limit: 5, maximumDistance: 0.7
        )
        XCTAssertEqual(
            boosted.first?.bestChunkText.contains("addAttachedFiles"), true,
            "identifier hit must rescue the chunk past the threshold and rank it first"
        )
    }

    func testLexicalTokens_DropStopwordsAndShortWords() {
        let tokens = VectorStoreService.lexicalTokens(from: "Tell me about the addAttachedFiles method")
        XCTAssertEqual(tokens, ["addAttachedFiles"])
    }

    func testIsIdentifierLike_CamelCaseAndUnderscoreOnly() {
        XCTAssertTrue(VectorStoreService.isIdentifierLike("addAttachedFiles"))
        XCTAssertTrue(VectorStoreService.isIdentifierLike("placeholder_text"))
        XCTAssertTrue(VectorStoreService.isIdentifierLike("Qwen25Instruct"))
        XCTAssertFalse(VectorStoreService.isIdentifierLike("technology"))
        XCTAssertFalse(VectorStoreService.isIdentifierLike("short"))
    }

    // MARK: - 2. Per-conversation removal

    func testConversationRemoval_DeletesOnlyThatConversation() throws {
        let doomed = UUID()
        let survivor = UUID()
        for i in 0..<5 {
            try seed(conversation: doomed, embedding: unitVector(lean: 0.01 * Float(i + 1)), text: "doomed-\(i)")
        }
        try seed(conversation: survivor, embedding: unitVector(lean: 0.2), text: "survivor")

        // The exact removal shape VectorStoreService.deleteDocuments uses:
        // children by plain-String conversation key; parents derived via relation.
        let childQuery = try childBox.query {
            ChildChunkEntity.conversationID == doomed.uuidString
        }.build()
        let children = try childQuery.find()
        var parentsByID: [Id: ParentDocumentEntity] = [:]
        for child in children {
            if let parent = child.parentDocument.target { parentsByID[parent.id] = parent }
        }
        let removed = try childQuery.remove()
        try parentBox.remove(Array(parentsByID.values))

        XCTAssertEqual(removed, 5)
        XCTAssertEqual(try childBox.count(), 1, "survivor conversation's chunk must remain")
        XCTAssertEqual(try parentBox.count(), 1, "survivor's parent must remain")

        // The doomed conversation retrieves nothing; the survivor still retrieves.
        let doomedHits = try childBox.query {
            ChildChunkEntity.embedding.nearestNeighbors(queryVector: unitVector(lean: 0), maxCount: 10)
                && ChildChunkEntity.conversationID == doomed.uuidString
        }.build().find()
        XCTAssertTrue(doomedHits.isEmpty)
    }

    // MARK: - 3. sourceIdentifier lookup (replace-on-reindex)

    func testSourceIdentifierLookup_MatchesOnlySameSourceAndConversation() throws {
        let conv = UUID()
        let otherConv = UUID()
        let path = "/Users/tester/Docs/Spec.md"

        try seed(conversation: conv, embedding: unitVector(lean: 0.1), text: "v1", source: path)
        try seed(conversation: otherConv, embedding: unitVector(lean: 0.1), text: "other-conv copy", source: path)
        try seed(conversation: conv, embedding: unitVector(lean: 0.2), text: "different file", source: "/tmp/other.md")

        // The exact match shape VectorStoreService.removeDocuments uses.
        let matches = try parentBox.query {
            ParentDocumentEntity.sourceIdentifier == path
        }.build().find()
            .filter { $0.conversationID == conv }

        XCTAssertEqual(matches.count, 1, "must match same source in same conversation only")
        XCTAssertEqual(matches.first?.fullTextContent, "v1")
    }

    func testConvenienceInit_RequiresAndSetsConversationID() {
        // The "" trap closure: scoping is now a required construction input, not
        // a field someone must remember to backfill before put.
        let chunk = ChildChunkEntity(chunkText: "scoped", embedding: [1, 0], chunkIndex: 0, conversationID: "conv-123")
        XCTAssertEqual(chunk.conversationID, "conv-123")
    }

    func testLegacyRows_EmptySourceIdentifier_NeverMatch() throws {
        let conv = UUID()
        try seed(conversation: conv, embedding: unitVector(lean: 0.1), text: "pre-hygiene row", source: "")

        let matches = try parentBox.query {
            ParentDocumentEntity.sourceIdentifier == ""
        }.build().find()
        // Rows DO exist with "" — the guard lives in removeDocuments (early return
        // on empty identifier). This test documents why that guard matters.
        XCTAssertEqual(matches.count, 1)
    }
}

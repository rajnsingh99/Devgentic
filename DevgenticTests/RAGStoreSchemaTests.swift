// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RAGStoreSchemaTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import ObjectBox
@testable import devgentic

@MainActor
final class RAGStoreSchemaTests: XCTestCase {

    private var directories: [URL] = []

    override func tearDown() async throws {
        for dir in directories { try? FileManager.default.removeItem(at: dir) }
        directories = []
    }

    private func testStore(capKB: UInt64 = 256 * 1024) throws -> VectorStoreService {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rag-schema-\(UUID().uuidString)")
        directories.append(dir)
        return try VectorStoreService(testDirectory: dir, maxDatabaseSizeKB: capKB)
    }

    private func vector(_ lean: Float) -> [Float] {
        var v = [Float](repeating: 0, count: 384); v[0] = 1 - lean; v[1] = lean
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 }); return v.map { $0 / n }
    }

    private func document(_ text: String, source: String, conversation: UUID, chunks: Int = 1)
        -> (ParentDocumentEntity, [ChildChunkEntity]) {
        let parent = ParentDocumentEntity(sourceMessageID: UUID(), conversationID: conversation,
                                          fullTextContent: text, sourceIdentifier: source)
        let children = (0..<chunks).map {
            ChildChunkEntity(chunkText: "\(text) part \($0)", embedding: vector(0.1), chunkIndex: $0,
                             conversationID: conversation.uuidString)
        }
        return (parent, children)
    }

    // MARK: - RAG-40: stored terms score exactly like re-tokenising

    /// The pre-RAG-40 algorithm, verbatim in substance: tokenise every chunk, full term maps.
    private func referenceBM25(queryText: String, chunkTexts: [String]) -> (scores: [Double], distinctive: Bool) {
        let tfs: [[String: Int]] = chunkTexts.map { text in
            var f: [String: Int] = [:]
            for token in VectorStoreService.bm25Tokens(from: text) { f[token, default: 0] += 1 }
            return f
        }
        var df: [String: Int] = [:]
        for f in tfs { for term in f.keys { df[term, default: 0] += 1 } }
        let lengths = tfs.map { Double($0.values.reduce(0, +)) }
        let n = Double(chunkTexts.count)
        let avg = max(1.0, lengths.reduce(0, +) / n)
        let query = Set(VectorStoreService.bm25Tokens(from: queryText)).sorted()
        var scores = [Double](repeating: 0, count: chunkTexts.count)
        guard !query.isEmpty else { return (scores, false) }
        var idf: [String: Double] = [:]
        for term in query { if let d = df[term] { idf[term] = log(1.0 + (n - Double(d) + 0.5) / (Double(d) + 0.5)) } }
        for (i, f) in tfs.enumerated() where lengths[i] > 0 {
            let norm = 1.0 - VectorStoreService.bm25B + VectorStoreService.bm25B * lengths[i] / avg
            for term in query {
                guard let occ = f[term], let w = idf[term] else { continue }
                let tf = Double(occ)
                scores[i] += w * (tf * (VectorStoreService.bm25K1 + 1.0)) / (tf + VectorStoreService.bm25K1 * norm)
            }
        }
        let distinctive = VectorStoreService.lexicalTokens(from: queryText).contains { word in
            guard let d = df[word.lowercased()], d >= 1 else { return false }
            return VectorStoreService.isIdentifierLike(word)
                || (chunkTexts.count >= VectorStoreService.minimumCorpusForRarity && 4 * d <= chunkTexts.count)
        }
        return (scores, distinctive)
    }

    func testStoredTermsScoreExactlyLikeTokenisingEveryChunk() {
        let vocabulary = ["the", "file", "addAttachedFiles", "num_ctx", "Kestrel", "ship", "march", "a", "a",
                          "JSONValue", "café", "naïve", "v2", "release_notes", "Tokenizer", "x", "data", "data"]
        var rng = SystemRandomNumberGenerator()
        for round in 0..<200 {
            let corpus = (0..<Int.random(in: 1...40, using: &rng)).map { _ in
                (0..<Int.random(in: 0...30, using: &rng)).map { _ in vocabulary.randomElement(using: &rng)! }.joined(separator: " ")
            }
            let query = (0..<Int.random(in: 0...5, using: &rng)).map { _ in vocabulary.randomElement(using: &rng)! }.joined(separator: " ")
            let expected = referenceBM25(queryText: query, chunkTexts: corpus)
            let actual = VectorStoreService.bm25Analysis(queryText: query, chunkTexts: corpus)
            XCTAssertEqual(actual.distinctive, expected.distinctive, "round \(round) router diverged for '\(query)'")
            XCTAssertEqual(actual.scores.count, expected.scores.count)
            for (a, e) in zip(actual.scores, expected.scores) {
                XCTAssertEqual(a, e, accuracy: 1e-12, "round \(round) score diverged for '\(query)'")
            }
        }
    }

    /// Adjacent tokens share a delimiter — `" a a a "` holds `" a "` three times.
    func testOccurrenceCountingSharesDelimiters() {
        func count(_ needle: String, _ haystack: String) -> Int {
            var h = haystack
            return h.withUTF8 { VectorStoreService.occurrences(of: Array(needle.utf8), in: $0) }
        }
        XCTAssertEqual(count(" a ", " a a a "), 3)
        XCTAssertEqual(count(" ab ", " ab abc ab "), 2, "a token is never matched inside a longer one")
        XCTAssertEqual(count(" ab ", " abab "), 0)
        XCTAssertEqual(count(" x ", ""), 0)
    }

    func testAChunkCarriesItsTermsFromConstruction() {
        let chunk = ChildChunkEntity(chunkText: "call addAttachedFiles now", embedding: vector(0), chunkIndex: 0, conversationID: "c")
        XCTAssertEqual(chunk.bm25Terms, " call addattachedfiles add attached files now ")
        XCTAssertEqual(chunk.bm25Length, 6)
    }

    /// WIRING: the ranker reads the STORED terms. Chunk B's text says nothing, but its stored terms
    /// hold a rare identifier — only a ranker that reads them fuses B to the top.
    func testRankingReadsTheStoredTerms() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rank-terms-\(UUID().uuidString)")
        directories.append(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(directoryPath: dir.path)
        defer { store.close() }
        let box = store.box(for: ChildChunkEntity.self)
        let conv = UUID().uuidString
        func put(_ text: String, lean: Float, storedTerms: String?) throws {
            let parent = ParentDocumentEntity(sourceMessageID: UUID(), conversationID: UUID(), fullTextContent: text)
            let chunk = ChildChunkEntity(chunkText: text, embedding: vector(lean), chunkIndex: 0, conversationID: conv)
            if let storedTerms { chunk.bm25Terms = storedTerms; chunk.bm25Length = 1 }
            chunk.parentDocument.target = parent
            try box.put(chunk)
        }
        try put("alpha notes", lean: 0.05, storedTerms: nil)
        try put("beta notes", lean: 0.3, storedTerms: " xylophonedelta7 ")
        try put("gamma notes", lean: 0.35, storedTerms: nil)
        try put("delta notes", lean: 0.4, storedTerms: nil)
        let chunks = try box.query { ChildChunkEntity.conversationID == conv }.build().find()

        let hits = VectorStoreService.rankConversationChunks(chunks, against: vector(0), queryText: "xylophoneDelta7",
                                                             limit: 1, maximumDistance: 0.7)
        XCTAssertEqual(hits.first?.fullTextContent, "beta notes",
                       "BM25 ignored the stored terms — the dense-closest chunk won instead")
    }

    // MARK: - RAG-13 / RAG-17: one transaction per replace

    func testAReplaceKeepsExactlyOneCopyOfTheSource() throws {
        let store = try testStore()
        let conv = UUID(), other = UUID()
        let (p1, c1) = document("version one", source: "/docs/spec.md", conversation: conv, chunks: 3)
        let (p2, c2) = document("version two", source: "/docs/spec.md", conversation: conv, chunks: 2)
        let (po, co) = document("other conversation's copy", source: "/docs/spec.md", conversation: other)
        XCTAssertEqual(store.replaceSemanticDocument(parent: po, children: co), .written)
        XCTAssertEqual(store.replaceSemanticDocument(parent: p1, children: c1), .written)
        XCTAssertEqual(store.replaceSemanticDocument(parent: p2, children: c2), .written)

        XCTAssertEqual(try store.parentTextsForTesting(sourceIdentifier: "/docs/spec.md", conversationID: conv), ["version two"])
        XCTAssertEqual(try store.parentTextsForTesting(sourceIdentifier: "/docs/spec.md", conversationID: other),
                       ["other conversation's copy"], "a replace reached into another conversation")
        let counts = try store.documentCountsForTesting()
        XCTAssertEqual(counts.parents, 2)
        XCTAssertEqual(counts.chunks, 3, "version one's 3 chunks are gone; version two's 2 + the other copy's 1 remain")
    }

    /// ⚠️ RAG-17: two concurrent re-indexes of one source. Remove-then-add in separate
    /// transactions let both remove before either added → two copies crowding the limit-3 slots.
    func testConcurrentReplacesOfOneSourceLeaveOneCopy() async throws {
        let store = try testStore()
        let conv = UUID()
        final class Done: @unchecked Sendable { let lock = NSLock(); var value = false }
        for round in 0..<30 {
            let source = "/docs/race-\(round).md"
            // ⚠️ WATCHDOG, not a structured await: without `writeLock` these writers DEADLOCK inside
            // ObjectBox, and a hung test hangs the whole suite unless timeouts are enabled. Unstructured,
            // so the test can report the deadlock and return while the stuck threads stay stuck.
            let done = Done()
            Task.detached {
                await withTaskGroup(of: Void.self) { group in
                    for writer in 0..<4 {
                        group.addTask {
                            let parent = ParentDocumentEntity(sourceMessageID: UUID(), conversationID: conv,
                                                              fullTextContent: "writer \(writer)", sourceIdentifier: source)
                            let chunks = (0..<3).map { ChildChunkEntity(chunkText: "w\(writer) c\($0)", embedding: [Float](repeating: 0.05, count: 384),
                                                                        chunkIndex: $0, conversationID: conv.uuidString) }
                            store.replaceSemanticDocument(parent: parent, children: chunks)
                        }
                    }
                }
                done.lock.withLock { done.value = true }
            }
            let deadline = Date().addingTimeInterval(20)
            while !done.lock.withLock({ done.value }), Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard done.lock.withLock({ done.value }) else {
                return XCTFail("round \(round): concurrent replaces DEADLOCKED (no progress in 20 s) — is every store write behind `writeLock`?")
            }
            XCTAssertEqual(try store.parentTextsForTesting(sourceIdentifier: source, conversationID: conv).count, 1,
                           "round \(round): concurrent replaces left duplicate copies")
        }
    }

    /// ⚠️⚠️ RAG-13: at the cap, a replace must FAIL WHOLE. The old remove-then-add deleted the
    /// source's previous vectors and stored nothing — memory lost on the write that failed.
    func testAFullStoreKeepsThePreviousCopyAndSaysSo() async throws {
        let store = try testStore(capKB: 2 * 1024)
        let conv = UUID()
        let (p1, c1) = document("small version", source: "/docs/book.md", conversation: conv)
        XCTAssertEqual(store.replaceSemanticDocument(parent: p1, children: c1), .written)

        // 1,200 chunks × a 384-float embedding (+ its HNSW node) is ~3 MB against a 2 MB cap.
        let (p2, c2) = document("big version", source: "/docs/book.md", conversation: conv, chunks: 1_200)
        XCTAssertEqual(store.replaceSemanticDocument(parent: p2, children: c2), .storeFull)
        XCTAssertEqual(try store.parentTextsForTesting(sourceIdentifier: "/docs/book.md", conversationID: conv), ["small version"],
                       "the previous copy was deleted by the write that failed")

        for _ in 0..<50 where AdvisoryCenter.shared.current(for: conv)?.category != .knowledgeStoreFull {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(AdvisoryCenter.shared.current(for: conv)?.category, .knowledgeStoreFull, "a full store is silent")
        AdvisoryCenter.shared.clear(category: .knowledgeStoreFull, conversationID: conv)

        // Latched: the next write refuses WITHOUT an attempt (an attempt at the cap costs ~13 s
        // under the write lock) — even a write small enough to fit.
        XCTAssertTrue(store.isLatchedFullForTesting)
        let (p3, c3) = document("tiny", source: "/docs/other.md", conversation: conv)
        XCTAssertEqual(store.replaceSemanticDocument(parent: p3, children: c3), .storeFull)
        XCTAssertEqual(try store.parentTextsForTesting(sourceIdentifier: "/docs/other.md", conversationID: conv), [])

        // A delete that frees space re-enables indexing — for conversations that still exist.
        store.deleteDocuments(forConversation: conv)
        XCTAssertFalse(store.isLatchedFullForTesting, "freeing space left indexing disabled")
        let (pf, cf) = document("after the cleanup", source: "/docs/new.md", conversation: UUID())
        XCTAssertEqual(store.replaceSemanticDocument(parent: pf, children: cf), .written)
        XCTAssertEqual(store.replaceSemanticDocument(parent: p3, children: c3), .conversationDeleted,
                       "the deleted conversation accepted a write (RAG-5)")
    }

    // MARK: - RAG-9: the manual codegen carried every index

    /// ⚠️ ObjectBox codegen is MANUAL. An `// objectbox: index` added without re-running the
    /// generator compiles, runs, and indexes nothing. Every annotation must reach the model.
    func testEveryIndexAnnotationReachedTheGeneratedModel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard let modelData = try? Data(contentsOf: root.appendingPathComponent("model-devgentic.json")) else {
            throw XCTSkip("model-devgentic.json not reachable — running outside a checkout")
        }
        let model = try XCTUnwrap(JSONSerialization.jsonObject(with: modelData) as? [String: Any])
        let entities = try XCTUnwrap(model["entities"] as? [[String: Any]])

        var annotated: [(entity: String, property: String)] = []
        for entity in ["ChildChunkEntity", "ParentDocumentEntity"] {
            let source = try String(contentsOf: root.appendingPathComponent("Devgentic/Core/Persistence/RAG/\(entity).swift"), encoding: .utf8)
            let lines = source.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces) == "// objectbox: index" {
                guard let decl = lines[(i + 1)...].first(where: { $0.contains("var ") }),
                      let name = decl.split(separator: " ").drop(while: { $0 != "var" }).dropFirst().first?
                        .split(separator: ":").first.map(String.init) else { continue }
                annotated.append((entity, name))
            }
        }
        XCTAssertTrue(annotated.contains { $0 == ("ChildChunkEntity", "conversationID") }, "this guard found no annotations")
        XCTAssertTrue(annotated.contains { $0 == ("ParentDocumentEntity", "sourceIdentifier") })

        for (entity, property) in annotated {
            let props = entities.first { $0["name"] as? String == entity }?["properties"] as? [[String: Any]] ?? []
            let prop = props.first { $0["name"] as? String == property }
            XCTAssertNotNil(prop?["indexId"], "\(entity).\(property) is annotated `// objectbox: index` but the generated model has no index — re-run the ObjectBox generator")
        }
    }
}

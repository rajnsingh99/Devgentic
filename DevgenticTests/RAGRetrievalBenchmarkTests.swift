// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RAGRetrievalBenchmarkTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import ObjectBox
@testable import devgentic

final class RAGRetrievalBenchmarkTests: XCTestCase {

    private var tempDir: URL!
    private var store: Store!
    private var childBox: Box<ChildChunkEntity>!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RAG_BENCH"] == "1",
            "CR-29 benchmark — opt-in via TEST_RUNNER_RAG_BENCH=1."
        )
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rag-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try Store(directoryPath: tempDir.path)
        childBox = store.box(for: ChildChunkEntity.self)
    }

    override func tearDownWithError() throws {
        store?.close()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Deterministic fixtures

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let dimensions = 384
    private static let rareIdentifier = "xylophoneDelta7"
    private static let queryText = "what does the quarterly forecast say about \(rareIdentifier)"

    /// ~4,000-word vocabulary with a Zipf-ish draw, so BM25 sees realistic document frequencies.
    private static let vocabulary: [String] = {
        var rng = SplitMix64(state: 7)
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return (0..<4_000).map { _ in
            String((0..<Int.random(in: 3...10, using: &rng)).map { _ in letters.randomElement(using: &rng)! })
        }
    }()

    private func text(characters: Int, rng: inout SplitMix64) -> String {
        var out = ""
        out.reserveCapacity(characters + 16)
        var length = 0   // `String.count` is O(n) — tracking it keeps a 2M-char file linear.
        while length < characters {
            // Zipf-ish: squaring a uniform skews toward low (frequent) indices.
            let u = Double.random(in: 0..<1, using: &rng)
            let word = Self.vocabulary[Int(u * u * Double(Self.vocabulary.count))]
            out += word
            out += " "
            length += word.utf8.count + 1
        }
        return out
    }

    private func unit(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / norm }
    }

    private func randomUnit(rng: inout SplitMix64) -> [Float] {
        unit((0..<Self.dimensions).map { _ in Float.random(in: -1...1, using: &rng) })
    }

    /// A unit vector at cosine similarity `similarity` to `query` — so the 0.7 distance gate
    /// admits a realistic fraction of candidates instead of rejecting random noise outright.
    private func embedding(near query: [Float], similarity: Float, rng: inout SplitMix64) -> [Float] {
        let r = randomUnit(rng: &rng)
        let dot = zip(r, query).reduce(0) { $0 + $1.0 * $1.1 }
        let perpendicular = unit(zip(r, query).map { $0.0 - dot * $0.1 })
        let s = similarity
        let c = (1 - s * s).squareRoot()
        return unit(zip(query, perpendicular).map { s * $0.0 + c * $0.1 })
    }

    private struct Scenario {
        let name: String
        let turns: Int
        let fileCharacters: [Int]
    }

    private struct Seeded {
        let conversation: UUID
        let query: [Float]
        let historyMessageIDs: Set<UUID>
        let chunkCount: Int
        let insertSeconds: Double
    }

    /// Seeds one conversation: `turns` messages (~900 chars → 2 chunks each, own parent) and one
    /// parent per attached file holding the WHOLE file text, exactly as `indexAttachedFiles` does.
    private func seed(_ scenario: Scenario, rng: inout SplitMix64) throws -> Seeded {
        let conversation = UUID()
        let query = randomUnit(rng: &rng)
        var history: Set<UUID> = []
        var chunkCount = 0
        var insertSeconds = 0.0
        let clock = ContinuousClock()

        for turn in 0..<scenario.turns {
            let messageID = UUID()
            history.insert(messageID)
            let full = text(characters: 900, rng: &rng)
            let parent = ParentDocumentEntity(sourceMessageID: messageID, conversationID: conversation, fullTextContent: full)
            var children: [ChildChunkEntity] = []
            for index in 0..<2 {
                var chunkText = text(characters: 450, rng: &rng)
                if turn % 97 == 0 { chunkText += " \(Self.rareIdentifier)" }
                let child = ChildChunkEntity(
                    chunkText: chunkText,
                    embedding: embedding(near: query, similarity: Float.random(in: -0.05...0.75, using: &rng), rng: &rng),
                    chunkIndex: index,
                    conversationID: conversation.uuidString
                )
                child.parentDocument.target = parent
                children.append(child)
            }
            let elapsed = try clock.measure { try childBox.put(children) }
            insertSeconds += elapsed.seconds
            chunkCount += children.count
        }

        for (fileIndex, characters) in scenario.fileCharacters.enumerated() {
            let full = text(characters: characters, rng: &rng)
            let parent = ParentDocumentEntity(
                sourceMessageID: UUID(), conversationID: conversation,
                fullTextContent: "[File: report-\(fileIndex).pdf]\n\(full)",
                sourceIdentifier: "/Users/bench/report-\(fileIndex).pdf"
            )
            let count = max(1, characters / 462)
            var children: [ChildChunkEntity] = []
            children.reserveCapacity(count)
            for index in 0..<count {
                var chunkText = text(characters: 500, rng: &rng)
                if index % 211 == 0 { chunkText += " \(Self.rareIdentifier)" }
                // The attached file is what the user is asking about: skew it relevant.
                let child = ChildChunkEntity(
                    chunkText: chunkText,
                    embedding: embedding(near: query, similarity: Float.random(in: 0.15...0.80, using: &rng), rng: &rng),
                    chunkIndex: index,
                    conversationID: conversation.uuidString
                )
                child.parentDocument.target = parent
                children.append(child)
            }
            let elapsed = try clock.measure { try childBox.put(children) }
            insertSeconds += elapsed.seconds
            chunkCount += children.count
        }
        return Seeded(conversation: conversation, query: query, historyMessageIDs: history,
                      chunkCount: chunkCount, insertSeconds: insertSeconds)
    }

    // MARK: - Measurement

    private func median(_ runs: Int = 5, _ body: () throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<runs { samples.append(try clock.measure(body).seconds * 1_000) }
        return samples.sorted()[runs / 2]
    }

    private func run(_ scenario: Scenario) throws {
        var rng = SplitMix64(state: 42)
        let seeded = try seed(scenario, rng: &rng)
        let conv = seeded.conversation.uuidString

        let fetch = { try self.childBox.query { ChildChunkEntity.conversationID == conv }.build().find() }
        let chunks = try fetch()
        XCTAssertEqual(chunks.count, seeded.chunkCount)

        let fetchMs = try median { _ = try fetch() }
        let denseMs = median {
            var sink = 0.0
            for chunk in chunks {
                if let e = chunk.embedding { sink += 1.0 - Double(VectorMath.dotProduct(e, seeded.query)) }
            }
            XCTAssertFalse(sink.isNaN)
        }
        // RAG-40: what the send path runs now — query terms counted in terms stored at construction.
        let documents = chunks.map { VectorStoreService.bm25Document(stored: $0) }
        let bm25Ms = median { _ = VectorStoreService.bm25Analysis(queryText: Self.queryText, documents: documents) }
        // Fresh chunk objects per run: a ToOne caches its resolved target, so re-ranking the
        // same array would hide the parent-resolution cost production pays on every send.
        let rankDenseOnlyMs = try median {
            let fresh = try fetch()
            _ = VectorStoreService.rankConversationChunks(fresh, against: seeded.query, queryText: nil, limit: 3,
                                                          maximumDistance: 0.7, exclusion: RetrievalExclusion(messageIDs: seeded.historyMessageIDs))
        } - fetchMs
        let endToEndMs = try median {
            let fresh = try fetch()
            _ = VectorStoreService.rankConversationChunks(fresh, against: seeded.query, queryText: Self.queryText, limit: 3,
                                                          maximumDistance: 0.7, exclusion: RetrievalExclusion(messageIDs: seeded.historyMessageIDs))
        }
        let parentResolveMs = try median {
            let fresh = try fetch()
            var bytes = 0
            for chunk in fresh { bytes += chunk.parentDocument.target?.fullTextContent.utf8.count ?? 0 }
            XCTAssertGreaterThan(bytes, 0)
        } - fetchMs

        // What delete/replace-on-reindex pay now (RAG-8): ids off the relation, no parent decode.
        let parentIDsOnlyMs = try median {
            let fresh = try fetch()
            XCTAssertFalse(Set(fresh.compactMap { $0.parentDocument.targetId?.value }).isEmpty)
        } - fetchMs

        let line = String(
            format: "[RAG-BENCH] %@ turns=%d files=%@ chunks=%d | insert=%.0fms | fetch=%.1fms dense=%.1fms bm25=%.1fms rankDenseOnly=%.1fms resolveAllParents=%.1fms parentIDsOnly=%.1fms | END-TO-END(fetch+hybrid rank)=%.1fms",
            scenario.name, scenario.turns, scenario.fileCharacters.map { "\($0 / 1_000)K" }.joined(separator: "+"),
            seeded.chunkCount, seeded.insertSeconds * 1_000,
            fetchMs, denseMs, bm25Ms, rankDenseOnlyMs, parentResolveMs, parentIDsOnlyMs, endToEndMs
        )
        print(line)
        try (line + "\n").appendLine(to: tempDir.deletingLastPathComponent().appendingPathComponent("rag-bench-results.txt"))
    }

    // MARK: - Scenarios (one test each so a slow one can't mask the rest)

    func test01_100Turns() throws { try run(.init(name: "chat-100", turns: 100, fileCharacters: [])) }
    func test02_300Turns() throws { try run(.init(name: "chat-300", turns: 300, fileCharacters: [])) }
    func test03_300TurnsPlus300PagePDF() throws { try run(.init(name: "chat-300+pdf-300p", turns: 300, fileCharacters: [600_000])) }
    func test04_300TurnsPlusBook() throws { try run(.init(name: "chat-300+book-1000p", turns: 300, fileCharacters: [2_000_000])) }
    func test05_300TurnsPlusThreeBooks() throws {
        try run(.init(name: "chat-300+3books", turns: 300, fileCharacters: [2_000_000, 2_000_000, 2_000_000]))
    }
}

private extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

private extension String {
    func appendLine(to url: URL) throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(utf8))
        } else {
            try write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

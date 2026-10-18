// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  EmbeddingServiceTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class EmbeddingServiceTests: XCTestCase {

    private let service = EmbeddingService.shared

    // MARK: - Embedding Generation

    func testGenerateEmbedding_ProducesNonNilResult() async {
        let embedding = await service.generateEmbedding(for: "Hello world")
        XCTAssertNotNil(embedding, "Embedding should not be nil for valid input")
    }

    func testGenerateEmbedding_OutputIs384Dimensional() async {
        let embedding = await service.generateEmbedding(for: "The quick brown fox jumps over the lazy dog.")
        XCTAssertNotNil(embedding)
        XCTAssertEqual(embedding?.count, 384,
                       "All-MiniLM-L6-v2 produces 384-dimensional embeddings")
    }

    func testGenerateEmbedding_OutputIsL2Normalized() async {
        guard let embedding = await service.generateEmbedding(for: "Test normalization") else {
            XCTFail("Embedding should not be nil")
            return
        }

        let magnitude = VectorMath.magnitude(of: embedding)
        XCTAssertEqual(magnitude, 1.0, accuracy: 1e-4,
                       "Embedding should be L2-normalized (magnitude ≈ 1.0)")
    }

    func testGenerateEmbedding_DeterministicForSameInput() async {
        let text = "Deterministic test input"
        let embedding1 = await service.generateEmbedding(for: text)
        let embedding2 = await service.generateEmbedding(for: text)

        XCTAssertNotNil(embedding1)
        XCTAssertNotNil(embedding2)
        XCTAssertEqual(embedding1, embedding2,
                       "Same input should always produce the same embedding")
    }

    func testGenerateEmbedding_DifferentInputs_ProduceDifferentEmbeddings() async {
        let embedding1 = await service.generateEmbedding(for: "Hello world")
        let embedding2 = await service.generateEmbedding(for: "Quantum physics and string theory")

        XCTAssertNotNil(embedding1)
        XCTAssertNotNil(embedding2)
        XCTAssertNotEqual(embedding1, embedding2,
                          "Different inputs should produce different embeddings")
    }

    // MARK: - Semantic Similarity via Embeddings

    func testEmbedding_SimilarTexts_HighCosineSimilarity() async {
        guard let emb1 = await service.generateEmbedding(for: "The cat sat on the mat"),
              let emb2 = await service.generateEmbedding(for: "A cat was sitting on a mat") else {
            XCTFail("Failed to generate embeddings")
            return
        }

        let similarity = VectorMath.cosineSimilarity(between: emb1, and: emb2)
        XCTAssertGreaterThan(similarity, 0.7,
                             "Semantically similar texts should have high cosine similarity (got \(similarity))")
    }

    func testEmbedding_UnrelatedTexts_LowCosineSimilarity() async {
        guard let emb1 = await service.generateEmbedding(for: "The cat sat on the mat"),
              let emb2 = await service.generateEmbedding(for: "Quantum computing uses qubits for parallel processing") else {
            XCTFail("Failed to generate embeddings")
            return
        }

        let similarity = VectorMath.cosineSimilarity(between: emb1, and: emb2)
        XCTAssertLessThan(similarity, 0.4,
                          "Unrelated texts should have low cosine similarity (got \(similarity))")
    }

    // MARK: - Edge Cases

    func testGenerateEmbedding_EmptyString() async {
        let embedding = await service.generateEmbedding(for: "")
        // Empty string still gets [CLS][SEP] tokens, so model should still produce output
        XCTAssertNotNil(embedding, "Empty string should still produce an embedding")
        if let emb = embedding {
            XCTAssertEqual(emb.count, 384)
        }
    }

    func testGenerateEmbedding_VeryLongText_TruncatesGracefully() async {
        // Create a 5000+ character input (well beyond 128-token limit)
        let longText = String(repeating: "This is a long sentence for testing truncation behavior. ", count: 100)

        let embedding = await service.generateEmbedding(for: longText)
        XCTAssertNotNil(embedding, "Long text should still produce an embedding after truncation")
        if let emb = embedding {
            XCTAssertEqual(emb.count, 384)
            let magnitude = VectorMath.magnitude(of: emb)
            XCTAssertEqual(magnitude, 1.0, accuracy: 1e-4,
                           "Truncated embedding should still be L2-normalized")
        }
    }

    func testGenerateEmbedding_UnicodeText() async {
        let embedding = await service.generateEmbedding(for: "こんにちは世界 你好世界 مرحبا بالعالم")
        XCTAssertNotNil(embedding, "Unicode text should produce a valid embedding")
        if let emb = embedding {
            XCTAssertEqual(emb.count, 384)
        }
    }

    func testGenerateEmbedding_RepeatedText_ServedFromCache() async {
        // Replace-on-reindex re-embeds byte-identical chunks when a file is
        // re-attached — the cache makes those hits free. Unique text so prior
        // tests in this suite can't have primed it.
        let text = "cache probe \(#function) — a deliberately unique sentence."
        let before = await service.cachedEmbeddingCount

        let first = await service.generateEmbedding(for: text)
        let afterFirst = await service.cachedEmbeddingCount
        let second = await service.generateEmbedding(for: text)
        let afterSecond = await service.cachedEmbeddingCount

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second, "cached result must be byte-identical")
        XCTAssertEqual(afterFirst, before + 1, "first call populates the cache")
        XCTAssertEqual(afterSecond, afterFirst, "second call must hit the cache, not re-embed")
    }

    func testExpectedDimensions_MatchesHNSWSchemaContract() {
        // ChildChunkEntity's hnswIndex annotation says dimensions=384 — the
        // embedder enforces the same number loudly; keep them in lockstep.
        XCTAssertEqual(EmbeddingService.expectedDimensions, 384)
    }

    func testGenerateEmbedding_EmojiText() async {
        let embedding = await service.generateEmbedding(for: "I love coding! 🚀💻🎉")
        XCTAssertNotNil(embedding, "Emoji text should produce a valid embedding")
        if let emb = embedding {
            XCTAssertEqual(emb.count, 384)
        }
    }
}

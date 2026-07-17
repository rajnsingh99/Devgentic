//
//  RAGPipelineDocumentation.swift
//  devgenticTests
//
//  Created by Raj Singh on 02/03/26.
//
//  ╔══════════════════════════════════════════════════════════════╗
//  ║  RAG Pipeline Documentation Tests                          ║
//  ║                                                            ║
//  ║  These tests serve as living documentation for Devgentic's ║
//  ║  Retrieval-Augmented Generation pipeline. Each test method ║
//  ║  demonstrates one stage with extensive comments explaining ║
//  ║  the "why" behind each step.                               ║
//  ║                                                            ║
//  ║  Pipeline:                                                 ║
//  ║  1. Message → ContentBlocks (parsing)                      ║
//  ║  2. ContentBlocks → Chunks (SemanticChunker)               ║
//  ║  3. Chunks → Embeddings (EmbeddingService + CoreML)        ║
//  ║  4. Embeddings → ChildChunkEntity (HNSW native [Float]? storage) ║
//  ║  5. Query → Ranked results (HNSW distance ≤ 0.7 ↔ sim ≥ 0.3) ║
//  ╚══════════════════════════════════════════════════════════════╝

import XCTest
@testable import devgentic

final class RAGPipelineDocumentationTests: XCTestCase {

    // MARK: - Stage 1: Message Ingestion

    /// Demonstrates how a ChatMessage is converted into structured ContentBlocks.
    ///
    /// In the RAG pipeline, raw chat messages (which may contain markdown, code,
    /// headings, tables, etc.) are first parsed into discrete `ContentBlock` objects.
    /// This structured representation allows the chunker to make intelligent decisions
    /// about where to split text — e.g., never splitting a code block mid-line.
    func testPipeline_Stage1_MessageToContentBlocks() {
        // Create a realistic agent message with mixed markdown content
        let markdown = """
        # How to Use SwiftUI

        SwiftUI is Apple's declarative UI framework. It uses a reactive data model \
        to keep views in sync with state.

        ```swift
        struct ContentView: View {
            var body: some View {
                Text("Hello, World!")
            }
        }
        ```

        The example above shows a minimal SwiftUI view.
        """

        let message = ChatMessage(
            conversationId: UUID(),
            sender: .agent,
            content: .markdownText(markdown)
        )

        // Stage 1: Extract ContentBlocks from the message
        let blocks = message.getBlocksForIndexing()

        // Verify: The parser should produce structured blocks for each section
        XCTAssertGreaterThanOrEqual(blocks.count, 2,
            "Markdown with heading + paragraph + code should produce multiple blocks")

        // Verify: At least one heading block and one code block exist
        let hasHeading = blocks.contains { if case .heading = $0.type { return true }; return false }
        let hasCode = blocks.contains { if case .code = $0.type { return true }; return false }

        XCTAssertTrue(hasHeading, "Should contain a heading block for '# How to Use SwiftUI'")
        XCTAssertTrue(hasCode, "Should contain a code block for the Swift snippet")
    }

    // MARK: - Stage 2: Semantic Chunking

    /// Demonstrates how ContentBlocks are split into vector-ready text chunks.
    ///
    /// The SemanticChunker respects content boundaries: it splits text at paragraph
    /// breaks, never severs code lines, and adds overlap between consecutive chunks
    /// to preserve context across chunk boundaries. This is crucial for embedding
    /// quality — a chunk that starts mid-sentence produces worse embeddings.
    func testPipeline_Stage2_ContentBlocksToChunks() {
        // Prepare blocks that simulate a parsed message
        let blocks = [
            ContentBlock(id: "b0", type: .heading(level: 1, text: "Swift Concurrency")),
            ContentBlock(id: "b1", type: .paragraph(
                "Swift's concurrency model uses async/await for structured concurrency. " +
                "Tasks can be created to run work in parallel, and actors provide " +
                "thread-safe access to mutable state."
            )),
            ContentBlock(id: "b2", type: .code(language: "swift", content: """
                func fetchData() async throws -> Data {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    return data
                }
                """, fileName: nil)),
            ContentBlock(id: "b3", type: .paragraph(
                "The async/await syntax makes asynchronous code read like synchronous code, " +
                "dramatically improving readability and reducing callback hell."
            ))
        ]

        // Use a smaller chunk size to force splitting
        let chunker = SemanticChunker(maxChunkSize: 256, overlap: 30)
        let chunks = chunker.chunk(blocks: blocks)

        // Verify: We should get multiple chunks (heading, text, code, text)
        XCTAssertGreaterThanOrEqual(chunks.count, 3,
            "4 content blocks with maxChunkSize=256 should produce at least 3 chunks")

        // Verify: Code chunks should have the language prefix
        let codeChunks = chunks.filter { $0.contains("[swift Context]:") }
        XCTAssertFalse(codeChunks.isEmpty,
            "Code blocks should be chunked with a '[swift Context]:' prefix for embedding context")

        // Verify: No chunk is empty
        for chunk in chunks {
            XCTAssertFalse(chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "No chunk should be empty or whitespace-only")
        }
    }

    // MARK: - Stage 3: Embedding Generation

    /// Demonstrates how text chunks are converted into 384-dimensional vector embeddings.
    ///
    /// Devgentic uses the All-MiniLM-L6-v2 sentence-transformer model (compiled to CoreML).
    /// Each chunk is tokenized using a real WordPiece tokenizer, fed through the model,
    /// and L2-normalized. The resulting 384-float vector captures the semantic meaning
    /// of the text in a form suitable for cosine similarity search.
    func testPipeline_Stage3_ChunksToEmbeddings() async {
        let service = EmbeddingService.shared
        let chunks = [
            "Swift Concurrency uses async/await for structured concurrency.",
            "Tasks can be created to run work in parallel using Task groups."
        ]

        var embeddings: [[Float]] = []
        for chunk in chunks {
            guard let embedding = await service.generateEmbedding(for: chunk) else {
                XCTFail("Failed to generate embedding for: '\(chunk.prefix(30))...'")
                return
            }
            embeddings.append(embedding)
        }

        // Verify: Each embedding is 384-dimensional (All-MiniLM-L6-v2 output size)
        for (i, emb) in embeddings.enumerated() {
            XCTAssertEqual(emb.count, 384,
                "Embedding \(i) should be 384-dimensional, got \(emb.count)")
        }

        // Verify: Each embedding is L2-normalized (magnitude ≈ 1.0)
        for (i, emb) in embeddings.enumerated() {
            let mag = VectorMath.magnitude(of: emb)
            XCTAssertEqual(mag, 1.0, accuracy: 1e-4,
                "Embedding \(i) should be L2-normalized (magnitude=\(mag))")
        }

        // Verify: Related chunks should have positive similarity
        // Note: All-MiniLM-L6-v2 measures semantic overlap at the sentence level.
        // These chunks share the topic (concurrency) but use different vocabulary,
        // so similarity ≈ 0.2–0.4 is expected. The production HNSW threshold is
        // distance ≤ 0.7 (similarity ≥ 0.3), so we use a relaxed floor here.
        let similarity = VectorMath.cosineSimilarity(between: embeddings[0], and: embeddings[1])
        XCTAssertGreaterThan(similarity, 0.15,
            "Two chunks about concurrency should have positive similarity (got \(similarity))")
    }

    // MARK: - Stage 4: HNSW Native Storage

    /// Demonstrates how embeddings are stored in ObjectBox HNSW without a custom converter.
    ///
    /// In Build 98+, `ChildChunkEntity.embedding` is typed as `[Float]?` with a native
    /// HNSW index annotation. ObjectBox serialises `floatVector` properties directly as
    /// packed Float32 data — no `FloatArrayConverter` is required.
    ///
    /// HNSW index parameters on ChildChunkEntity:
    ///   - dimensions=384            Matches All-MiniLM-L6-v2 output exactly
    ///   - neighborsPerNode=48       High M for escape edges out of dense code clusters
    ///   - indexingSearchCount=200   High efConstruction for recall-optimised graph edges
    ///   - distanceType="cosine"     Aligned with sentence-transformer training objective
    ///   - vectorCacheHintSizeKB=524288  512 MB cap to prevent iOS Jetsam termination
    ///
    /// This test validates that the [Float] produced by EmbeddingService can be assigned
    /// directly to ChildChunkEntity with no conversion and no precision loss.
    func testPipeline_Stage4_EmbeddingHNSWStorageContract() async {
        // Generate a real embedding (L2-normalised by EmbeddingService)
        guard let embedding = await EmbeddingService.shared.generateEmbedding(for: "HNSW storage test") else {
            XCTFail("Failed to generate embedding")
            return
        }

        // Assign directly to entity — no converter, no serialisation step
        let chunk = ChildChunkEntity(chunkText: "HNSW storage test", embedding: embedding, chunkIndex: 0, conversationID: "")

        // Verify: Exact equality — native floatVector storage has no precision loss
        XCTAssertEqual(chunk.embedding?.count, 384,
                       "HNSW index requires exactly 384 dimensions (All-MiniLM-L6-v2)")
        XCTAssertEqual(chunk.embedding, embedding,
                       "Embedding must be stored verbatim — no converter applied")

        // Verify: L2-normalisation is preserved; HNSW cosine distance relies on unit vectors
        let mag = VectorMath.magnitude(of: chunk.embedding ?? [])
        XCTAssertEqual(mag, 1.0, accuracy: 1e-4,
                       "L2-normalisation must be intact after assignment to ChildChunkEntity")
    }

    // MARK: - Stage 5: Similarity Search Simulation

    /// Demonstrates how the HNSW vector search retrieves the most relevant documents.
    ///
    /// In production, `VectorStoreService.findNearest()` issues an ObjectBox HNSW query
    /// via `nearestNeighbors` + `findWithScores()`. Results arrive pre-sorted ascending
    /// by cosine distance (lower = better). Here we simulate the post-HNSW ranking logic:
    /// 1. Compute cosine similarity between query and each stored chunk
    /// 2. Convert to cosine distance (distance = 1 − similarity) — the HNSW metric
    /// 3. Filter by maximumCosineDistance ≤ 0.7 (equivalent to similarity ≥ 0.3)
    /// 4. Return top-K results sorted ascending by distance
    func testPipeline_Stage5_HNSWSimilaritySearch() async {
        let service = EmbeddingService.shared

        // Index: 3 documents with different topics
        let docs = [
            "Swift concurrency uses async/await for parallel execution.",
            "The solar system has eight planets orbiting the sun.",
            "Actors in Swift provide thread-safe access to mutable state."
        ]

        var storedEmbeddings: [(text: String, embedding: [Float])] = []
        for doc in docs {
            guard let emb = await service.generateEmbedding(for: doc) else {
                XCTFail("Failed to embed: \(doc.prefix(30))")
                return
            }
            storedEmbeddings.append((text: doc, embedding: emb))
        }

        // Query: Ask about Swift concurrency
        guard let queryEmb = await service.generateEmbedding(for: "How does async await work in Swift?") else {
            XCTFail("Failed to embed query")
            return
        }

        // Simulate VectorStoreService.findNearest() post-HNSW filtering
        // HNSW returns cosine distance (ascending, lower = better)
        // Threshold: distance ≤ 0.7  ↔  similarity ≥ 0.3  (for L2-normalised vectors)
        let maximumCosineDistance: Float = 0.7
        let limit = 2

        let scored = storedEmbeddings.map { item -> (text: String, similarity: Float, distance: Float) in
            let sim = VectorMath.cosineSimilarity(between: queryEmb, and: item.embedding)
            return (text: item.text, similarity: sim, distance: 1.0 - sim)
        }

        let ranked = scored
            .sorted { $0.distance < $1.distance }           // ascending distance (HNSW order)
            .filter { $0.distance <= maximumCosineDistance } // threshold: ≤ 0.7 ↔ similarity ≥ 0.3
            .prefix(limit)

        // Verify: The two Swift-related docs should rank above the astronomy doc
        XCTAssertGreaterThanOrEqual(ranked.count, 1,
            "At least one document should pass the maximumCosineDistance ≤ 0.7 threshold")

        // The top result should be about Swift, not planets
        XCTAssertTrue(ranked.first?.text.contains("Swift") ?? false,
            "Top result should be about Swift concurrency, not astronomy")

        // The planet doc should have the highest distance (lowest similarity)
        let planetDist = scored.first(where: { $0.text.contains("planet") })?.distance ?? 2
        let swiftDist = scored.first(where: { $0.text.contains("async/await") })?.distance ?? 2
        XCTAssertLessThan(swiftDist, planetDist,
            "Swift doc should have lower HNSW cosine distance than planet doc for a Swift query")
    }

    // MARK: - Full Pipeline End-to-End

    /// Demonstrates the complete RAG pipeline from message ingestion to retrieval.
    ///
    /// This is the definitive integration test. It walks through every stage:
    /// 1. Create a ChatMessage with rich markdown
    /// 2. Extract ContentBlocks
    /// 3. Chunk the blocks with SemanticChunker
    /// 4. Generate embeddings for each chunk
    /// 5. Assign embeddings to ChildChunkEntity (no converter — native HNSW [Float]? storage)
    /// 6. Generate a query embedding
    /// 7. Rank chunks by cosine similarity (HNSW distance ≤ 0.7 ↔ similarity ≥ 0.3)
    /// 8. Verify the most relevant chunk is retrieved
    func testPipeline_EndToEnd_IngestAndRetrieve() async {
        // ─── Step 1: Create a realistic chat message ───
        let markdown = """
        # Error Handling in Swift

        Swift uses a powerful error handling model based on throwing functions. \
        You mark functions that can fail with the `throws` keyword.

        ```swift
        enum NetworkError: Error {
            case noConnection
            case timeout
        }

        func fetchData() throws -> Data {
            guard isConnected else { throw NetworkError.noConnection }
            return try performRequest()
        }
        ```

        Use `do-catch` blocks to handle errors gracefully. For non-critical errors, \
        you can use `try?` to convert the result to an optional.
        """

        let message = ChatMessage(
            conversationId: UUID(),
            sender: .agent,
            content: .markdownText(markdown)
        )

        // ─── Step 2: Extract ContentBlocks ───
        let blocks = message.getBlocksForIndexing()
        XCTAssertFalse(blocks.isEmpty, "Step 2: Should extract blocks from markdown")

        // ─── Step 3: Semantic Chunking ───
        let chunker = SemanticChunker(maxChunkSize: 300, overlap: 30)
        let chunks = chunker.chunk(blocks: blocks)
        XCTAssertFalse(chunks.isEmpty, "Step 3: Should produce chunks from blocks")

        // ─── Step 4: Generate Embeddings ───
        let service = EmbeddingService.shared
        var chunkEmbeddings: [(text: String, embedding: [Float])] = []

        for chunk in chunks {
            guard let emb = await service.generateEmbedding(for: chunk) else {
                // Some chunks (very short headings) might still embed; skip failures
                continue
            }
            chunkEmbeddings.append((text: chunk, embedding: emb))
        }

        XCTAssertFalse(chunkEmbeddings.isEmpty, "Step 4: Should generate at least one embedding")

        // ─── Step 5: Assign to ChildChunkEntity (HNSW native storage) ───
        // ObjectBox stores [Float]? natively as floatVector; no custom converter needed.
        let entities = chunkEmbeddings.enumerated().map { (i, item) in
            ChildChunkEntity(chunkText: item.text, embedding: item.embedding, chunkIndex: i, conversationID: "")
        }
        for (i, entity) in entities.enumerated() {
            XCTAssertEqual(entity.embedding, chunkEmbeddings[i].embedding,
                "Step 5: Embedding \(i) must be stored verbatim in ChildChunkEntity")
            XCTAssertEqual(entity.embedding?.count, 384,
                "Step 5: All embeddings must be 384-dimensional for the HNSW index")
        }

        // ─── Step 6: Query Embedding ───
        guard let queryEmb = await service.generateEmbedding(for: "How do I handle errors in Swift?") else {
            XCTFail("Step 6: Failed to embed query")
            return
        }

        // ─── Step 7: Similarity Ranking ───
        let scored = chunkEmbeddings.map { item in
            (text: item.text, score: VectorMath.cosineSimilarity(between: queryEmb, and: item.embedding))
        }.sorted { $0.score > $1.score }

        // ─── Step 8: Verify Retrieval Quality ───
        guard let topResult = scored.first else {
            XCTFail("Step 8: No scored results")
            return
        }

        // HNSW threshold: cosine distance ≤ 0.7 ↔ cosine similarity ≥ 0.3 (L2-normalised vectors)
        XCTAssertGreaterThan(topResult.score, 0.3,
            "Step 8: Top chunk should pass similarity ≥ 0.3 (HNSW distance ≤ 0.7), got \(topResult.score)")

        // The top chunk should be about error handling, not something unrelated
        let topChunkIsRelevant = topResult.text.lowercased().contains("error") ||
                                  topResult.text.lowercased().contains("throw") ||
                                  topResult.text.lowercased().contains("catch")
        XCTAssertTrue(topChunkIsRelevant,
            "Step 8: Top retrieved chunk should be about error handling. Got: '\(topResult.text.prefix(80))...'")
    }
}

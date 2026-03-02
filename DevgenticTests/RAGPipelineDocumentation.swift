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
//  ║  4. Embeddings ↔ Data (FloatArrayConverter for ObjectBox)  ║
//  ║  5. Query → Ranked results (VectorMath similarity search)  ║
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

        // Verify: Related chunks should have high similarity
        let similarity = VectorMath.cosineSimilarity(between: embeddings[0], and: embeddings[1])
        XCTAssertGreaterThan(similarity, 0.5,
            "Two chunks about Swift Concurrency should have high similarity (got \(similarity))")
    }

    // MARK: - Stage 4: Storage Roundtrip

    /// Demonstrates how embeddings survive the ObjectBox storage roundtrip.
    ///
    /// ObjectBox doesn't natively support [Float] arrays, so Devgentic uses
    /// `FloatArrayConverter` to serialize embeddings to raw `Data` for storage
    /// and deserialize them back for similarity search. This test verifies that
    /// no precision is lost in the conversion.
    func testPipeline_Stage4_EmbeddingStorageRoundtrip() async {
        // Generate a real embedding
        guard let embedding = await EmbeddingService.shared.generateEmbedding(for: "Storage roundtrip test") else {
            XCTFail("Failed to generate embedding")
            return
        }

        // Simulate ObjectBox storage: [Float] → Data → [Float]
        let storedData = FloatArrayConverter.convert(embedding)
        let restoredEmbedding = FloatArrayConverter.convert(storedData)

        // Verify: Exact equality — no floating-point precision loss in raw Data storage
        XCTAssertEqual(embedding.count, restoredEmbedding.count)
        for i in 0..<embedding.count {
            XCTAssertEqual(embedding[i], restoredEmbedding[i],
                "Mismatch at index \(i): \(embedding[i]) vs \(restoredEmbedding[i])")
        }

        // Verify: The restored embedding still has the correct magnitude
        let mag = VectorMath.magnitude(of: restoredEmbedding)
        XCTAssertEqual(mag, 1.0, accuracy: 1e-4)
    }

    // MARK: - Stage 5: Similarity Search Simulation

    /// Demonstrates how the vector search retrieves the most relevant documents.
    ///
    /// In production, `VectorStoreService.findNearest()` performs this search over
    /// the ObjectBox database. Here we simulate the same algorithm:
    /// 1. Compute cosine similarity between query and each stored chunk
    /// 2. Sort by similarity (descending)
    /// 3. Filter by minimum threshold (0.3)
    /// 4. Return top-K results
    func testPipeline_Stage5_SimilaritySearch() async {
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

        // Simulate VectorStoreService.findNearest() algorithm
        let minimumSimilarity: Float = 0.3
        let limit = 2

        let scored = storedEmbeddings.map { item in
            (text: item.text, score: VectorMath.cosineSimilarity(between: queryEmb, and: item.embedding))
        }

        let ranked = scored
            .sorted { $0.score > $1.score }
            .filter { $0.score >= minimumSimilarity }
            .prefix(limit)

        // Verify: The two Swift-related docs should rank above the astronomy doc
        XCTAssertGreaterThanOrEqual(ranked.count, 1,
            "At least one document should pass the 0.3 similarity threshold")

        // The top result should be about Swift, not planets
        XCTAssertTrue(ranked.first?.text.contains("Swift") ?? false,
            "Top result should be about Swift concurrency, not astronomy")

        // The planet doc should have the lowest score
        let planetScore = scored.first(where: { $0.text.contains("planet") })?.score ?? 0
        let swiftScore = scored.first(where: { $0.text.contains("async/await") })?.score ?? 0
        XCTAssertGreaterThan(swiftScore, planetScore,
            "Swift doc should score higher than planet doc for a Swift query")
    }

    // MARK: - Full Pipeline End-to-End

    /// Demonstrates the complete RAG pipeline from message ingestion to retrieval.
    ///
    /// This is the definitive integration test. It walks through every stage:
    /// 1. Create a ChatMessage with rich markdown
    /// 2. Extract ContentBlocks
    /// 3. Chunk the blocks with SemanticChunker
    /// 4. Generate embeddings for each chunk
    /// 5. Roundtrip through FloatArrayConverter
    /// 6. Generate a query embedding
    /// 7. Rank chunks by cosine similarity
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

        // ─── Step 5: Storage Roundtrip ───
        for i in 0..<chunkEmbeddings.count {
            let data = FloatArrayConverter.convert(chunkEmbeddings[i].embedding)
            let restored = FloatArrayConverter.convert(data)
            XCTAssertEqual(chunkEmbeddings[i].embedding, restored,
                "Step 5: Embedding \(i) should survive storage roundtrip")
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

        XCTAssertGreaterThan(topResult.score, 0.3,
            "Step 8: Top chunk should pass the 0.3 similarity threshold (got \(topResult.score))")

        // The top chunk should be about error handling, not something unrelated
        let topChunkIsRelevant = topResult.text.lowercased().contains("error") ||
                                  topResult.text.lowercased().contains("throw") ||
                                  topResult.text.lowercased().contains("catch")
        XCTAssertTrue(topChunkIsRelevant,
            "Step 8: Top retrieved chunk should be about error handling. Got: '\(topResult.text.prefix(80))...'")
    }
}

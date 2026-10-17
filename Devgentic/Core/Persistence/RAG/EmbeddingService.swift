// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  EmbeddingService.swift
//  Devgentic
//
//  Created by Raj Singh on 13/07/25.
//

import Foundation
import CoreML
import os
import Tokenizers

// MARK: - Errors

enum EmbeddingError: LocalizedError {
    case tokenizerResourceNotFound
    case tokenizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .tokenizerResourceNotFound:
            return "Tokenizer resource files (tokenizer.json / tokenizer_config.json) not found in bundle."
        case .tokenizationFailed(let reason):
            return "Tokenization failed: \(reason)"
        }
    }
}

/// A service responsible for generating text embeddings using a local Core ML model
/// with a real WordPiece tokenizer loaded from bundled Hugging Face tokenizer files.
actor EmbeddingService {

    // MARK: - Singleton Instance
    static let shared = EmbeddingService()

    // MARK: - Private Properties

    /// The loaded Core ML sentence embedding model.
    ///
    /// Provenance (see `THIRD_PARTY_NOTICES.md` → "Bundled models"): `all-MiniLM-L6-v2` by the
    /// sentence-transformers project, **Apache-2.0**, converted to Core ML with coremltools. It was
    /// fine-tuned upstream from `nreimers/MiniLM-L6-H384-uncased` (MIT, a six-layer cut of Microsoft
    /// MiniLM), which is also where the WordPiece tokenizer files under `Resources/AllMiniLMTokenizer`
    /// come from. ⚠️ Not this project's own model — the `.mlpackage` metadata once claimed so; the
    /// author and licence keys there are the attribution and must stay correct.
    private let model: All_MiniLM_L6_v2?

    /// The fixed sequence length the Core ML model expects.
    private let sequenceLength = 128

    /// Output width contract — must match ChildChunkEntity's `dimensions=384`
    /// HNSW annotation. Enforced loudly in `generateEmbedding`: a swapped model
    /// with a different width would otherwise corrupt the index schema silently
    /// (the annotation is the only other place the contract lives).
    static let expectedDimensions = 384

    /// Which model produced the stored vectors, recorded beside the vector store (RAG-32). Vectors
    /// from two models are not comparable even at the same width, so a store written by another
    /// model is set aside rather than mixed. Derived from the GENERATED Core ML class, so swapping
    /// the bundled model changes it without anyone remembering to.
    static let modelIdentifier = "\(String(describing: All_MiniLM_L6_v2.self))/\(expectedDimensions)"

    /// Special-token IDs, resolved from the LOADED tokenizer where possible —
    /// the BERT-vocab literals (102 / 0) remain only as fallbacks. Previously
    /// hardcoded: a tokenizer swap with different special tokens would have
    /// broken truncation/padding silently.
    private var sepTokenID = 102
    private var padTokenID = 0

    /// Embedding cache. The dominant repeat pattern is replace-on-reindex:
    /// re-attaching a file re-embeds mostly byte-identical chunks — this makes
    /// those hits free. FIFO eviction (the win is the burst, not long-lived
    /// reuse); bounded at ~256 × 384 floats ≈ 400 KB.
    private var cache: [String: [Float]] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 256

    /// Test hook: current number of cached embeddings.
    var cachedEmbeddingCount: Int { cache.count }

    /// Whether the missing-model error has been logged this launch.
    private var reportedModelUnavailable = false

    /// Lazy-loaded tokenizer instance (actor isolation provides thread safety).
    private var _tokenizer: (any Tokenizer)?

    /// Logger for diagnostics and error reporting.
    private let logger = DGLogger(category: "EmbeddingService")

    // MARK: - Initialization

    private init() {
        do {
            self.model = try All_MiniLM_L6_v2(configuration: MLModelConfiguration())
            logger.info("[RAG] Loaded the Core ML embedding model (\(Self.modelIdentifier)).")
        } catch {
            self.model = nil
            logger.critical("[RAG] Failed to load the Core ML embedding model: \(error.localizedDescription). CONSEQUENCE: conversation memory is OFF for this launch — nothing is indexed and retrieval finds nothing; chats themselves are unaffected.")
        }
    }

    // MARK: - Public Interface

    /// Generates a vector embedding for a given string of text.
    ///
    /// This function is asynchronous and can be safely called from any thread.
    /// It tokenizes the text using a real WordPiece tokenizer, feeds the numerical
    /// input to the Core ML model, and L2-normalizes the output.
    ///
    /// - Parameter text: The input string to generate an embedding for.
    /// - Returns: An array of `Float` representing the normalized vector embedding, or `nil` if an error occurs.
    func generateEmbedding(for text: String) async -> [Float]? {
        if let cached = cache[text] {
            return cached
        }

        guard let model = self.model else {
            // Once per launch, not once per chunk (RAG-38): a file is ~1k chunks.
            if !reportedModelUnavailable {
                reportedModelUnavailable = true
                logger.error("[RAG] Embedding requested but the model is not loaded. CONSEQUENCE: every embed this launch returns nil — nothing new is indexed and retrieval finds nothing. (Logged once.)")
            }
            return nil
        }

        do {
            // 1. Load the tokenizer (lazy, cached after first call)
            let tokenizer = try await loadTokenizerIfNeeded()

            // 2. Tokenize the input text into MLMultiArrays
            let tokenizedInput = try tokenize(text: text, using: tokenizer)

            // 3. Create the model input
            let input = All_MiniLM_L6_v2Input(
                input_ids: tokenizedInput.inputIDs,
                attention_mask: tokenizedInput.attentionMask
            )

            // 4. Perform the prediction
            let output = try await model.prediction(input: input)

            // 5. Convert the MLMultiArray to a [Float] array
            let embeddingMultiArray = output.var_514
            let floatArray = convertMultiArrayToFloatArray(embeddingMultiArray)

            // 6. L2-normalize the embedding (standard for sentence-transformers)
            // Use safeL2Normalize to catch zero vectors before they reach HNSW
            guard let normalizedArray = VectorMath.safeL2Normalize(floatArray) else {
                // [M6] Length only — `text` is user content (RAG-38).
                logger.warning("[RAG] The model produced a zero vector for a \(text.count)-char chunk. CONSEQUENCE: that chunk is not indexed.")
                return nil
            }

            // 7. Enforce the width contract LOUDLY — a mismatched model would
            // otherwise poison the HNSW index (schema says 384) without a trace.
            guard normalizedArray.count == Self.expectedDimensions else {
                logger.error("[RAG] Embedding width \(normalizedArray.count) ≠ expected \(Self.expectedDimensions) — model/schema mismatch. CONSEQUENCE: this embedding is dropped (the chunk is not indexed, or a query retrieves nothing); every embed from this model will fail the same way.")
                return nil
            }

            cacheStore(text: text, embedding: normalizedArray)
            logger.debug("[RAG] Embedded a \(text.count)-char chunk.")
            return normalizedArray
        } catch {
            logger.error("[RAG] Embedding a \(text.count)-char chunk FAILED: \(error.localizedDescription). CONSEQUENCE: that chunk is not indexed (or, for a query, retrieval is skipped this turn).")
            return nil
        }
    }

    // MARK: - Tokenizer Loading

    /// Loads the WordPiece tokenizer from bundled resource files.
    /// Thread-safe and cached after first successful load.
    private func loadTokenizerIfNeeded() async throws -> any Tokenizer {
        // Fast path: already loaded
        if let existing = _tokenizer { return existing }

        // Load from bundle
        let tokenizer = try await _loadTokenizer()

        // Actor isolation provides thread safety
        if let existing = _tokenizer { return existing }
        _tokenizer = tokenizer

        // Resolve special-token IDs from the tokenizer itself; keep the BERT
        // literals only when the vocabulary doesn't answer.
        if let sep = tokenizer.convertTokenToId("[SEP]") { sepTokenID = sep }
        if let pad = tokenizer.convertTokenToId("[PAD]") { padTokenID = pad }

        logger.info("[RAG] Loaded the WordPiece tokenizer for All-MiniLM-L6-v2 (sep=\(self.sepTokenID), pad=\(self.padTokenID)).")
        return tokenizer
    }

    /// FIFO-bounded cache insert (see `cache` doc for the sizing rationale).
    private func cacheStore(text: String, embedding: [Float]) {
        if cache[text] == nil {
            cacheOrder.append(text)
            if cacheOrder.count > cacheLimit {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        }
        cache[text] = embedding
    }

    private func _loadTokenizer() async throws -> any Tokenizer {
        // Try folder reference first (preserved directory in bundle)
        if let folderURL = Bundle.main.url(forResource: "AllMiniLMTokenizer", withExtension: nil) {
            return try await AutoTokenizer.from(modelFolder: folderURL)
        }

        // Fallback: find individual files and assemble into a temp folder
        guard let tokenizerURL = Bundle.main.url(forResource: "tokenizer", withExtension: "json"),
              let configURL = Bundle.main.url(forResource: "tokenizer_config", withExtension: "json") else {
            throw EmbeddingError.tokenizerResourceNotFound
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllMiniLMTokenizer", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let destTokenizer = tempDir.appendingPathComponent("tokenizer.json")
        let destConfig = tempDir.appendingPathComponent("tokenizer_config.json")

        if !FileManager.default.fileExists(atPath: destTokenizer.path) {
            try FileManager.default.copyItem(at: tokenizerURL, to: destTokenizer)
        }
        if !FileManager.default.fileExists(atPath: destConfig.path) {
            try FileManager.default.copyItem(at: configURL, to: destConfig)
        }

        return try await AutoTokenizer.from(modelFolder: tempDir)
    }

    // MARK: - Tokenization

    /// Tokenizes text into MLMultiArray inputs for the CoreML model.
    /// Encodes with [CLS]/[SEP] special tokens, truncates/pads to sequenceLength.
    private func tokenize(text: String, using tokenizer: any Tokenizer) throws
        -> (inputIDs: MLMultiArray, attentionMask: MLMultiArray)
    {
        // 1. Encode text to token IDs (automatically adds [CLS] and [SEP])
        let tokenIDs = tokenizer.encode(text: text)

        // 2. Truncate if needed, preserving [SEP] at end
        let truncatedIDs: [Int]
        if tokenIDs.count > sequenceLength {
            var ids = Array(tokenIDs.prefix(sequenceLength - 1))
            ids.append(sepTokenID) // resolved from the tokenizer (BERT 102 fallback)
            truncatedIDs = ids
        } else {
            truncatedIDs = tokenIDs
        }

        // 3. Create MLMultiArrays (int32, shape [1, sequenceLength])
        let inputIDs = try MLMultiArray(
            shape: [1, NSNumber(value: sequenceLength)],
            dataType: .int32
        )
        let attentionMask = try MLMultiArray(
            shape: [1, NSNumber(value: sequenceLength)],
            dataType: .int32
        )

        // 4. Fill input_ids and attention_mask
        for i in 0..<sequenceLength {
            if i < truncatedIDs.count {
                inputIDs[i] = NSNumber(value: Int32(truncatedIDs[i]))
                attentionMask[i] = 1 as NSNumber
            } else {
                inputIDs[i] = NSNumber(value: Int32(padTokenID)) // resolved from the tokenizer (0 fallback)
                attentionMask[i] = 0 as NSNumber                 // no attention on padding
            }
        }

        return (inputIDs, attentionMask)
    }

    // MARK: - Vector Math Helpers

    /// Converts an `MLMultiArray` to a `[Float]` array.
    private func convertMultiArrayToFloatArray(_ multiArray: MLMultiArray) -> [Float] {
        let count = multiArray.count
        let pointer = multiArray.dataPointer.bindMemory(to: Float32.self, capacity: count)
        let buffer = UnsafeBufferPointer(start: pointer, count: count)
        return Array(buffer)
    }

}

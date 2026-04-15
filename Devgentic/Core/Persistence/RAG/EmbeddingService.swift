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
    private let model: All_MiniLM_L6_v2?

    /// The fixed sequence length the Core ML model expects.
    private let sequenceLength = 128

    /// Lazy-loaded tokenizer instance (actor isolation provides thread safety).
    private var _tokenizer: (any Tokenizer)?

    /// Logger for diagnostics and error reporting.
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "EmbeddingService")

    // MARK: - Initialization

    private init() {
        do {
            self.model = try All_MiniLM_L6_v2(configuration: MLModelConfiguration())
            logger.info("Successfully loaded Core ML embedding model: All_MiniLM_L6_v2.")
        } catch {
            self.model = nil
            logger.critical("Failed to load Core ML embedding model: \(error.localizedDescription)")
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
        guard let model = self.model else {
            logger.error("Embedding model is not available. Cannot generate embedding.")
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
                logger.warning("Model produced a zero vector for text: '\(text.prefix(50))...' — skipping.")
                return nil
            }

            logger.debug("Generated embedding for text (\(text.prefix(50))...).")
            return normalizedArray
        } catch {
            logger.error("Failed to generate embedding: \(error.localizedDescription)")
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
        logger.info("Successfully loaded WordPiece tokenizer for All-MiniLM-L6-v2.")
        return tokenizer
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
            ids.append(102) // [SEP] token ID for BERT vocab
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
                inputIDs[i] = 0 as NSNumber     // [PAD] token ID = 0
                attentionMask[i] = 0 as NSNumber // no attention on padding
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

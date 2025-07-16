//
//  EmbeddingService.swift
//  Devgentic
//
//  Created by Raj Singh on 13/07/25.
//

import Foundation
import CoreML
import os

/// A placeholder class for tokenizing text.
///
/// NOTE: This is a non-functional placeholder to allow the project to compile. A real implementation
/// is required for the embedding model to work correctly. This would involve loading a vocabulary
/// file (e.g., `vocab.txt`) and implementing a tokenization algorithm like WordPiece, which is
/// standard for BERT-based models like `All-MiniLM-L6-v2`.
fileprivate class Tokenizer {
    /// The fixed sequence length the Core ML model expects (e.g., 128, 256, 512).
    /// This must match the sequence length the model was converted with.
    private let sequenceLength = 128

    /// A placeholder method that simulates tokenization.
    /// - Parameter text: The input string.
    /// - Returns: A tuple containing dummy `MLMultiArray`s for `inputIDs` and `attentionMask`.
    func tokenize(text: String) -> (inputIDs: MLMultiArray, attentionMask: MLMultiArray)? {
        os_log(.info, "Tokenizer: WARNING - Using placeholder tokenizer. A real implementation is required.")
        
        // In a real implementation, you would:
        // 1. Use the vocabulary to convert the input `text` into an array of token IDs.
        // 2. Pad or truncate this array to `sequenceLength`.
        // 3. Create an attention mask (1 for real tokens, 0 for padding).
        
        do {
            let inputIDs = try MLMultiArray(shape: [1, NSNumber(value: sequenceLength)], dataType: .int32)
            let attentionMask = try MLMultiArray(shape: [1, NSNumber(value: sequenceLength)], dataType: .int32)
            
            // Fill with dummy data. A real tokenizer would populate these with actual token data.
            for i in 0..<sequenceLength {
                inputIDs[i] = 0
                attentionMask[i] = 0
            }
            
            // For example, a real tokenizer might set the first token ID to 101 ([CLS])
            // and the corresponding attention mask to 1.
            
            return (inputIDs, attentionMask)
        } catch {
            os_log(.error, "Tokenizer: Failed to create dummy MLMultiArrays: \(error.localizedDescription)")
            return nil
        }
    }
}


/// A service responsible for generating text embeddings using a local Core ML model.
///
/// This class is designed as a singleton to ensure the Core ML model is loaded only once
/// during the application's lifecycle, which is crucial for performance.
class EmbeddingService {

    // MARK: - Singleton Instance
    static let shared = EmbeddingService()

    // MARK: - Private Properties

    /// The loaded Core ML sentence embedding model.
    private let model: All_MiniLM_L6_v2?
    
    /// The tokenizer responsible for converting text into model-compatible numerical input.
    private let tokenizer: Tokenizer

    /// Logger for diagnostics and error reporting.
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "EmbeddingService")

    // MARK: - Initialization

    /// Private initializer to enforce the singleton pattern.
    /// This attempts to load the Core ML model and logs the outcome.
    private init() {
        self.tokenizer = Tokenizer()
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
    /// It first tokenizes the text and then feeds the numerical input to the Core ML model.
    ///
    /// - Parameter text: The input string to generate an embedding for.
    /// - Returns: An array of `Float` representing the vector embedding, or `nil` if an error occurs.
    func generateEmbedding(for text: String) async -> [Float]? {
        guard let model = self.model else {
            logger.error("Embedding model is not available. Cannot generate embedding.")
            return nil
        }
        
        // 1. Tokenize the input text to get numerical representations.
        guard let tokenizedInput = tokenizer.tokenize(text: text) else {
            logger.error("Failed to tokenize input text.")
            return nil
        }

        do {
            // 2. Create the model input using the tokenized data.
            let input = All_MiniLM_L6_v2Input(input_ids: tokenizedInput.inputIDs, attention_mask: tokenizedInput.attentionMask)

            // 3. Perform the prediction.
            let output = try await model.prediction(input: input)
            
            // 4. Access the output using the correct property name 'var_514' as defined in the generated model class.
            let embeddingMultiArray = output.var_514

            // 5. Convert the MLMultiArray to a more usable [Float] array.
            let floatArray = convertMultiArrayToFloatArray(embeddingMultiArray)
            
            logger.debug("Successfully generated embedding for text.")
            return floatArray
        } catch {
            logger.error("Failed to generate embedding for text: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private Helper Methods

    /// Converts an `MLMultiArray` to a `[Float]` array.
    ///
    /// - Parameter multiArray: The `MLMultiArray` output from the Core ML model.
    /// - Returns: A `[Float]` array containing the embedding vector.
    private func convertMultiArrayToFloatArray(_ multiArray: MLMultiArray) -> [Float] {
        // Get the number of elements in the multi-array.
        let count = multiArray.count
        
        // Create a buffer pointer to the memory of the MLMultiArray.
        // We specify Float32 because it's a common type for embedding models.
        let pointer = multiArray.dataPointer.bindMemory(to: Float32.self, capacity: count)
        
        // Create a Swift array from the buffer pointer.
        let buffer = UnsafeBufferPointer(start: pointer, count: count)
        
        return Array(buffer)
    }
}

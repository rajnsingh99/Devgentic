//
//  MLXService.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//

import Foundation
import MLX
// import MLXRandom // Uncomment if MLXRandom is linked for reproducibility
import MLXLLM
import MLXLMCommon
import os

/// A thread-safe actor that manages the lifecycle and inference of local MLX models.
/// It wraps the `MLXLLM` framework functionality to provide a clean API for the rest of the app.
actor MLXService {
    
    // MARK: - Singleton
    static let shared = MLXService()
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic", category: "MLXService")
    
    // MARK: - State
    
    /// The loaded model container (holds weights + tokenizer).
    /// If nil, no model is currently loaded in memory.
    private var modelContainer: ModelContainer?
    
    /// Tracks the directory of the currently loaded model to prevent reloading the same model.
    private var currentModelDirectory: URL?
    
    private init() {}
    
    // MARK: - Lifecycle Management
    
    /// Loads a model from the specified local directory into memory.
    /// - Parameter directory: The URL pointing to the folder containing `config.json` and `.safetensors`.
    func loadModel(from directory: URL) async throws {
        // Optimization: Don't reload if it's already the active model
        if let current = currentModelDirectory, current == directory, modelContainer != nil {
            logger.info("Model already loaded: \(directory.lastPathComponent)")
            return
        }
        
        logger.notice("Loading MLX model from: \(directory.path)")
        
        // 1. Clean up previous model to free RAM
        unloadModel()
        
        do {
            // 2. Configure for local loading
            // We force the seed for reproducibility, though you can make this random.
            // Note: To use specific seeding, add 'MLXRandom' to your project dependencies and uncomment the import.
            // MLXRandom.seed(UInt64(Date().timeIntervalSince1970))
            
            // Create configuration pointing to the local directory
            let config = ModelConfiguration(directory: directory)
            
            // 3. Load weights and tokenizer (This is the heavy operation)
            let container = try await MLXLMCommon.loadModelContainer(configuration: config)
            
            self.modelContainer = container
            self.currentModelDirectory = directory
            
            logger.notice("Successfully loaded MLX model: \(directory.lastPathComponent)")
            
        } catch {
            logger.error("Failed to load MLX model: \(error.localizedDescription)")
            // Ensure state is clean on failure
            unloadModel()
            throw error
        }
    }
    
    /// Unloads the current model from memory. Call this when switching profiles or putting the app in background.
    func unloadModel() {
        if modelContainer != nil {
            logger.info("Unloading MLX model to free resources.")
            modelContainer = nil
            currentModelDirectory = nil
        }
    }
    
    // MARK: - Inference
    
    /// Streams a chat response from the loaded model.
    /// - Parameters:
    ///   - messages: An array of dictionaries, e.g., `[["role": "user", "content": "Hello"]]`.
    ///   - maxTokens: The maximum number of new tokens to generate.
    ///   - temperature: Controls randomness (0.0 = deterministic, 1.0 = creative).
    /// - Returns: An async stream of string tokens.
    func streamChat(
        messages: [[String: String]],
        maxTokens: Int = 2048,
        temperature: Float = 0.6
    ) -> AsyncThrowingStream<String, Error> {
        
        return AsyncThrowingStream { continuation in
            Task {
                guard let container = modelContainer else {
                    continuation.finish(throwing: NSError(domain: "MLXService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No MLX model is currently loaded. Please load a model first."]))
                    return
                }
                
                do {
                    // Use container.perform to safely access the ModelContext (which contains model, processor, tokenizer).
                    // This resolves issues with accessing 'model' directly and needing to reconstruct the context.
                    let stream = try await container.perform { context -> AsyncStream<Generation> in
                        // 1. Apply Chat Template & Tokenize using the context's tokenizer
                        let promptTokens = try context.tokenizer.applyChatTemplate(messages: messages)
                        
                        // 2. Create LMInput
                        let lmInput = LMInput(tokens: MLXArray(promptTokens))
                        
                        // 3. Configure Generation
                        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: temperature)
                        
                        // 4. Run Inference
                        return try MLXLMCommon.generate(
                            input: lmInput,
                            parameters: parameters,
                            context: context
                        )
                    }
                    
                    for await generation in stream {
                        switch generation {
                        case .chunk(let text):
                            continuation.yield(text)
                        case .toolCall, .info:
                            // We ignore tool calls and info stats for the basic chat stream
                            break
                        }
                    }
                    
                    // Finished successfully
                    continuation.finish()
                    
                } catch {
                    logger.error("MLX Generation Error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

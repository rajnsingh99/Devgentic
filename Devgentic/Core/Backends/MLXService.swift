//
//  MLXService.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//

import Foundation
import MLX
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
    
    /// Task handle for the auto-unload timer.
    private var idleCleanupTask: Task<Void, Never>?
    
    /// The duration of inactivity before the model is automatically unloaded to save RAM.
    /// Default: 300 seconds (5 minutes).
    private let idleTimeoutNanoseconds: UInt64 = 2 * 60 * 1_000_000_000
    
    private init() {}
    
    // MARK: - Lifecycle Management
    
    /// Loads a model from the specified local directory into memory.
    /// - Parameter directory: The URL pointing to the folder containing `config.json` and `.safetensors`.
    func loadModel(from directory: URL) async throws {
        // Cancel any pending unload timer since we are about to use the model (or load a new one)
        cancelIdleTimer()
        
        // Optimization: Don't reload if it's already the active model
        if let current = currentModelDirectory, current == directory, modelContainer != nil {
            logger.info("Model already loaded: \(directory.lastPathComponent)")
            return
        }
        
        logger.notice("Loading MLX model from: \(directory.path)")
        
        // 1. Clean up previous model to free RAM
        _ = unloadModel()
        
        do {
            // 2. Configure for local loading
            let config = ModelConfiguration(directory: directory)
            
            // 3. Load weights and tokenizer (This is the heavy operation)
            let container = try await MLXLMCommon.loadModelContainer(configuration: config)
            
            self.modelContainer = container
            self.currentModelDirectory = directory
            
            logger.notice("Successfully loaded MLX model: \(directory.lastPathComponent)")
            self.logMemoryStats(label: "Post-Load")
            
        } catch {
            logger.error("Failed to load MLX model: \(error.localizedDescription)")
            // Ensure state is clean on failure
            _ = unloadModel()
            throw error
        }
    }
    
    /// Unloads the current model from memory and forces a cache clear.
    /// - Returns: A dictionary containing memory stats (freed bytes, remaining active, remaining cache).
    @discardableResult
    func unloadModel() -> [String: Int] {
        cancelIdleTimer()
        
        // 1. VISUALIZATION STEP 1: Initial State
        let activeBefore = MLX.GPU.activeMemory
        let cacheBefore = MLX.GPU.cacheMemory
        let totalBefore = activeBefore + cacheBefore
        
        logger.notice("🔻 [Unload Start] Active: \(ByteCountFormatter.string(fromByteCount: Int64(activeBefore), countStyle: .memory)) | Cache: \(ByteCountFormatter.string(fromByteCount: Int64(cacheBefore), countStyle: .memory))")
        
        if modelContainer != nil {
            // 2. Release Swift reference
            modelContainer = nil
            currentModelDirectory = nil
            
            // 3. VISUALIZATION STEP 2: Intermediate State (Swift Release)
            // At this point, Active should drop, but Cache should spike as buffers are recycled.
            let activeIntermediate = MLX.GPU.activeMemory
            let cacheIntermediate = MLX.GPU.cacheMemory
            logger.debug("🔸 [Ref Released] Active: \(ByteCountFormatter.string(fromByteCount: Int64(activeIntermediate), countStyle: .memory)) | Cache: \(ByteCountFormatter.string(fromByteCount: Int64(cacheIntermediate), countStyle: .memory)) (Memory moved to cache)")
            
            // 4. FORCE MLX GPU CACHE CLEAR
            // This tells Metal to return the memory to the OS immediately.
            MLX.GPU.clearCache()
            
            // 5. VISUALIZATION STEP 3: Final State
            let activeAfter = MLX.GPU.activeMemory
            let cacheAfter = MLX.GPU.cacheMemory
            let totalAfter = activeAfter + cacheAfter
            
            let freedBytes = totalBefore - totalAfter
            
            logger.notice("✅ [Unload Done] Freed: \(ByteCountFormatter.string(fromByteCount: Int64(freedBytes), countStyle: .memory)) | Remaining Cache: \(ByteCountFormatter.string(fromByteCount: Int64(cacheAfter), countStyle: .memory))")
            
            return [
                "freedBytes": freedBytes,
                "activeMemory": activeAfter,
                "cacheMemory": cacheAfter
            ]
        } else {
            // Even if modelContainer was nil, force clear artifacts
            let cacheBeforeClear = MLX.GPU.cacheMemory
            MLX.GPU.clearCache()
            let cacheAfterClear = MLX.GPU.cacheMemory
            let freed = cacheBeforeClear - cacheAfterClear
            
            if freed > 0 {
                logger.notice("✅ [Cache Cleanup] Freed artifacts: \(ByteCountFormatter.string(fromByteCount: Int64(freed), countStyle: .memory))")
            }
            
            return [
                "freedBytes": freed,
                "activeMemory": MLX.GPU.activeMemory,
                "cacheMemory": cacheAfterClear
            ]
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
        
        // 1. Cancel any pending idle timer because we are active now.
        cancelIdleTimer()
        
        return AsyncThrowingStream { continuation in
            Task {
                guard let container = modelContainer else {
                    continuation.finish(throwing: NSError(domain: "MLXService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No MLX model is currently loaded. Please load a model first."]))
                    return
                }
                
                do {
                    // Use container.perform to safely access the ModelContext (which contains model, processor, tokenizer).
                    let stream = try await container.perform { context -> AsyncStream<Generation> in
                        // A. Apply Chat Template & Tokenize
                        let promptTokens = try context.tokenizer.applyChatTemplate(messages: messages)
                        
                        // B. Create LMInput
                        let lmInput = LMInput(tokens: MLXArray(promptTokens))
                        
                        // C. Configure Generation
                        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: temperature)
                        
                        // D. Run Inference
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
                            break
                        }
                    }
                    
                    continuation.finish()
                    
                } catch {
                    logger.error("MLX Generation Error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
                
                // 2. Inference is complete (success or failure). Start the idle timer.
                await self.startIdleTimer()
            }
        }
    }
    
    // MARK: - Diagnostics
    
    private func logMemoryStats(label: String) {
        let active = ByteCountFormatter.string(fromByteCount: Int64(MLX.GPU.activeMemory), countStyle: .memory)
        let cache = ByteCountFormatter.string(fromByteCount: Int64(MLX.GPU.cacheMemory), countStyle: .memory)
        logger.debug("[\(label)] MLX Memory - Active: \(active), Cache: \(cache)")
    }
    
    // MARK: - Idle Management
    
    /// Starts a timer that will unload the model if no further requests are made.
    private func startIdleTimer() {
        cancelIdleTimer() // Ensure no duplicate timers
        
        logger.debug("Starting idle timer. Model will unload in 5 minutes if inactive.")
        
        idleCleanupTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: idleTimeoutNanoseconds)
                
                // If we reached here without cancellation, unload.
                guard let self = self else { return }
                
                // Check for cancellation one last time before acting
                if !Task.isCancelled {
                    await self.handleIdleTimeout()
                }
            } catch {
                // Task was cancelled (new request came in), do nothing.
            }
        }
    }
    
    /// Cancels the current idle timer.
    private func cancelIdleTimer() {
        if let task = idleCleanupTask {
            task.cancel()
            idleCleanupTask = nil
            logger.debug("Idle timer cancelled. Model remains active.")
        }
    }
    
    /// The action to perform when the timer fires.
    private func handleIdleTimeout() {
        logger.notice("MLX Service has been idle for 5 minutes. Releasing memory.")
        _ = unloadModel()
    }
}

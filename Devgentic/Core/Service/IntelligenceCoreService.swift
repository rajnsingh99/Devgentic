//
//  IntelligenceCoreService.swift
//  Devgentic
//
//  Created by Antigravity on 12/03/26.
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Hub
import os

/// A specialized service for managing the "Intelligence Core" MLX model.
/// This model is managed separately from user-downloaded models.
actor IntelligenceCoreService {
    
    static let shared = IntelligenceCoreService()
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic", category: "IntelligenceCoreService")
    
    private let modelId = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    
    private var modelContainer: ModelContainer?
    
    // MARK: - Configuration
    
    private var modelsDirectory: URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let path = appSupport.appendingPathComponent("huggingface/intelligence_core")
        
        if !fileManager.fileExists(atPath: path.path) {
            try? fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        }
        return path
    }
    
    private var hub: HubApi {
        return HubApi(downloadBase: modelsDirectory)
    }
    
    private init() {}
    
    // MARK: - Model Management
    
    /// Checks if the model is already downloaded.
    func isDownloaded() -> Bool {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey]
        
        guard let enumerator = fileManager.enumerator(
            at: modelsDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }
        
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "config.json" {
                return true
            }
        }
        return false
    }
    
    /// Downloads the intelligence core model if not present.
    func downloadIfNeeded(progressHandler: @escaping (Progress) -> Void) async throws {
        if isDownloaded() {
            logger.info("Intelligence Core model is already downloaded.")
            return
        }
        
        logger.notice("Downloading Intelligence Core model: \(self.modelId)")
        let config = ModelConfiguration(id: modelId)
        
        _ = try await MLXLMCommon.downloadModel(
            hub: hub,
            configuration: config,
            progressHandler: progressHandler
        )
        
        logger.notice("Intelligence Core model download complete.")
    }
    
    /// Loads the model into memory.
    func load() async throws {
        if modelContainer != nil { return }
        
        logger.notice("Loading Intelligence Core model into memory...")
        
        let config = ModelConfiguration(id: modelId)
        // We need to ensure Hub uses our custom directory
        let container = try await MLXLMCommon.loadModelContainer(
            hub: hub,
            configuration: config
        )
        
        self.modelContainer = container
        logger.notice("Intelligence Core model loaded successfully.")
    }
    
    /// Unloads the model from memory.
    func unload() {
        if modelContainer != nil {
            modelContainer = nil
            MLX.GPU.clearCache()
            logger.notice("Intelligence Core model unloaded and GPU cache cleared.")
        }
    }
    
    // MARK: - Inference
    
    /// Synchronous generation (collects all tokens).
    func generate(messages: [[String: String]], maxTokens: Int = 1024, temperature: Float = 0.6) async throws -> String {
        try await load()
        
        guard let container = modelContainer else {
            throw NSError(domain: "IntelligenceCoreService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Model container not available."])
        }
        
        return try await container.perform { context in
            let promptTokens = try context.tokenizer.applyChatTemplate(messages: messages.map { $0 as [String: Any] })
            let lmInput = LMInput(tokens: MLXArray(promptTokens))
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: temperature)
            
            let stream = try MLXLMCommon.generate(
                input: lmInput,
                parameters: parameters,
                context: context
            )
            
            var fullText = ""
            for await generation in stream {
                if case .chunk(let text) = generation {
                    fullText += text
                }
            }
            return fullText
        }
    }
}

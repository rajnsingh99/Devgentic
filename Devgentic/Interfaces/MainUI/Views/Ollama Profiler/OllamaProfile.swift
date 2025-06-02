//
//  OllamaProfile.swift
//  Devgentic
//
//  Created by Raj Singh on 01/06/25.
//

import Foundation


// MARK: - OllamaProfile Struct

/// Represents a single Ollama configuration profile, including its base URL,
/// selected model, and advanced generation/file handling parameters.
struct OllamaProfile: Codable, Identifiable, Hashable {
    let id: UUID // Unique identifier for the profile
    var profileName: String // User-defined name for the profile (e.g., "Local Ollama", "Cloud Ollama")
    var baseURL: String // The base URL of the Ollama server for this profile

    // Ollama Model Selection
    var llmModelName: String // The currently selected large language model for this profile (e.g., "gemma:2b")

    // Advanced Generation Parameters (defaults from MainApplicationViewModel)
    var temperature: Double
    var topK: Int
    var topP: Double
    var repeatPenalty: Double
    var contextWindowSize: Int
    var gpuLayers: Int

    // File Handling Parameters (defaults from MainApplicationViewModel)
    var maxInlineChars: Int
    var maxAttachedFiles: Int
    var textFileInclusionStrategy: TextFileInclusionStrategy
    var imageHandlingStrategy: OllamaImageHandlingStrategy
    var binaryFileHandlingStrategy: OllamaBinaryFileHandlingStrategy

    // Conformance to Hashable for easy comparison and use in collections like Set
    // All properties in OllamaProfile are themselves Hashable (UUID, String, Double, Int, and our custom Enums which are String raw values)
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(profileName)
        hasher.combine(baseURL)
        hasher.combine(llmModelName)
        hasher.combine(temperature)
        hasher.combine(topK)
        hasher.combine(topP)
        hasher.combine(repeatPenalty)
        hasher.combine(contextWindowSize)
        hasher.combine(gpuLayers)
        hasher.combine(maxInlineChars)
        hasher.combine(maxAttachedFiles)
        hasher.combine(textFileInclusionStrategy)
        hasher.combine(imageHandlingStrategy)
        hasher.combine(binaryFileHandlingStrategy)
    }

    static func == (lhs: OllamaProfile, rhs: OllamaProfile) -> Bool {
        // For equality, comparing just the ID is usually sufficient for identifiable objects,
        // but for full value equality, all properties should be compared.
        // Given that it's a profile, changes to any property should make it "different".
        lhs.id == rhs.id &&
        lhs.profileName == rhs.profileName &&
        lhs.baseURL == rhs.baseURL &&
        lhs.llmModelName == rhs.llmModelName &&
        lhs.temperature == rhs.temperature &&
        lhs.topK == rhs.topK &&
        lhs.topP == rhs.topP &&
        lhs.repeatPenalty == rhs.repeatPenalty &&
        lhs.contextWindowSize == rhs.contextWindowSize &&
        lhs.gpuLayers == rhs.gpuLayers &&
        lhs.maxInlineChars == rhs.maxInlineChars &&
        lhs.maxAttachedFiles == rhs.maxAttachedFiles &&
        lhs.textFileInclusionStrategy == rhs.textFileInclusionStrategy &&
        lhs.imageHandlingStrategy == rhs.imageHandlingStrategy &&
        lhs.binaryFileHandlingStrategy == rhs.binaryFileHandlingStrategy
    }

    /// Provides a default OllamaProfile instance.
    static func defaultProfile() -> OllamaProfile {
        OllamaProfile(
            id: UUID(),
            profileName: "Local Ollama (Default)",
            baseURL: "http://localhost:11434",
            llmModelName: "gemma:2b", // Default model name
            temperature: 0.8,
            topK: 40,
            topP: 0.9,
            repeatPenalty: 1.1,
            contextWindowSize: 4096,
            gpuLayers: -1, // -1 typically means all available GPU layers
            maxInlineChars: 5000,
            maxAttachedFiles: 5,
            textFileInclusionStrategy: .preferInlining,
            imageHandlingStrategy: .includePathWithWarning,
            binaryFileHandlingStrategy: .includePathWithWarning
        )
    }
}

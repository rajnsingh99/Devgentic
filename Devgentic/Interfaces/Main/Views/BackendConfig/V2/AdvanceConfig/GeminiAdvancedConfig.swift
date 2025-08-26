//
//  GeminiAdvancedConfig.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//

import Foundation

/// A Codable struct that represents the advanced configuration options for the Google Gemini API.
/// It includes both generation settings and safety settings.
struct GeminiAdvancedConfig: Codable, Hashable {
    
    // MARK: - Generation Configuration
    
    /// Controls the randomness of the output. Higher values (closer to 1.0) make the output more random,
    /// while lower values make it more deterministic.
    var temperature: Double?
    
    /// The cumulative probability of tokens to consider when sampling.
    var topP: Double?
    
    /// The maximum number of tokens to consider when sampling.
    var topK: Int?
    
    /// The maximum number of tokens to generate in the response.
    var maxOutputTokens: Int?
    
    /// A set of sequences that will stop the generation of output.
    var stopSequences: [String]?
    
    // MARK: - Safety Settings
    
    /// A collection of safety settings for different harm categories.
    var safetySettings: [SafetySetting]?
    
    /// Creates a default configuration for Gemini.
    static func `default`() -> GeminiAdvancedConfig {
        GeminiAdvancedConfig(
            temperature: 0.9,
            topP: 1.0,
            topK: 1,
            maxOutputTokens: 2048,
            stopSequences: [],
            safetySettings: [
                .init(category: .harassment, threshold: .blockMediumAndAbove),
                .init(category: .hateSpeech, threshold: .blockMediumAndAbove),
                .init(category: .sexuallyExplicit, threshold: .blockMediumAndAbove),
                .init(category: .dangerousContent, threshold: .blockMediumAndAbove)
            ]
        )
    }
}

// MARK: - Supporting Enums and Structs for Safety Settings

/// Represents a single safety setting for a specific harm category.
/// Conforms to `Identifiable` so it can be used in a `ForEach` loop.
struct SafetySetting: Codable, Hashable, Identifiable {
    // FIXED: Add `id` to conform to Identifiable. The category is a unique identifier.
    var id: HarmCategory { category }
    
    let category: HarmCategory
    // FIXED: Change `threshold` from `let` to `var` so the Picker can modify it.
    var threshold: HarmBlockThreshold
}

/// The category of harmful content to be configured.
enum HarmCategory: String, Codable, Hashable, CaseIterable {
    case harassment = "HARM_CATEGORY_HARASSMENT"
    case hateSpeech = "HARM_CATEGORY_HATE_SPEECH"
    case sexuallyExplicit = "HARM_CATEGORY_SEXUALLY_EXPLICIT"
    case dangerousContent = "HARM_CATEGORY_DANGEROUS_CONTENT"
}

/// The threshold for blocking content in a specific harm category.
enum HarmBlockThreshold: String, Codable, Hashable, CaseIterable {
    case unspecified = "HARM_BLOCK_THRESHOLD_UNSPECIFIED"
    case blockLowAndAbove = "BLOCK_LOW_AND_ABOVE"
    case blockMediumAndAbove = "BLOCK_MEDIUM_AND_ABOVE"
    case blockOnlyHigh = "BLOCK_ONLY_HIGH"
    case blockNone = "BLOCK_NONE"
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GeminiAdvancedConfig.swift
//  Devgentic
//
//  Created by Raj Singh.
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
            // `nil` omits topK so the model applies its own default; `1` is greedy decoding, making temperature inert.
            // Shipped as-is for unconfigured Gemini profiles via `AgentConnect.initializeModel`.
            topK: nil,
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
    
    // MARK: - Codable Implementation
    
    // Keys for manual decoding to handle potential type mismatches from older versions.
    private enum CodingKeys: String, CodingKey {
        case temperature, topP, topK, maxOutputTokens, stopSequences, safetySettings
    }

    // Since we provide a custom decoder, we must also provide a memberwise initializer
    // so that methods like `default()` continue to function correctly.
    init(temperature: Double?, topP: Double?, topK: Int?, maxOutputTokens: Int?, stopSequences: [String]?, safetySettings: [SafetySetting]?) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxOutputTokens = maxOutputTokens
        self.stopSequences = stopSequences
        self.safetySettings = safetySettings
    }

    /// Custom decoder to handle cases where a numeric type was incorrectly saved as a Bool.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // For `temperature`, first try to decode a Double. If that fails, try a Bool.
        if let tempDouble = try? container.decode(Double.self, forKey: .temperature) {
            self.temperature = tempDouble
        } else if let tempBool = try? container.decode(Bool.self, forKey: .temperature) {
            self.temperature = tempBool ? 1.0 : 0.0 // Convert bool to a sensible default double
        } else {
            self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        }

        // For `topP`, first try to decode a Double. If that fails, try a Bool.
        if let topPDouble = try? container.decode(Double.self, forKey: .topP) {
            self.topP = topPDouble
        } else if let topPBool = try? container.decode(Bool.self, forKey: .topP) {
            self.topP = topPBool ? 1.0 : 0.0 // Convert bool to a sensible default double
        } else {
            self.topP = try container.decodeIfPresent(Double.self, forKey: .topP)
        }

        // For `topK`, first try to decode an Int, then a Bool.
        // A stored `1` is repaired to nil: it was the old greedy default, indistinguishable from never touched.
        if let topKInt = try? container.decode(Int.self, forKey: .topK) {
            self.topK = topKInt == 1 ? nil : topKInt
        } else if let topKBool = try? container.decode(Bool.self, forKey: .topK) {
            self.topK = topKBool ? nil : 0 // legacy bool: `true` meant 1, i.e. the greedy value
        } else {
            let stored = try container.decodeIfPresent(Int.self, forKey: .topK)
            self.topK = stored == 1 ? nil : stored
        }
        
        // **FIXED**: For `maxOutputTokens`, first try to decode an Int. If that fails, try a Bool.
        if let maxTokensInt = try? container.decode(Int.self, forKey: .maxOutputTokens) {
            self.maxOutputTokens = maxTokensInt
        } else if let maxTokensBool = try? container.decode(Bool.self, forKey: .maxOutputTokens) {
            self.maxOutputTokens = maxTokensBool ? 2048 : 0 // Convert bool to a sensible default int
        } else {
            self.maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        }

        // Decode all other properties normally.
        self.stopSequences = try container.decodeIfPresent([String].self, forKey: .stopSequences)
        self.safetySettings = try container.decodeIfPresent([SafetySetting].self, forKey: .safetySettings)
    }
}

// MARK: - Supporting Enums and Structs for Safety Settings

/// Represents a single safety setting for a specific harm category.
/// Conforms to `Identifiable` so it can be used in a `ForEach` loop.
struct SafetySetting: Codable, Hashable, Identifiable {
    var id: HarmCategory { category }
    let category: HarmCategory
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

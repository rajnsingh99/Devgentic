// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OllamaAdvancedConfig.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Distinguishes agent-tuned defaults (low temperature, fixed seed, tight sampling) from chat-tuned defaults (warmer,
/// no fixed seed, looser sampling). Passed into `OllamaSettingsView` so "Apply Optimal" produces the right preset for
/// the host profile.
enum OllamaConfigDefaultProfile {
    case agent
    case chat
}

extension OllamaConfigDefaultProfile {

    /// Which preset ladder a profile type is on: `.bot` is the only conversational type, while `.agent`, `.code` and
    /// `.workflow` run the tool loop and use the agent ladder. One mapping shared by the request factory and
    /// `EffectiveContextWindow`, so they agree on the window.
    static func forProfileType(_ type: ProfileType) -> OllamaConfigDefaultProfile {
        type == .bot ? .chat : .agent
    }
}

/// A Codable struct that represents the advanced configuration options for the Ollama API.
struct OllamaAdvancedConfig: Codable, Hashable {
    
    // MARK: - Generation Configuration
    
    /// Controls the randomness of the output.
    var temperature: Double?
    
    /// The cumulative probability of tokens to consider when sampling.
    var topP: Double?
    
    /// The maximum number of tokens to consider when sampling.
    var topK: Int?
    
    /// Sets the size of the context window (in tokens) that the model considers when generating a response.
    var numCtx: Int?
    
    /// A set of sequences that will stop the generation of output.
    var stop: [String]?
    
    /// A seed for the random number generator to ensure reproducible outputs.
    var seed: Int?
    
    /// Penalty for repeating tokens to prevent degenerate loops.
    var repeatPenalty: Double?

    /// Represents the different size tiers for Ollama models.
    enum ModelTier: String, CaseIterable, Identifiable {
        case tiny = "Tiny (1B-3B)"
        case smallMedium = "Small/Medium (7B-14B)"
        case large = "Large (70B+)"
        
        var id: String { self.rawValue }
    }
    
    /// Creates a default configuration for Ollama.
    static func `default`() -> OllamaAdvancedConfig {
        return .preset(for: .smallMedium)
    }
    
    /// Returns a preset configuration optimized for the specific model tier.
    static func preset(for tier: ModelTier) -> OllamaAdvancedConfig {
        switch tier {
        case .tiny:
            return OllamaAdvancedConfig(
                temperature: 0.05,
                topP: 0.2,
                topK: 5,
                numCtx: 4096,
                stop: [],
                seed: 42,
                repeatPenalty: 1.2
            )
        case .smallMedium:
            return OllamaAdvancedConfig(
                temperature: 0.1,
                topP: 0.6,
                topK: 40,
                numCtx: 8192,
                stop: [],
                seed: 42,
                repeatPenalty: 1.1
            )
        case .large:
            return OllamaAdvancedConfig(
                temperature: 0.3,
                topP: 0.8,
                topK: 50,
                numCtx: 16384,
                stop: [],
                seed: 42,
                repeatPenalty: 1.05
            )
        }
    }
    
    /// Returns the recommended config for this model and host profile, mapping the 5-tier `ModelTier` into Ollama's
    /// 3-tier preset vocabulary and dispatching to the agent or chat preset. The tier mapping is inlined to avoid
    /// colliding with the nested `OllamaAdvancedConfig.ModelTier`.
    static func recommended(for metadata: ModelMetadata, profile: OllamaConfigDefaultProfile) -> OllamaAdvancedConfig {
        let presetTier: ModelTier   // resolves to OllamaAdvancedConfig.ModelTier (inner)
        switch metadata.tier {       // metadata.tier is the GLOBAL ModelTier (outer)
        case .tiny:                   presetTier = .tiny
        case .small, .medium:         presetTier = .smallMedium
        case .large, .ultra:          presetTier = .large
        }
        return profile == .agent
            ? .preset(for: presetTier)
            : .botPreset(for: presetTier)
    }

    /// Returns a preset optimized for conversational bot use (higher creativity, no fixed seed).
    static func botPreset(for tier: ModelTier) -> OllamaAdvancedConfig {
        switch tier {
        case .tiny:
            return OllamaAdvancedConfig(
                temperature: 0.5, topP: 0.8, topK: 40,
                numCtx: 4096, stop: [], seed: nil, repeatPenalty: 1.1)
        case .smallMedium:
            return OllamaAdvancedConfig(
                temperature: 0.7, topP: 0.9, topK: 50,
                numCtx: 8192, stop: [], seed: nil, repeatPenalty: 1.05)
        case .large:
            return OllamaAdvancedConfig(
                temperature: 0.7, topP: 0.9, topK: 50,
                numCtx: 16384, stop: [], seed: nil, repeatPenalty: 1.0)
        }
    }

    // MARK: - Codable Implementation
    
    private enum CodingKeys: String, CodingKey {
        case temperature, topP, topK, numCtx, stop, seed, repeatPenalty
    }
    
    // Memberwise initializer required due to custom decoder.
    init(temperature: Double?, topP: Double?, topK: Int?, numCtx: Int?, stop: [String]?, seed: Int?, repeatPenalty: Double? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.numCtx = numCtx
        self.stop = stop
        self.seed = seed
        self.repeatPenalty = repeatPenalty
    }
    
    /// Custom decoder to handle cases where numeric types were incorrectly saved as Bools.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Robustly decode Double properties
        if let tempDouble = try? container.decode(Double.self, forKey: .temperature) {
            self.temperature = tempDouble
        } else if let tempBool = try? container.decode(Bool.self, forKey: .temperature) {
            self.temperature = tempBool ? 1.0 : 0.0
        } else {
            self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        }
        
        if let topPDouble = try? container.decode(Double.self, forKey: .topP) {
            self.topP = topPDouble
        } else if let topPBool = try? container.decode(Bool.self, forKey: .topP) {
            self.topP = topPBool ? 1.0 : 0.0
        } else {
            self.topP = try container.decodeIfPresent(Double.self, forKey: .topP)
        }
        
        // Robustly decode Int properties
        if let topKInt = try? container.decode(Int.self, forKey: .topK) {
            self.topK = topKInt
        } else if let topKBool = try? container.decode(Bool.self, forKey: .topK) {
            self.topK = topKBool ? 1 : 0
        } else {
            self.topK = try container.decodeIfPresent(Int.self, forKey: .topK)
        }
        
        if let numCtxInt = try? container.decode(Int.self, forKey: .numCtx) {
            self.numCtx = numCtxInt
        } else if let numCtxBool = try? container.decode(Bool.self, forKey: .numCtx) {
            self.numCtx = numCtxBool ? 1 : 0
        } else {
            self.numCtx = try container.decodeIfPresent(Int.self, forKey: .numCtx)
        }
        
        if let seedInt = try? container.decode(Int.self, forKey: .seed) {
            self.seed = seedInt
        } else if let seedBool = try? container.decode(Bool.self, forKey: .seed) {
            self.seed = seedBool ? 1 : 0
        } else {
            self.seed = try container.decodeIfPresent(Int.self, forKey: .seed)
        }
        
        if let repeatPenaltyDouble = try? container.decode(Double.self, forKey: .repeatPenalty) {
            self.repeatPenalty = repeatPenaltyDouble
        } else if let repeatPenaltyBool = try? container.decode(Bool.self, forKey: .repeatPenalty) {
            self.repeatPenalty = repeatPenaltyBool ? 1.0 : 0.0
        } else {
            self.repeatPenalty = try container.decodeIfPresent(Double.self, forKey: .repeatPenalty)
        }
        
        // Decode other properties normally
        self.stop = try container.decodeIfPresent([String].self, forKey: .stop)
    }
}

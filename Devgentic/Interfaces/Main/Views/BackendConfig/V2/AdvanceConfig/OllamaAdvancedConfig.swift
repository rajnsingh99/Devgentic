//
//  OllamaAdvancedConfig.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//

import Foundation

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
    
    /// Creates a default configuration for Ollama.
    static func `default`() -> OllamaAdvancedConfig {
        OllamaAdvancedConfig(
            temperature: 0.8,
            topP: 0.9,
            topK: 40,
            numCtx: 2048,
            stop: [],
            seed: nil
        )
    }
}

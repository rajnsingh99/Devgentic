//
//  OllamaAdvancedConfig.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//
//  Fixed on 27/08/25 to add robust decoding for legacy boolean values.
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
    
    // MARK: - Codable Implementation
    
    private enum CodingKeys: String, CodingKey {
        case temperature, topP, topK, numCtx, stop, seed
    }
    
    // Memberwise initializer required due to custom decoder.
    init(temperature: Double?, topP: Double?, topK: Int?, numCtx: Int?, stop: [String]?, seed: Int?) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.numCtx = numCtx
        self.stop = stop
        self.seed = seed
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
        
        // Decode other properties normally
        self.stop = try container.decodeIfPresent([String].self, forKey: .stop)
    }
}

//
//  DeepseekAdvancedConfig.swift
//  Devgentic
//
//  Created by Raj Singh on 25/08/25.
//

import Foundation

struct DeepseekAdvancedConfig: Codable, Hashable {
    
    // MARK: - Generation Configuration
    
    var temperature: Double?
    var topP: Double?
    var maxTokens: Int?
    var frequencyPenalty: Double?
    var presencePenalty: Double?
    
    // Maps Swift-style camelCase properties to snake_case keys for JSON encoding.
    enum CodingKeys: String, CodingKey {
        case temperature
        case topP = "top_p"
        case maxTokens = "max_tokens"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
    }
    
    /// Provides a default, sensible configuration for Deepseek models.
    static func `default`() -> DeepseekAdvancedConfig {
        DeepseekAdvancedConfig(
            temperature: 1.0,
            topP: 0.9,
            maxTokens: 2048,
            frequencyPenalty: 0.0,
            presencePenalty: 0.0
        )
    }
}

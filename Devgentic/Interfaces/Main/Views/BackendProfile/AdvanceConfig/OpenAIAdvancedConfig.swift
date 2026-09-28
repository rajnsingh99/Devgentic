// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OpenAIAdvancedConfig.swift
//  Devgentic
//
//  Created by Raj Singh on 27/03/26.
//

import Foundation

/// A Codable struct that represents the advanced configuration options for the OpenAI API.
/// Includes generation parameters and reasoning effort for o-series models.
struct OpenAIAdvancedConfig: Codable, Hashable {

    // MARK: - Generation Configuration

    /// The maximum number of tokens to generate in the response.
    /// When nil, the model decides the appropriate length.
    var maxTokens: Int?

    /// Controls the randomness of the output. Range: 0.0–2.0.
    var temperature: Double?

    /// The cumulative probability of tokens to consider when sampling.
    var topP: Double?

    /// A set of sequences that will stop the generation of output.
    var stopSequences: [String]?

    // MARK: - Reasoning Configuration

    /// Controls the reasoning effort for o-series models (o1, o3, etc.).
    /// Valid values: "low", "medium", "high". When nil, uses the model's default.
    var reasoningEffort: String?

    // MARK: - OpenRouter Routing

    /// OpenRouter only: when true, requests carry `provider.data_collection: "deny"`, so OpenRouter
    /// routes only to upstream providers that do not retain or train on prompts. Off (nil) by
    /// default — many `:free` models are served ONLY by providers that do collect data, and with
    /// this on OpenRouter refuses them ("No endpoints found matching your data policy").
    /// Ignored by OpenAI proper, which shares this config type.
    var denyDataCollection: Bool?

    /// Creates a default configuration for OpenAI.
    static func `default`() -> OpenAIAdvancedConfig {
        OpenAIAdvancedConfig(
            maxTokens: nil,
            temperature: 1.0,
            topP: nil,
            stopSequences: nil,
            reasoningEffort: nil,
            denyDataCollection: nil
        )
    }

    // MARK: - Codable Implementation

    private enum CodingKeys: String, CodingKey {
        case maxTokens, temperature, topP, stopSequences, reasoningEffort, denyDataCollection
    }

    // Memberwise initializer required due to custom decoder.
    init(maxTokens: Int?, temperature: Double?, topP: Double?,
         stopSequences: [String]?, reasoningEffort: String?, denyDataCollection: Bool? = nil) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stopSequences = stopSequences
        self.reasoningEffort = reasoningEffort
        self.denyDataCollection = denyDataCollection
    }

    /// Custom decoder to handle cases where numeric types were incorrectly saved as Bools
    /// and to provide forward-compatible defaults for missing keys.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // maxTokens
        if let val = try? container.decode(Int.self, forKey: .maxTokens) {
            self.maxTokens = val
        } else if let boolVal = try? container.decode(Bool.self, forKey: .maxTokens) {
            self.maxTokens = boolVal ? 4096 : nil
        } else {
            self.maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        }

        // temperature
        if let val = try? container.decode(Double.self, forKey: .temperature) {
            self.temperature = val
        } else if let boolVal = try? container.decode(Bool.self, forKey: .temperature) {
            self.temperature = boolVal ? 1.0 : 0.0
        } else {
            self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        }

        // topP
        if let val = try? container.decode(Double.self, forKey: .topP) {
            self.topP = val
        } else if let boolVal = try? container.decode(Bool.self, forKey: .topP) {
            self.topP = boolVal ? 1.0 : 0.0
        } else {
            self.topP = try container.decodeIfPresent(Double.self, forKey: .topP)
        }

        // stopSequences
        self.stopSequences = try container.decodeIfPresent([String].self, forKey: .stopSequences)

        // reasoningEffort
        self.reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)

        // denyDataCollection — absent in every config saved before 2026-09-27 → nil (off).
        self.denyDataCollection = try container.decodeIfPresent(Bool.self, forKey: .denyDataCollection)
    }
}

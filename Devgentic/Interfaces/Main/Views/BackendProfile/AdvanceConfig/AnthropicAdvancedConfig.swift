// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  AnthropicAdvancedConfig.swift
//  Devgentic
//
//  Created by Raj Singh on 27/03/26.
//

import Foundation

/// A Codable struct that represents the advanced configuration options for the Anthropic Claude API.
/// Includes generation parameters and extended thinking configuration.
struct AnthropicAdvancedConfig: Codable, Hashable {

    // MARK: - Generation Configuration

    /// The maximum number of tokens to generate in the response.
    /// Claude requires this to be explicitly set. Range: 256–128,000.
    var maxTokens: Int

    /// Controls the randomness of the output. Higher values make the output more random.
    /// Note: Must be unset or 1.0 when extended thinking is enabled.
    var temperature: Double?

    /// The cumulative probability of tokens to consider when sampling.
    var topP: Double?

    /// The maximum number of tokens to consider when sampling. Anthropic supports up to 500.
    var topK: Int?

    /// A set of sequences that will stop the generation of output.
    var stopSequences: [String]?

    // MARK: - Extended Thinking

    /// When enabled, Claude reasons internally before responding.
    ///
    /// ⚠️ Carried by `anthropic-version: 2023-06-01` like every other request — thinking is NOT
    /// gated behind an API version. A previous comment here claimed it required `2025-04-14`,
    /// which is not a value the API recognises; the provider acted on that claim and rejected
    /// every request from a thinking-enabled profile. See `AnthropicModelGeneration` for what
    /// actually varies by model.
    var extendedThinking: Bool

    /// The maximum number of tokens Claude can use for internal thinking.
    ///
    /// ⚠️ LEGACY MODELS ONLY (Opus 4.5 and older, Sonnet 4.5/4.0, Haiku 4.5). `budget_tokens` was
    /// removed on Opus 4.7+ / Sonnet 5 / Fable 5 and returns 400 there — those models take
    /// `thinkingEffort` instead. Must be less than `maxTokens` where it does apply.
    var thinkingBudgetTokens: Int?

    /// Thinking depth on adaptive-era models: `low` | `medium` | `high` | `xhigh` | `max`.
    /// Nil means "API default" (`high`). Replaces `thinkingBudgetTokens` on those models.
    /// ⚠️ `xhigh` arrived with Opus 4.7 and is rejected by Opus 4.6 / Sonnet 4.6.
    var thinkingEffort: String?

    /// Creates a default configuration for Anthropic Claude.
    static func `default`() -> AnthropicAdvancedConfig {
        AnthropicAdvancedConfig(
            maxTokens: 4096,
            temperature: 1.0,
            topP: nil,
            topK: nil,
            stopSequences: nil,
            extendedThinking: false,
            thinkingBudgetTokens: 10000,
            thinkingEffort: nil
        )
    }

    // MARK: - Codable Implementation

    private enum CodingKeys: String, CodingKey {
        case maxTokens, temperature, topP, topK, stopSequences
        case extendedThinking, thinkingBudgetTokens, thinkingEffort
    }

    // Memberwise initializer required due to custom decoder.
    init(maxTokens: Int, temperature: Double?, topP: Double?, topK: Int?,
         stopSequences: [String]?, extendedThinking: Bool, thinkingBudgetTokens: Int?,
         thinkingEffort: String? = nil) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.stopSequences = stopSequences
        self.extendedThinking = extendedThinking
        self.thinkingBudgetTokens = thinkingBudgetTokens
        self.thinkingEffort = thinkingEffort
    }

    /// Custom decoder to handle cases where numeric types were incorrectly saved as Bools
    /// and to provide forward-compatible defaults for missing keys.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // maxTokens (non-optional, default 4096)
        if let val = try? container.decode(Int.self, forKey: .maxTokens) {
            self.maxTokens = val
        } else if let boolVal = try? container.decode(Bool.self, forKey: .maxTokens) {
            self.maxTokens = boolVal ? 4096 : 256
        } else {
            self.maxTokens = 4096
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

        // topK
        if let val = try? container.decode(Int.self, forKey: .topK) {
            self.topK = val
        } else if let boolVal = try? container.decode(Bool.self, forKey: .topK) {
            self.topK = boolVal ? 1 : 0
        } else {
            self.topK = try container.decodeIfPresent(Int.self, forKey: .topK)
        }

        // stopSequences
        self.stopSequences = try container.decodeIfPresent([String].self, forKey: .stopSequences)

        // extendedThinking (default false)
        self.extendedThinking = (try? container.decode(Bool.self, forKey: .extendedThinking)) ?? false

        // thinkingBudgetTokens
        if let val = try? container.decode(Int.self, forKey: .thinkingBudgetTokens) {
            self.thinkingBudgetTokens = val
        } else if let boolVal = try? container.decode(Bool.self, forKey: .thinkingBudgetTokens) {
            self.thinkingBudgetTokens = boolVal ? 10000 : 1024
        } else {
            self.thinkingBudgetTokens = try container.decodeIfPresent(Int.self, forKey: .thinkingBudgetTokens)
        }

        // thinkingEffort — absent on every profile written before the adaptive-thinking fix,
        // so decoding must tolerate the missing key rather than fail the whole blob.
        self.thinkingEffort = try container.decodeIfPresent(String.self, forKey: .thinkingEffort)
    }
}

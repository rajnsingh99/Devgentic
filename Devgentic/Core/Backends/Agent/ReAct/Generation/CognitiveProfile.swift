//
//  CognitiveProfile.swift
//  Devgentic
//
//  Step 1.1 — Shared domain types for dialect-based routing.
//  Defines the output format a model produces and the combined profile
//  used to select the correct generator + parser pair.
//
//  Created by Raj Singh on 06/03/26.
//

import Foundation

// MARK: - Model Tier

/// Classification of models based on parameter size and hardware requirements.
/// Used to drive different memory eviction and reasoning strategies.
enum ModelTier: String, Codable, CaseIterable, Identifiable, Hashable {
    case tiny = "Tiny"         // < 4B (e.g. Phi-3, Qwen-1.5B)
    case small = "Small"       // 7B - 14B (e.g. Llama-8B, Mistral)
    case medium = "Medium"     // 30B - 40B
    case large = "Large"       // 70B - 80B
    case ultra = "Ultra"       // > 100B (e.g. Llama-405B, GPT-4)
    
    var id: String { rawValue }

    /// Returns true if the model belongs to a high-capacity tier (70B+ / GPT-4 level).
    var isFrontier: Bool {
        return self == .large || self == .ultra
    }
}


/// Rich metadata describing the physical and logical constraints of an LLM.
struct ModelMetadata: Codable, Hashable {
    var tier: ModelTier
    var contextWindow: Int?     // Captured from num_ctx or model config
    var quantization: String?   // e.g. "Q4_K_M"
    var family: String?         // e.g. "llama3", "mistral", "phi"
    var parameterCount: String? // e.g. "7.2B", "70B"
    
    init(tier: ModelTier, contextWindow: Int? = nil, quantization: String? = nil, family: String? = nil, parameterCount: String? = nil) {
        self.tier = tier
        self.contextWindow = contextWindow
        self.quantization = quantization
        self.family = family
        self.parameterCount = parameterCount
    }
}

// MARK: - Model Dialect

/// Describes the exact response format a local LLM produces for tool calls.
/// This drives both the prompt generator and the response parser selection.
enum ModelDialect: String, Codable, CaseIterable, Identifiable, Hashable {

    /// Standard JSON arrays natively output by models (OpenAI-compatible).
    /// Used with NativeStructuredStrategy / NativeJSONParser.
    case nativeJSON = "Native JSON"

    /// Pseudo-XML wrapping used by some Mistral variants.
    /// e.g. <tool_call>{"name": "ls", "arguments": {}}</tool_call>
    case mistralXML = "Mistral XML"

    /// Classic ReAct markdown format (Thought / Action / Action Input).
    /// e.g. Action: ls\nAction Input: {"path": "/"}
    case reactMarkdown = "ReAct Markdown"

    /// Single flat JSON object ({"tool_name": "ls", "arguments": {}}).
    /// Used with PromptedJsonModeStrategy / PromptedFlatJSONParser.
    case promptedFlatJSON = "Prompted Flat JSON"

    var id: String { rawValue }
}

// MARK: - Cognitive Profile

/// A complete runtime profile that pairs the model's structural capability tier
/// with the specific output dialect it produces.
/// This is the single source of truth for selecting a generator + parser at runtime.
struct CognitiveProfile: Codable, Hashable {

    /// The structural capability tier (parallel, single, none).
    let capability: ModelCognitiveCapability

    /// The exact output format/dialect this model uses for tool calls.
    let dialect: ModelDialect

    /// Rich metadata describing the model's constraints (tier, context, etc).
    var metadata: ModelMetadata?

    init(capability: ModelCognitiveCapability, dialect: ModelDialect = .nativeJSON, metadata: ModelMetadata? = nil) {
        self.capability = capability
        self.dialect = dialect
        self.metadata = metadata
    }

    // MARK: - Convenience Presets

    /// Cloud/modern providers: native OpenAI-compatible JSON arrays.
    static let cloudNative = CognitiveProfile(capability: .parallelActions, dialect: .nativeJSON)

    /// Fallback for constrained models: prompted flat JSON.
    static let localPrompted = CognitiveProfile(capability: .singleAction, dialect: .promptedFlatJSON)

    /// No tool capability.
    static let noCapability = CognitiveProfile(capability: .none, dialect: .promptedFlatJSON)
}

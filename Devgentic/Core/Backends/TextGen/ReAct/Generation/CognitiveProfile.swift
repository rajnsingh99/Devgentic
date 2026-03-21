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
    
    /// Heuristic JSON parsing for both flat and parallel tool calls.
    /// Used with MLXNativeStructuredGenerator / JsonStructuredGenerator.
    case heuristicJson = "Heuristic JSON"

    var id: String { rawValue }
}

// MARK: - Chat Template Family

/// Identifies the chat template format a model was trained on.
/// Used as a Layer 2 fallback when the tokenizer lacks a built-in `chat_template`
/// and no raw Jinja string was extractable from `tokenizer_config.json`.
///
/// Detection is based on special tokens present in the model's tokenizer files
/// (`added_tokens.json`, `special_tokens_map.json`, `tokenizer_config.json`).
enum ChatTemplateFamily: String, Codable, CaseIterable, Hashable {
    /// OpenAI ChatML format — used by Qwen, Hermes, DeepSeek, Yi, and many fine-tunes.
    /// Markers: `<|im_start|>`, `<|im_end|>`
    case chatML = "ChatML"

    /// Meta Llama 3.x format — used by Llama 3, 3.1, 3.2, 3.3.
    /// Markers: `<|start_header_id|>`, `<|end_header_id|>`, `<|eot_id|>`
    case llama3 = "Llama 3"

    /// Mistral Tekken (v3/v7) format — used by Mistral, Devstral, Pixtral, Ministral.
    /// Markers: `[INST]`, `[/INST]`, `[AVAILABLE_TOOLS]`, `[TOOL_CALLS]`
    case mistralTekken = "Mistral Tekken"

    /// Google Gemma format — used by Gemma, Gemma 2, CodeGemma.
    /// Markers: `<start_of_turn>`, `<end_of_turn>`
    case gemma = "Gemma"

    /// Microsoft Phi format — used by Phi-3, Phi-3.5, Phi-4.
    /// Markers: `<|user|>`, `<|assistant|>`, `<|end|>`
    case phi = "Phi"

    /// Cohere Command-R format.
    /// Markers: `<|START_OF_TURN_TOKEN|>`, `<|USER_TOKEN|>`, `<|CHATBOT_TOKEN|>`
    case commandR = "Command-R"

    /// HuggingFace Zephyr format — used by Zephyr, Starling.
    /// Markers: `<|user|>`, `<|assistant|>` with `</s>` as turn delimiter
    case zephyr = "Zephyr"

    /// Legacy instruction-following format (Alpaca/Vicuna style).
    /// No reliable special token markers — detected by model name heuristics.
    case alpaca = "Alpaca"
}

// MARK: - Chat Template Source

/// Describes where the chat template for an MLX model comes from at runtime.
/// Stored in `CognitiveProfile` and used by `MLXService` during the fallback path.
enum ChatTemplateSource: Codable, Hashable, CustomStringConvertible {
    /// The tokenizer has a built-in chat template — no fallback needed (normal path).
    case embedded

    /// The raw Jinja template was extracted from `tokenizer_config.json` during analysis.
    /// This is Layer 1: the model author's own template, most accurate.
    case extracted(String)

    /// The template family was detected from special tokens in the tokenizer files.
    /// This is Layer 2: a hardcoded fallback matched to the model's token vocabulary.
    case familyFallback(ChatTemplateFamily)

    var description: String {
        switch self {
        case .embedded:
            return "embedded"
        case .extracted(let template):
            return "extracted(\(template.count) chars)"
        case .familyFallback(let family):
            return "familyFallback(\(family.rawValue))"
        }
    }
}

// MARK: - Supported Modalities

/// Describes the input/output modalities a model supports.
/// Used by ContextCompressor and provider adapters to filter media blocks
/// for models that cannot handle them.
struct SupportedModalities: OptionSet, Sendable, Codable, Hashable {
    let rawValue: Int

    static let textInput     = SupportedModalities(rawValue: 1 << 0)
    static let textOutput    = SupportedModalities(rawValue: 1 << 1)
    static let visionInput   = SupportedModalities(rawValue: 1 << 2)
    static let imageOutput   = SupportedModalities(rawValue: 1 << 3)  // Future: imageGen
    static let audioInput    = SupportedModalities(rawValue: 1 << 4)  // Future
    static let audioOutput   = SupportedModalities(rawValue: 1 << 5)  // Future

    /// Default for text-only models.
    static let textOnly: SupportedModalities = [.textInput, .textOutput]

    /// Cloud frontier models with vision.
    static let visionCapable: SupportedModalities = [.textInput, .textOutput, .visionInput]
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

    /// The input/output modalities this model supports.
    /// Defaults to `.textOnly` for backward compatibility.
    var modalities: SupportedModalities

    /// Describes how to obtain the correct chat template for this model.
    /// `.embedded` means the tokenizer handles it natively (most models).
    /// `.extracted` or `.familyFallback` are used when the tokenizer lacks a template.
    /// Defaults to `.embedded` for backward compatibility.
    var chatTemplateSource: ChatTemplateSource

    /// Custom stop sequences extracted from the model's tokenizer configuration.
    /// These are special tokens (turn markers, role markers) that the model should
    /// never generate during a normal response. If the model emits one, it has crossed
    /// a turn boundary and generation should stop immediately.
    ///
    /// Extracted by `MLXTokenizerAnalyzer` from `added_tokens.json` and `special_tokens_map.json`.
    /// Empty array means no custom stop sequences — rely on framework EOS detection only.
    var stopSequences: [String]

    init(capability: ModelCognitiveCapability, dialect: ModelDialect = .nativeJSON, metadata: ModelMetadata? = nil, modalities: SupportedModalities = .textOnly, chatTemplateSource: ChatTemplateSource = .embedded, stopSequences: [String] = []) {
        self.capability = capability
        self.dialect = dialect
        self.metadata = metadata
        self.modalities = modalities
        self.chatTemplateSource = chatTemplateSource
        self.stopSequences = stopSequences
    }

    // MARK: - Convenience Presets

    /// Cloud/modern providers: native OpenAI-compatible JSON arrays with vision support.
    /// Cloud tokenizers always have embedded templates.
    static let cloudNative = CognitiveProfile(capability: .parallelActions, dialect: .nativeJSON, modalities: .visionCapable, chatTemplateSource: .embedded)

    /// Fallback for constrained models: prompted flat JSON, text-only.
    static let localPrompted = CognitiveProfile(capability: .singleAction, dialect: .heuristicJson, chatTemplateSource: .embedded)

    /// No tool capability.
    static let noCapability = CognitiveProfile(capability: .none, dialect: .heuristicJson, chatTemplateSource: .embedded)
}

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

    /// Qwen/Hermes native format: single JSON object per `<tool_call>` wrapper,
    /// with `name` key first, then `arguments`. Multiple blocks = parallel calls.
    /// Covers Qwen2.5/3 Instruct, Hermes-2-Pro, Hermes-3, and structurally identical
    /// fine-tunes. Detected via `ChatTemplateFingerprinter` on the Jinja template.
    /// Emits `<tool_call>\n{"name": "...", "arguments": {...}}\n</tool_call>`.
    case qwenHermesToolCall = "Qwen/Hermes Tool Call"

    /// Llama-3.1 / 3.2 / 3.3 native JSON format.
    /// Covers `meta-llama/Llama-3.1-*-Instruct`, `Llama-3.2-*-Instruct`, `Llama-3.3-*-Instruct`.
    /// Emits `{"name": "...", "parameters": {...}}` — uses `parameters` key (NOT `arguments`).
    /// Template ENFORCES single-call-only (raises exception for multi-call).
    /// Optional `<|python_tag|>` prefix, terminates with `<|eot_id|>` or `<|eom_id|>`.
    case llama3JsonSingle = "Llama 3 JSON (Single Call)"

    /// Mistral family, tokenizer v3 (Tekken): JSON array of tool calls wrapped in marker.
    /// Covers Mistral-7B-Instruct-v0.3, Mistral-Nemo, Mixtral-8x22B, Mistral-Small-2409,
    /// Ministral-8B, Pixtral-Large, older Devstral. Older format (pre-2025-03).
    /// Emits `[TOOL_CALLS] [{"name": "...", "arguments": {...}, "id": "xxxxxxxxx"}]</s>`.
    case mistralV3Array = "Mistral v3 (Array)"

    /// Mistral family, tokenizer v11 (2025+): flat marker+name+ARGS syntax.
    /// Covers Mistral-Small-3.1-24B+, Devstral-Small-2505/2507+, Mistral-Medium-2025+.
    /// Parallel calls = multiple `[TOOL_CALLS]...[ARGS]...` blocks concatenated.
    /// Emits `[TOOL_CALLS]list_directory[ARGS]{"path":"/"}`.
    case mistralV11Flat = "Mistral v11 (Flat)"

    /// Phi-4-mini Instruct + Fireworks Firefunction-v2.
    /// Emits `functools[{"name":"X","arguments":{...}}, ...]` — JSON array after
    /// literal `functools[` marker. Structurally similar to Mistral v3 array shape
    /// but with a different marker.
    case phiFunctoolsBracket = "Phi functools[]"

    /// DeepSeek-V3 / DeepSeek-R1 native format. Uses full-width Unicode pipes `｜`
    /// (U+FF5C) and `▁` (U+2581) in token markers. Emits tool name via `<|tool▁sep|>`
    /// then JSON args in a `\`\`\`json ... \`\`\`` code fence, wrapped in
    /// `<|tool▁calls▁begin|>...<|tool▁call▁end|><|tool▁calls▁end|>`.
    case deepseekV3JsonFence = "DeepSeek V3 (JSON Fence)"

    /// Pythonic function-call list format. Used by small Llama 3.2 variants
    /// (1B / 3B Instruct), Salesforce xLAM-2, Team-ACE ToolACE-8B, Llama 4 pythonic.
    /// Emits `[func_name(arg1="val1", arg2=42), func2(...)]` — Python expression
    /// syntax (NOT JSON). Parsing requires kwarg extraction + Python-literal handling.
    case pythonicBracketList = "Pythonic Bracket List"

    /// IBM Granite 3.0 / 3.1 / 3.2 / 3.3 — JSON array wrapped in tool-call marker.
    /// 3.0 uses `<|tool_call|>` with ASCII pipes; 3.1+ uses `<tool_call>` without.
    /// Both emit the same body shape: `[{"name":"...","arguments":{...}}, ...]`.
    /// One parser handles both markers.
    case graniteLegacyArray = "Granite 3.x (Array)"

    /// IBM Granite 4.0 — single-object `<tool_call>{"name":..., "arguments":...}</tool_call>`
    /// identical in shape to Qwen/Hermes native. Parser is routed to QwenHermesJsonParser.
    /// Distinguished from Qwen at the fingerprint layer (Granite-specific role markers).
    case granite4ToolCall = "Granite 4.x"

    /// Cohere Command-R / Command-R+ — Action-prefixed markdown directive with
    /// fenced JSON list using `tool_name` + `parameters` keys (unique to Cohere).
    /// Emits `Action: \`\`\`json\n[{"tool_name":"...","parameters":{...}}]\n\`\`\``.
    case commandRAction = "Command-R Action"

    /// Cohere Command-R7B (Dec 2024+) and likely Command-A — token-delimited
    /// `<|START_ACTION|>[...]<|END_ACTION|>` with `tool_call_id`/`tool_name`/`parameters`.
    /// Explicit `tool_call_id` field is distinctive vs older Command-R.
    case commandR7BAction = "Command-R7B Action"

    /// Qwen3-Coder (30B-A3B, 480B-A35B, etc.) — deep XML format:
    /// `<tool_call><function=NAME><parameter=KEY>value</parameter>...</function></tool_call>`.
    /// Fundamentally different from Qwen2.5/3 base (which uses JSON in wrapper).
    /// Parameter values type-coerced from schema (string/int/float/bool/JSON).
    case qwen3CoderDeepXml = "Qwen3-Coder Deep XML"

    /// DeepSeek V3.1 — flat variant: name followed by JSON args, NO code fence.
    /// Emits `<｜tool▁calls▁begin｜><｜tool▁call▁begin｜>name<｜tool▁sep｜>{args}<｜tool▁call▁end|><｜tool▁calls▁end|>`.
    /// Same full-width Unicode token markers as V3 but dropped the code fence rendering.
    case deepseekV31Flat = "DeepSeek V3.1 (Flat)"

    /// DeepSeek V3.2 — brand new `<｜DSML｜...>` XML namespace replacing the old
    /// begin/end/sep sentinels. Emits `<｜DSML｜function_calls><｜DSML｜invoke name="X">
    /// <｜DSML｜parameter name="Y" string="true">value</｜DSML｜parameter></｜DSML｜invoke>
    /// </｜DSML｜function_calls>`. Per-parameter typing via `string="true"` attribute.
    case deepseekV32Dsml = "DeepSeek V3.2 (DSML)"

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

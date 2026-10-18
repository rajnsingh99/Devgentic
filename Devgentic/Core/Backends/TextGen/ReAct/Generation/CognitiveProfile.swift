// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CognitiveProfile.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    /// Qwen/Hermes native format: one JSON object per `<tool_call>` wrapper, `name` first, then `arguments`.
    /// Multiple blocks are parallel calls; covers Qwen2.5/3 Instruct, Hermes-2-Pro, Hermes-3 and identical fine-tunes.
    /// Detected via `ChatTemplateFingerprinter`; emits `<tool_call>\n{"name": ..., "arguments": {...}}\n</tool_call>`.
    case qwenHermesToolCall = "Qwen/Hermes Tool Call"

    /// Llama-3.1/3.2/3.3 native JSON: `{"name": "...", "parameters": {...}}` (the key is `parameters`, not `arguments`).
    /// Single call only; optional `<|python_tag|>` prefix, terminated by `<|eot_id|>` or `<|eom_id|>`.
    case llama3JsonSingle = "Llama 3 JSON (Single Call)"

    /// Mistral tokenizer v3 (Tekken): a JSON array of tool calls after a `[TOOL_CALLS]` marker.
    /// Covers Mistral-7B-Instruct-v0.3, Mistral-Nemo, Mixtral-8x22B, Mistral-Small-2409, Ministral-8B, Pixtral-Large.
    /// Emits `[TOOL_CALLS] [{"name": ..., "arguments": {...}, "id": ...}]</s>`.
    case mistralV3Array = "Mistral v3 (Array)"

    /// Mistral tokenizer v11: flat marker+name+args syntax, `[TOOL_CALLS]list_directory[ARGS]{"path":"/"}`.
    /// Covers Mistral-Small-3.1-24B+, Devstral-Small-2505/2507+, Mistral-Medium-2025+.
    /// Parallel calls are multiple `[TOOL_CALLS]...[ARGS]...` blocks concatenated.
    case mistralV11Flat = "Mistral v11 (Flat)"

    /// Phi-4-mini Instruct and Fireworks Firefunction-v2: `functools[{"name":"X","arguments":{...}}, ...]`.
    /// A JSON array after a literal `functools[` marker, shaped like Mistral v3 but with a different marker.
    case phiFunctoolsBracket = "Phi functools[]"

    /// DeepSeek-V3 / R1 native format, using full-width pipes `｜` (U+FF5C) and `▁` (U+2581) in token markers.
    /// The tool name follows `<|tool▁sep|>`, then JSON args in a json code fence, inside `<|tool▁calls▁begin|>…`.
    case deepseekV3JsonFence = "DeepSeek V3 (JSON Fence)"

    /// Pythonic function-call list: `[func_name(arg1="val1", arg2=42), func2(...)]`, Python syntax rather than JSON.
    /// Used by small Llama 3.2 variants (1B/3B), Salesforce xLAM-2, Team-ACE ToolACE-8B and Llama 4 pythonic.
    /// Parsing needs kwarg extraction and Python-literal handling.
    case pythonicBracketList = "Pythonic Bracket List"

    /// IBM Granite 3.0-3.3: a JSON array `[{"name":"...","arguments":{...}}, ...]` wrapped in a tool-call marker.
    /// 3.0 uses `<|tool_call|>` with ASCII pipes and 3.1+ uses `<tool_call>`; one parser handles both.
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

    /// Qwen3-Coder (30B-A3B, 480B-A35B, ...): deep XML, not the JSON-in-wrapper form of Qwen2.5/3 base.
    /// `<tool_call><function=NAME><parameter=KEY>value</parameter>...</function></tool_call>`
    /// Parameter values are type-coerced from the schema (string/int/float/bool/JSON).
    case qwen3CoderDeepXml = "Qwen3-Coder Deep XML"

    /// DeepSeek V3.1 — flat variant: name followed by JSON args, NO code fence.
    /// Emits `<｜tool▁calls▁begin｜><｜tool▁call▁begin｜>name<｜tool▁sep｜>{args}<｜tool▁call▁end|><｜tool▁calls▁end|>`.
    /// Same full-width Unicode token markers as V3 but dropped the code fence rendering.
    case deepseekV31Flat = "DeepSeek V3.1 (Flat)"

    /// DeepSeek V3.2: a `<｜DSML｜...>` XML namespace; `<｜DSML｜function_calls>` wraps `<｜DSML｜invoke name="X">` blocks.
    /// Parameters are `<｜DSML｜parameter name="Y" string="true">value</｜DSML｜parameter>`, typed via `string=`.
    case deepseekV32Dsml = "DeepSeek V3.2 (DSML)"

    var id: String { rawValue }
}

// MARK: - Corrective Format Reminder

extension ModelDialect {

    // Why: exhaustive switch, no `default:`, so a new dialect breaks the build instead of inheriting another family's shape.
    /// One sentence naming this dialect's tool-call wire shape, for a corrective alert injected after a parse failure.
    /// Shape statements, not instructions; keep in step with `NativeToolTemplateGenerator`'s per-dialect `triggerSuffix`.
    var formatReminder: String {
        switch self {
        case .nativeJSON, .heuristicJson:
            return #"a single JSON object: {"reasoning": "...", "toolCalls": [{"name": "...", "arguments": {...}}]} — no prose, no markdown fences"#
        case .mistralXML:
            return #"<tool_call>{"name": "...", "arguments": {...}}</tool_call>"#
        case .reactMarkdown:
            return #"Thought: ... then Action: <tool_name> and Action Input: {"key": "value"} on their own lines"#
        case .qwenHermesToolCall, .granite4ToolCall:
            return #"one or more <tool_call>{"name": "...", "arguments": {...}}</tool_call> blocks, "name" before "arguments""#
        case .llama3JsonSingle:
            return #"a SINGLE JSON object {"name": "...", "parameters": {...}} — the key is "parameters", not "arguments", and only one call per response"#
        case .mistralV3Array:
            return #"[TOOL_CALLS] followed by a JSON array: [{"name": "...", "arguments": {...}}]"#
        case .mistralV11Flat:
            return #"[TOOL_CALLS]<tool_name>[ARGS]{"key": "value"} — the name sits between the two markers, not inside JSON"#
        case .phiFunctoolsBracket:
            return #"functools[{"name": "...", "arguments": {...}}]"#
        case .deepseekV3JsonFence:
            return "<｜tool▁call▁begin｜>function<｜tool▁sep｜>tool_name then the arguments in a ```json fence, closed by <｜tool▁call▁end｜>"
        case .deepseekV31Flat:
            return #"<｜tool▁call▁begin｜>tool_name<｜tool▁sep｜>{"key": "value"}<｜tool▁call▁end｜> — bare JSON, no code fence"#
        case .deepseekV32Dsml:
            return #"<｜DSML｜function_calls><｜DSML｜invoke name="tool_name"><｜DSML｜parameter name="key" string="true">value</｜DSML｜parameter></｜DSML｜invoke></｜DSML｜function_calls>"#
        case .pythonicBracketList:
            return #"a Python list of calls: [tool_name(key="value", count=42)] — Python literal syntax (True/False/None), not JSON"#
        case .graniteLegacyArray:
            return #"<tool_call>[{"name": "...", "arguments": {...}}]</tool_call> — a JSON ARRAY inside the wrapper"#
        case .commandRAction:
            return #"Action: ```json followed by [{"tool_name": "...", "parameters": {...}}] — the keys are "tool_name" and "parameters""#
        case .commandR7BAction:
            return #"<|START_ACTION|>[{"tool_call_id": "0", "tool_name": "...", "parameters": {...}}]<|END_ACTION|>"#
        case .qwen3CoderDeepXml:
            return "<tool_call><function=tool_name><parameter=key>value</parameter></function></tool_call>"
        }
    }

    // Why: an exhaustive switch rather than a substring test on `formatReminder`, so a new dialect must answer explicitly.
    /// Whether this dialect carries its tool arguments as a JSON payload.
    /// Gates JSON-syntax advice in the malformed-JSON corrective alert; false for pythonic and XML-parameter dialects.
    /// The wrapper syntax is irrelevant: `.mistralV11Flat` has a bare name between markers but a JSON `[ARGS]` payload.
    var argumentsAreJSON: Bool {
        switch self {
        case .nativeJSON, .heuristicJson, .mistralXML, .reactMarkdown, .qwenHermesToolCall,
             .llama3JsonSingle, .mistralV3Array, .mistralV11Flat, .phiFunctoolsBracket,
             .deepseekV3JsonFence, .deepseekV31Flat, .graniteLegacyArray, .granite4ToolCall,
             .commandRAction, .commandR7BAction:
            return true
        case .pythonicBracketList, .qwen3CoderDeepXml, .deepseekV32Dsml:
            return false
        }
    }
}

// MARK: - Chat Template Family

/// Identifies the chat template format a model was trained on, detected from special tokens in the tokenizer files.
/// Used as a fallback when the tokenizer has no built-in `chat_template` and no raw Jinja string was extractable.
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
/// Used by provider adapters to filter media blocks
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

// MARK: - Tool Support Caveat

/// Qualifies a model's tool capability for the UI: blocked models render disabled with a reason, quality-suspect ones
/// selectable with a warning; `nil` means clean. Detection-side only: never persisted by `ProviderConfig`.
enum ToolSupportCaveat: String, Codable, Hashable, Sendable {
    /// The daemon's capabilities array lacks "tools": any tools request WILL be
    /// rejected with HTTP 400. A hard protocol block, not a guess.
    case serverRejectsTools
    /// Reasoning-focused fine-tune (deepseek-r1, qwq, gpt-oss...). When the daemon declares tools it stays selectable;
    /// the caveat flags tool-call reliability. Without a capabilities field the pattern blocks (cannot verify).
    case reasoningFocused
    /// No authoritative capabilities data and no heuristic signal — tool support
    /// can't be verified (legacy daemon without the capabilities field).
    case undetected
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

    /// Why `capability` needs qualification in pickers (blocked reason / reliability
    /// warning). Optional so old persisted profiles decode unchanged and nil encodes
    /// as absent.
    var toolSupportCaveat: ToolSupportCaveat?

    /// Rich metadata describing the model's constraints (tier, context, etc).
    var metadata: ModelMetadata?

    /// The input/output modalities this model supports.
    /// Defaults to `.textOnly` for backward compatibility.
    var modalities: SupportedModalities

    /// Describes how to obtain the correct chat template: `.embedded` means the tokenizer handles it natively (most models);
    /// `.extracted` or `.familyFallback` apply when the tokenizer lacks a template. Defaults to `.embedded`.
    var chatTemplateSource: ChatTemplateSource

    /// Custom stop sequences (turn and role markers) extracted by `MLXTokenizerAnalyzer` from the tokenizer configuration.
    /// Emitting one means the model crossed a turn boundary and generation stops; empty means rely on framework EOS only.
    var stopSequences: [String]

    init(capability: ModelCognitiveCapability, dialect: ModelDialect = .nativeJSON, metadata: ModelMetadata? = nil, modalities: SupportedModalities = .textOnly, chatTemplateSource: ChatTemplateSource = .embedded, stopSequences: [String] = [], toolSupportCaveat: ToolSupportCaveat? = nil) {
        self.capability = capability
        self.dialect = dialect
        self.metadata = metadata
        self.modalities = modalities
        self.chatTemplateSource = chatTemplateSource
        self.stopSequences = stopSequences
        self.toolSupportCaveat = toolSupportCaveat
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

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NativeToolTemplateGenerator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logLLMOps = DGLogger(category: "LLMOps")

/// A single generator for all chat-template-native MLX dialects. Dialect-specific behavior lives in the matching
/// parser (via `ParserFactory`), the `triggerSuffix` format hint, and the model's own Jinja chat template.
struct NativeToolTemplateGenerator: CognitiveGenerator {

    // Why: stored non-optional and exposed through the optional `expectedDialect` witness; a stored property of that name
    // would not satisfy `ModelDialect?` and the protocol default `nil` would win silently.
    /// The dialect this generator asks for and parses back; it routes the raw output to the matching parser and feeds
    /// drift detection and confidence classification.
    let dialect: ModelDialect

    var expectedDialect: ModelDialect? { dialect }

    /// The dialect's call format, completing "To call a tool, respond with …" in the prompt
    /// trigger each iteration. Kept brief and attention-proximate; the chat template provides
    /// the authoritative format spec via the `<tools>` scaffolding.
    let triggerSuffix: String

    /// Short identifier for log lines — keeps grepping straightforward across dialects.
    let logTag: String

    // MARK: - CognitiveGenerator protocol

    /// Unused when `isNativeFlow: true` (tools are injected by the chat template, not
    /// formatted into the system prompt). Kept on the protocol contract.
    let toolAdapter: ToolSchemaAdapter = PromptedMarkdownAdapter()

    /// No custom dialect rules injected into the system prompt. The chat template
    /// owns format instructions; any drift reinforcement goes through `triggerSuffix`.
    let dialectRules: String? = nil

    /// Markdown wrapping prevents conflicts between XML prompt sections and the
    /// XML-wrapped JSON that some dialects (Qwen/Hermes, Mistral XML) emit.
    var promptWrapping: PromptWrapping { .markdown }

    // MARK: - Private

    /// Produces OpenAI-style `[{type:"function", function:{name,description,parameters}}]`
    /// schemas consumed by `applyChatTemplate(tools:)`. Triggers the template's
    /// `{% if tools %}` branch, which renders the dialect's native scaffolding.
    private let nativeSchemaAdapter: ToolSchemaAdapter = NativeJSONSchemaAdapter()

    // MARK: - Init

    init(expectedDialect: ModelDialect, triggerSuffix: String, logTag: String) {
        self.dialect = expectedDialect
        self.triggerSuffix = triggerSuffix
        self.logTag = logTag
    }

    // MARK: - Message compilation

    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        // `isNativeFlow: true` → skips `available_tools` + `execution_contract` prompt
        // injection. The model's chat template owns tool scaffolding entirely.
        return buildStandardMessages(
            context: context,
            dialectRules: dialectRules,
            isNativeFlow: true,
            layerConfig: context.promptLayerConfig,
            wrapping: .markdown
        )
    }

    func promptTrigger(for iteration: Int) -> String {
        let base = IterationTrigger.base(for: iteration)
        // The format hint is conditional, and plain text is named as the way to answer, so small models answer instead of
        // exploring when tools are not needed.
        return base + " To call a tool, respond with " + triggerSuffix
            + " To answer the user instead, reply in plain text with no tool call."
    }

    // MARK: - Generation

    func generateCognitiveStep(
        model: any LLMProvider,
        context: SemanticContext,
        iteration: Int
    ) async throws -> ModernCognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logLLMOps.info("⚡️ [\(self.logTag):\(reqId)] Start Generation - Iteration: \(iteration) - Dialect: \(self.dialect.rawValue)")

        var executionMessages = compileMessages(from: context)
        executionMessages.append(["role": "user", "content": promptTrigger(for: iteration)])

        // Vision degrades here: native tool schemas need `streamChat`, while the vision path has no tools parameter. For an
        // agent tools win; the drop is logged with its consequence.
        let hasImages = (context.userImagePayload?.contains { if case .image = $0 { return true }; return false } ?? false)
            || (context.nativeHistoryTurns?.totalImageCount ?? 0) > 0
        if hasImages {
            logLLMOps.warning("[VISION] [\(self.logTag):\(reqId)] image(s) present but this model uses NATIVE tool-call templates, which the MLX vision path cannot combine with tool injection — answering from text + tools only; the model will NOT see the image(s)")
        }

        // Build OpenAI-style tool schemas for the chat template's `{% if tools %}` branch.
        let nativeTools = nativeSchemaAdapter.formatForNativeAPI(context.availableTools)
        logLLMOps.info("🔧 [\(self.logTag):\(reqId)] Passing \(nativeTools?.count ?? 0) native tool schema(s) to chat template")

        logLLMOps.debug("📤 [\(self.logTag):\(reqId)] Sending request...")
        let startTime = Date()

        let responseText = try await model.generate(
            messages: executionMessages,
            tools: nativeTools,
            responseSchema: nil
        )

        let duration = Date().timeIntervalSince(startTime)
        logLLMOps.info("✅ [\(self.logTag):\(reqId)] Response received in \(String(format: "%.4f", duration))s")
        logLLMOps.debug("📄 [\(self.logTag):\(reqId)] Raw:\n\(responseText)")

        guard !responseText.isEmpty else {
            logLLMOps.error("❌ [\(self.logTag):\(reqId)] Empty response from model.")
            throw GenerationError.emptyResponse(generator: self.logTag)
        }

        let pipeline = CognitiveParsePipeline(
            expectedDialect: dialect,
            modelId: model.modelName,
            iteration: iteration,
            knownToolNames: Set(context.availableTools.map(\.name)).union(context.runToolNames),
            registeredTools: context.availableTools
        )
        return pipeline.parse(raw: responseText)
    }
}

// MARK: - Dialect Factories
// Each helper builds a preconfigured generator for one dialect and is the single source of truth for that dialect's
// `triggerSuffix`; tune prompt reinforcement here, not in callers.

extension NativeToolTemplateGenerator {

    /// Qwen2.5/3, Hermes-2-Pro, Hermes-3, and structurally identical fine-tunes.
    /// Expects `<tool_call>{"name":...,"arguments":...}</tool_call>` wrapped JSON.
    static func qwenHermes() -> NativeToolTemplateGenerator {
        .init(
            expectedDialect: .qwenHermesToolCall,
            triggerSuffix: "one or more <tool_call> blocks containing JSON with `name` then `arguments`.",
            logTag: "QwenHermes"
        )
    }

    /// Llama-3.1 / 3.2 / 3.3 Instruct family.
    /// Single-call only (template enforced). Uses `"parameters"` key, NOT `"arguments"`.
    static func llama3Json() -> NativeToolTemplateGenerator {
        .init(
            expectedDialect: .llama3JsonSingle,
            triggerSuffix: "a SINGLE JSON object: {\"name\": <tool>, \"parameters\": {...}}. Only one tool call per response.",
            logTag: "Llama3"
        )
    }

    /// Mistral 7B v0.3, Nemo, Mixtral, Ministral, Pixtral, Mistral Small-2409 (pre-v11).
    /// Parallel calls rendered as JSON array inside `[TOOL_CALLS] [...]</s>`.
    static func mistralV3() -> NativeToolTemplateGenerator {
        .init(
            expectedDialect: .mistralV3Array,
            triggerSuffix: "[TOOL_CALLS] followed by a JSON array of tool call objects.",
            logTag: "MistralV3"
        )
    }

    /// Mistral Small-3.1+, Devstral-2505+, Mistral Medium 2025+ (v11 tokenizer).
    /// Flat syntax: `[TOOL_CALLS]name[ARGS]{args}` per tool call, concatenated for parallel.
    static func mistralV11() -> NativeToolTemplateGenerator {
        .init(
            expectedDialect: .mistralV11Flat,
            triggerSuffix: "[TOOL_CALLS]<tool_name>[ARGS]<json_arguments> for each tool call.",
            logTag: "MistralV11"
        )
    }

    /// Phi-4-mini Instruct + Firefunction-v2.
    /// Emits `functools[{"name":..., "arguments":...}]` — JSON array after literal marker.
    static func phiFunctools() -> NativeToolTemplateGenerator {
        .init(
            expectedDialect: .phiFunctoolsBracket,
            triggerSuffix: "functools[{\"name\":\"<tool>\",\"arguments\":{...}}] containing one or more tool calls.",
            logTag: "PhiFunctools"
        )
    }

    /// DeepSeek-V3 / DeepSeek-R1 native format — full-width Unicode token markers
    /// wrapping a code-fenced JSON argument payload.
    static func deepseekV3() -> NativeToolTemplateGenerator {
        .init(
            expectedDialect: .deepseekV3JsonFence,
            triggerSuffix: "DeepSeek's native <｜tool▁call▁begin｜>function<｜tool▁sep｜>name ```json {...} ``` <｜tool▁call▁end｜> format.",
            logTag: "DeepSeekV3"
        )
    }

    /// Pythonic bracket-list format — Llama-3.2 1B/3B small models, xLAM-2, ToolACE.
    /// Output is Python expression syntax (NOT JSON): `[func_name(arg="val"), ...]`.
    static func pythonic() -> NativeToolTemplateGenerator {
        .init(
            expectedDialect: .pythonicBracketList,
            triggerSuffix: "a Python list of function calls: [func_name(arg1=\"val\", arg2=42), ...]. Use Python literal syntax (True/False/None, not true/false/null).",
            logTag: "Pythonic"
        )
    }

    /// IBM Granite 3.0 / 3.1 / 3.2 / 3.3 — JSON array wrapped in tool-call marker.
    static func graniteLegacy() -> NativeToolTemplateGenerator {
        .init(
            expectedDialect: .graniteLegacyArray,
            triggerSuffix: "<tool_call>[{\"name\":\"...\",\"arguments\":{...}}]</tool_call> containing a JSON array of tool calls.",
            logTag: "GraniteLegacy"
        )
    }

    /// IBM Granite 4.x — single-object per wrapper (Qwen-style).
    /// Parser routes to QwenHermesJsonParser since the output shape is identical.
    static func granite4() -> NativeToolTemplateGenerator {
        .init(
            expectedDialect: .granite4ToolCall,
            triggerSuffix: "one or more <tool_call>{\"name\":\"...\",\"arguments\":{...}}</tool_call> blocks.",
            logTag: "Granite4"
        )
    }

    /// Cohere Command-R / R+ — `Action:` markdown directive with fenced JSON list.
    static func commandR() -> NativeToolTemplateGenerator {
        .init(
            expectedDialect: .commandRAction,
            triggerSuffix: "Action: ```json\\n[{\"tool_name\":\"...\",\"parameters\":{...}}]\\n``` containing the tool call list.",
            logTag: "CommandR"
        )
    }

    /// Cohere Command-R7B / Command-A — `<|START_ACTION|>[...]<|END_ACTION|>` token-delimited.
    static func commandR7B() -> NativeToolTemplateGenerator {
        .init(
            expectedDialect: .commandR7BAction,
            triggerSuffix: "<|START_ACTION|>[{\"tool_call_id\":\"0\",\"tool_name\":\"...\",\"parameters\":{...}}]<|END_ACTION|>.",
            logTag: "CommandR7B"
        )
    }

    /// Qwen3-Coder — deep XML with `<function=NAME><parameter=KEY>value</parameter></function>`.
    static func qwen3Coder() -> NativeToolTemplateGenerator {
        .init(
            expectedDialect: .qwen3CoderDeepXml,
            triggerSuffix: "<tool_call><function=<tool_name>><parameter=<key>>value</parameter></function></tool_call>.",
            logTag: "Qwen3Coder"
        )
    }

    /// DeepSeek V3.1 — flat variant of V3: no code fence around args.
    static func deepseekV31() -> NativeToolTemplateGenerator {
        .init(
            expectedDialect: .deepseekV31Flat,
            triggerSuffix: "DeepSeek V3.1 native format: <｜tool▁call▁begin｜>name<｜tool▁sep｜>{args}<｜tool▁call▁end｜>.",
            logTag: "DeepSeekV31"
        )
    }

    /// DeepSeek V3.2 — brand new `<｜DSML｜...>` XML format.
    static func deepseekV32() -> NativeToolTemplateGenerator {
        .init(
            expectedDialect: .deepseekV32Dsml,
            triggerSuffix: "DeepSeek V3.2 DSML format: <｜DSML｜function_calls><｜DSML｜invoke name=\"X\"><｜DSML｜parameter name=\"Y\" string=\"true\">value</｜DSML｜parameter></｜DSML｜invoke></｜DSML｜function_calls>.",
            logTag: "DeepSeekV32"
        )
    }
}

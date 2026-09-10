// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MLXTokenizerDialectTests.swift
//  DevgenticTests
//
//  Tests for MLXTokenizerAnalyzer.detectCognitiveProfile() — the dialect and
//  capability detection engine for local MLX models. Creates temporary model
//  directories with tokenizer artifacts to verify detection across all signal
//  tiers: special tokens, Jinja templates, family names, and fallbacks.
//

import XCTest
@testable import devgentic

final class MLXTokenizerDialectTests: XCTestCase {

    /// Temporary model directory recreated for each test.
    private var modelDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        modelDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXDialectTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = modelDir, FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func writeJSON(_ filename: String, _ content: String) throws {
        let url = modelDir.appendingPathComponent(filename)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func detect(modelName: String = "test-model") -> CognitiveProfile {
        MLXTokenizerAnalyzer.detectCognitiveProfile(for: modelDir, modelName: modelName)
    }

    // MARK: - Tier 1: Special Token Markers → parallelActions

    func testSpecialTokens_ToolCall_ParallelActions_MistralXML() throws {
        try writeJSON("special_tokens_map.json", """
        {"additional_special_tokens": ["<tool_call>", "</tool_call>", "<s>", "</s>"]}
        """)
        let profile = detect()
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .mistralXML)
    }

    func testSpecialTokens_TOOL_CALLS_ParallelActions_MistralXML() throws {
        try writeJSON("special_tokens_map.json", """
        {"additional_special_tokens": ["[TOOL_CALLS]", "[INST]", "[/INST]"]}
        """)
        let profile = detect()
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .mistralXML)
    }

    func testSpecialTokens_AVAILABLE_TOOLS_ParallelActions_MistralXML() throws {
        try writeJSON("special_tokens_map.json", """
        {"additional_special_tokens": ["[AVAILABLE_TOOLS]", "[/AVAILABLE_TOOLS]"]}
        """)
        let profile = detect()
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .mistralXML)
    }

    func testSpecialTokens_FunctionCall_ParallelActions_MistralXML() throws {
        // Blind spot fix: <function_call> should be detected as a tool token
        try writeJSON("special_tokens_map.json", """
        {"additional_special_tokens": ["<function_call>", "</function_call>"]}
        """)
        let profile = detect()
        XCTAssertEqual(profile.capability, .parallelActions,
                       "<function_call> in special tokens should trigger parallelActions")
        XCTAssertEqual(profile.dialect, .mistralXML,
                       "<function_call> should map to mistralXML dialect")
    }

    func testSpecialTokens_eom_id_ParallelActions() throws {
        try writeJSON("special_tokens_map.json", """
        {"additional_special_tokens": ["<|eom_id|>", "<|start_header_id|>"]}
        """)
        let profile = detect()
        XCTAssertEqual(profile.capability, .parallelActions)
    }

    // MARK: - Tier 1: Added Tokens Fallback

    func testAddedTokens_ToolCall_ParallelActions_MistralXML() throws {
        try writeJSON("added_tokens.json", """
        [{"content": "<tool_call>", "special": true}, {"content": "</tool_call>", "special": true}]
        """)
        let profile = detect()
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .mistralXML)
    }

    func testAddedTokens_FunctionCall_ParallelActions_MistralXML() throws {
        // Blind spot fix: <function_call> in added_tokens.json
        try writeJSON("added_tokens.json", """
        [{"content": "<function_call>", "special": true}]
        """)
        let profile = detect()
        XCTAssertEqual(profile.capability, .parallelActions,
                       "<function_call> in added_tokens should trigger parallelActions")
        XCTAssertEqual(profile.dialect, .mistralXML)
    }

    // MARK: - Tier 1: Tokenizer Config (Extra Special Tokens / Jinja Template)

    func testTokenizerConfig_ExtraSpecialTokens_FunctionCall() throws {
        // Mistral/Pixtral models stash tool tokens in tokenizer_config.json
        try writeJSON("tokenizer_config.json", """
        {"extra_special_tokens": ["<function_call>", "</function_call>"], "model_type": "mistral"}
        """)
        let profile = detect()
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .mistralXML)
    }

    func testTokenizerConfig_JinjaTemplate_ParallelToolCalls() throws {
        try writeJSON("tokenizer_config.json", """
        {"chat_template": "{% for message in messages %}{{ message.content }}{% endfor %}{% if tools %}{% for tool in tools %}{{ tool }}{% endfor %}{% endif %}{% for tc in message.tool_calls %}{{ tc }}{% endfor %}"}
        """)
        let profile = detect()
        XCTAssertEqual(profile.capability, .parallelActions,
                       "Jinja template with message.tool_calls should trigger parallelActions")
    }

    func testTokenizerConfig_JinjaTemplate_MistralXMLSignal() throws {
        try writeJSON("tokenizer_config.json", """
        {"chat_template": "{% for message in messages %}{{ message.content }}{% endfor %}[TOOL_CALLS]{% for tool in tools %}{{ tool }}{% endfor %}"}
        """)
        let profile = detect()
        XCTAssertEqual(profile.dialect, .mistralXML,
                       "[TOOL_CALLS] in Jinja template should set mistralXML dialect")
    }

    // MARK: - Tier 2: Known Family Names → parallelActions

    func testFamilyName_Mistral_ParallelActions_NativeJSON() throws {
        let profile = detect(modelName: "mistral-7b-instruct-v0.3")
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .nativeJSON)
    }

    func testFamilyName_Llama31_ParallelActions_NativeJSON() throws {
        let profile = detect(modelName: "meta-llama-3.1-8b-instruct")
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .nativeJSON)
    }

    func testFamilyName_Devstral_ParallelActions_NativeJSON() throws {
        let profile = detect(modelName: "devstral-small-2505")
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .nativeJSON)
    }

    func testFamilyName_Pixtral_ParallelActions_NativeJSON() throws {
        let profile = detect(modelName: "pixtral-12b-2409")
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .nativeJSON)
    }

    func testFamilyName_ToolUse_ParallelActions_NativeJSON() throws {
        let profile = detect(modelName: "llama-3-groq-tool-use-8b")
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .nativeJSON)
    }

    // MARK: - Tier 2: Config.json _name_or_path Overrides Display Name

    func testConfigJson_NameOrPath_OverridesModelName() throws {
        // Display name is generic, but config.json reveals the true family
        try writeJSON("config.json", """
        {"_name_or_path": "mistralai/Mistral-7B-Instruct-v0.3"}
        """)
        let profile = detect(modelName: "my-custom-finetune")
        XCTAssertEqual(profile.capability, .parallelActions,
                       "_name_or_path should override display name for family detection")
    }

    // MARK: - Tier 3: Basic Tool Template → singleAction

    func testJinjaTemplate_BasicTools_SingleAction() throws {
        // Template has tools loop but no parallel/special token signals
        try writeJSON("tokenizer_config.json", """
        {"chat_template": "{% for message in messages %}{{ message.content }}{% endfor %}{% if tools %}Use these tools{% endif %}"}
        """)
        let profile = detect(modelName: "unknown-model")
        XCTAssertEqual(profile.capability, .singleAction)
    }

    func testJinjaTemplate_BasicTools_HeuristicJsonDialect() throws {
        // singleAction without specific dialect signals → heuristicJson
        try writeJSON("tokenizer_config.json", """
        {"chat_template": "{% for message in messages %}{{ message.content }}{% endfor %}{% if tools %}Available tools: {{ tools }}{% endif %}"}
        """)
        let profile = detect(modelName: "unknown-model")
        XCTAssertEqual(profile.capability, .singleAction)
        XCTAssertEqual(profile.dialect, .heuristicJson)
    }

    // MARK: - Tier 3: singleAction with Dialect Signals

    func testSingleAction_MistralXMLSignalInTemplate() throws {
        // Jinja template has [AVAILABLE_TOOLS] → mistralXML signal
        // But no parallel template marker → singleAction
        // (edge case: XML signal present but no parallel proof)
        try writeJSON("tokenizer_config.json", """
        {"chat_template": "{% if tools %}[AVAILABLE_TOOLS]{{ tools }}[/AVAILABLE_TOOLS]{% endif %}{{ messages }}"}
        """)
        // [AVAILABLE_TOOLS] is also a parallel template marker, so this should actually be parallelActions
        let profile = detect(modelName: "unknown-model")
        // The check `hasParallelTemplate` looks for [AVAILABLE_TOOLS], so this promotes to parallelActions
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .mistralXML)
    }

    func testSingleAction_ReActSignalInTemplate() throws {
        // Jinja template has Action:/Thought: markers
        try writeJSON("tokenizer_config.json", """
        {"chat_template": "{% for message in messages %}{{ message.content }}{% endfor %}{% if tools %}Thought: reasoning\\nAction: tool{% endif %}"}
        """)
        let profile = detect(modelName: "unknown-model")
        XCTAssertEqual(profile.dialect, .reactMarkdown,
                       "Action:/Thought: in Jinja template should set reactMarkdown dialect")
    }

    // MARK: - Tier 4: No Tool Support → none

    func testNoConfig_NoTokens_None() throws {
        // Empty model directory — no files at all
        let profile = detect(modelName: "empty-model")
        XCTAssertEqual(profile.capability, .none)
        XCTAssertEqual(profile.dialect, .heuristicJson)
    }

    func testTokenizerConfig_NoToolTemplate_None() throws {
        // Chat template exists but has no tool references
        try writeJSON("tokenizer_config.json", """
        {"chat_template": "{% for message in messages %}{{ message.content }}{% endfor %}"}
        """)
        let profile = detect(modelName: "unknown-model")
        XCTAssertEqual(profile.capability, .none)
    }

    // MARK: - Dialect Priority: Mistral XML > ReAct > heuristicJson

    func testDialectPriority_MistralXML_BeatsReAct() throws {
        // Both XML and ReAct signals present in special tokens + template
        try writeJSON("special_tokens_map.json", """
        {"additional_special_tokens": ["[TOOL_CALLS]"]}
        """)
        try writeJSON("tokenizer_config.json", """
        {"chat_template": "{% if tools %}Thought: reason\\nAction: act{% endif %}{% for message in messages %}{{ message.content }}{% endfor %}"}
        """)
        let profile = detect(modelName: "unknown-model")
        XCTAssertEqual(profile.dialect, .mistralXML,
                       "Mistral XML signal should take priority over ReAct hints")
    }

    // MARK: - Stop Sequence Extraction

    func testStopSequences_LlamaTokens() throws {
        try writeJSON("special_tokens_map.json", """
        {"eos_token": "</s>", "additional_special_tokens": ["<|eot_id|>", "<|start_header_id|>", "<|end_header_id|>"]}
        """)
        let profile = detect(modelName: "test-llama-model")
        XCTAssertTrue(profile.stopSequences.contains("<|eot_id|>"),
                      "Llama turn-boundary token should be extracted as stop sequence")
    }

    func testStopSequences_ChatMLTokens() throws {
        try writeJSON("special_tokens_map.json", """
        {"additional_special_tokens": ["<|im_start|>", "<|im_end|>"]}
        """)
        let profile = detect(modelName: "test-chatml-model")
        XCTAssertTrue(profile.stopSequences.contains("<|im_end|>"),
                      "ChatML end token should be extracted as stop sequence")
    }
}

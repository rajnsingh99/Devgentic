//
//  OllamaCognitiveProfileTests.swift
//  DevgenticTests
//
//  Tests for OllamaShowResponse.cognitiveProfile — the dialect and capability
//  detection engine for Ollama models. Covers primary tool markers, secondary
//  chat-format signals, family matching, modelfile hints, and metadata extraction.
//

import XCTest
@testable import devgentic

final class OllamaCognitiveProfileTests: XCTestCase {

    // MARK: - Helpers

    /// Builds an OllamaShowResponse with the given signals for testing.
    private func makeResponse(
        template: String? = nil,
        modelfile: String? = nil,
        family: String? = nil,
        families: [String]? = nil,
        parameterSize: String? = nil,
        capabilities: [String]? = nil
    ) -> OllamaShowResponse {
        let details = OllamaModelDetails(
            format: nil,
            family: family,
            families: families,
            parameterSize: parameterSize,
            quantizationLevel: nil
        )
        return OllamaShowResponse(
            license: nil,
            modelfile: modelfile,
            parameters: nil,
            template: template,
            details: details,
            capabilities: capabilities
        )
    }

    // MARK: - parallelActions: Native Go Template Tools

    func testGoTemplate_ToolsMarker_ParallelActions_NativeJSON() {
        let response = makeResponse(template: "{{ .System }}\n{{ .Prompt }}\n{{ .Tools }}")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .nativeJSON)
    }

    func testGoTemplate_CompactToolsMarker_ParallelActions_NativeJSON() {
        let response = makeResponse(template: "{{.System}}{{.Prompt}}{{.Tools}}")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .nativeJSON)
    }

    func testGoTemplate_ConditionalToolsMarker_ParallelActions_NativeJSON() {
        let response = makeResponse(template: "{{- if .Tools }}{{ .Tools }}{{- end }}")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .nativeJSON)
    }

    // MARK: - parallelActions: Mistral XML Markers

    func testTemplate_ToolCallXML_ParallelActions_MistralXML() {
        let response = makeResponse(template: "<tool_call>{\"name\": \"foo\"}</tool_call>")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .mistralXML)
    }

    func testTemplate_ToolCallsBracket_ParallelActions_MistralXML() {
        let response = makeResponse(template: "[TOOL_CALLS] [{\"name\": \"bar\"}]")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .mistralXML)
    }

    func testTemplate_FunctionCallXML_ParallelActions_MistralXML() {
        // Blind spot fix: <function_call> is now detected as Mistral XML marker
        let response = makeResponse(template: "<function_call>{\"name\": \"foo\"}</function_call>")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .mistralXML)
    }

    // MARK: - parallelActions: ReAct Markers

    func testTemplate_AvailableTools_ParallelActions_ReActMarkdown() {
        let response = makeResponse(template: "[AVAILABLE_TOOLS] tools here [/AVAILABLE_TOOLS]")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .reactMarkdown)
    }

    // MARK: - parallelActions: Known Families

    func testFamily_Llama31_ParallelActions_NativeJSON() {
        let response = makeResponse(family: "llama3.1")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .nativeJSON)
    }

    func testFamily_Llama32_ParallelActions_NativeJSON() {
        let response = makeResponse(family: "llama3.2")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .nativeJSON)
    }

    func testFamily_Mistral_ParallelActions_NativeJSON() {
        let response = makeResponse(family: "mistral")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .nativeJSON)
    }

    func testFamily_Qwen25_ParallelActions_NativeJSON() {
        let response = makeResponse(family: "qwen2.5")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .nativeJSON)
    }

    func testFamily_Hermes_ParallelActions_NativeJSON() {
        let response = makeResponse(family: "hermes")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .nativeJSON)
    }

    func testFamily_CommandR_ParallelActions_NativeJSON() {
        let response = makeResponse(family: "command-r")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .nativeJSON)
    }

    func testFamilies_Array_Llama32_ParallelActions_NativeJSON() {
        let response = makeResponse(families: ["llama3.2", "clip"])
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .nativeJSON)
    }

    // MARK: - singleAction: Modelfile Hints Only

    func testModelfileHint_Tool_SingleAction_HeuristicJson() {
        let response = makeResponse(modelfile: "This model supports tool use and function calling.")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .singleAction)
        XCTAssertEqual(profile.dialect, .heuristicJson, "No structural hints — should fall to heuristicJson")
    }

    func testModelfileHint_FunctionCalling_SingleAction() {
        let response = makeResponse(modelfile: "Supports function calling via JSON schema.")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .singleAction)
    }

    func testModelfileHint_JsonSchema_SingleAction() {
        let response = makeResponse(modelfile: "Uses json_schema for structured output.")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .singleAction)
    }

    // MARK: - singleAction: Secondary Dialect Signals (Mistral Chat Structure)

    func testSingleAction_MistralChatStructure_INST_MistralXML() {
        // Template has [INST] chat markers but no explicit tool markers
        // → singleAction (from modelfile hint) + mistralXML (from chat structure)
        let response = makeResponse(
            template: "[INST] {{ .System }} {{ .Prompt }} [/INST]",
            modelfile: "This model supports tool calling."
        )
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .singleAction)
        XCTAssertEqual(profile.dialect, .mistralXML, "Mistral chat structure [INST]/[/INST] should infer XML dialect")
    }

    func testSingleAction_INSTClose_MistralXML() {
        // Only [/INST] closing tag present
        let response = makeResponse(
            template: "{{ .System }} {{ .Prompt }} [/INST]",
            modelfile: "Fine-tuned for tool use."
        )
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .singleAction)
        XCTAssertEqual(profile.dialect, .mistralXML)
    }

    // MARK: - singleAction: Secondary Dialect Signals (ReAct Structure Hints)

    func testSingleAction_ReActHintsInTemplate_ReactMarkdown() {
        // Template contains Thought:/Action: markers → infer ReAct dialect
        let response = makeResponse(
            template: "{{ .System }}\nThought: reasoning\nAction: tool_name",
            modelfile: "Supports tool calling."
        )
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .singleAction)
        XCTAssertEqual(profile.dialect, .reactMarkdown, "Thought/Action markers in template should infer ReAct dialect")
    }

    func testSingleAction_ReActHintsInModelfile_ReactMarkdown() {
        // Modelfile system prompt contains ReAct markers
        let response = makeResponse(
            modelfile: "SYSTEM You use a Thought: / Action: / Action Input: loop to solve tasks. Supports tool calling."
        )
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .singleAction)
        XCTAssertEqual(profile.dialect, .reactMarkdown, "Thought/Action markers in modelfile should infer ReAct dialect")
    }

    // MARK: - singleAction: Mistral Takes Precedence Over ReAct

    func testSingleAction_BothSignals_MistralWins() {
        // Both Mistral chat structure and ReAct hints present — Mistral takes precedence
        let response = makeResponse(
            template: "[INST] Thought: reason\nAction: do_thing [/INST]",
            modelfile: "Supports tool calling."
        )
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .singleAction)
        XCTAssertEqual(profile.dialect, .mistralXML, "Mistral chat structure should take precedence over ReAct hints")
    }

    // MARK: - none: No Signals

    func testNoSignals_None_HeuristicJson() {
        let response = makeResponse()
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .none)
        XCTAssertEqual(profile.dialect, .heuristicJson)
    }

    func testNoSignals_PlainTemplate_None() {
        let response = makeResponse(template: "{{ .System }}\n{{ .Prompt }}")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .none)
        XCTAssertEqual(profile.dialect, .heuristicJson)
    }

    func testUnknownFamily_NoModelfile_None() {
        let response = makeResponse(family: "custom-fine-tune")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .none)
    }

    // MARK: - Metadata: Parameter Size Tiers

    func testMetadata_TinyModel() {
        let response = makeResponse(parameterSize: "3B")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.metadata?.tier, .tiny)
    }

    func testMetadata_SmallModel() {
        let response = makeResponse(parameterSize: "7B")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.metadata?.tier, .small)
    }

    func testMetadata_MediumModel() {
        let response = makeResponse(parameterSize: "32B")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.metadata?.tier, .medium)
    }

    func testMetadata_LargeModel() {
        let response = makeResponse(parameterSize: "70B")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.metadata?.tier, .large)
    }

    func testMetadata_UltraModel() {
        let response = makeResponse(parameterSize: "405B")
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.metadata?.tier, .ultra)
    }

    // MARK: - Signal Priority: Template Markers Beat Family

    func testPriority_MistralXMLMarker_OverridesFamily() {
        // Template has <tool_call> AND family is "llama3.1"
        // Template XML marker should dictate dialect (.mistralXML), not family (.nativeJSON)
        let response = makeResponse(
            template: "<tool_call>{\"name\": \"test\"}</tool_call>",
            family: "llama3.1"
        )
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .mistralXML, "XML marker in template should override family-based nativeJSON")
    }

    func testPriority_ReActMarker_OverridesFamily() {
        let response = makeResponse(
            template: "[AVAILABLE_TOOLS] tools [/AVAILABLE_TOOLS]",
            family: "mistral"
        )
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .reactMarkdown, "ReAct marker should override family dialect")
    }

    // MARK: - Signal Priority: Primary Markers Promote Past singleAction

    func testPriority_TemplateToolMarker_PromotesToParallel() {
        // Both template marker AND modelfile hint present.
        // Template marker should win → parallelActions, not singleAction
        let response = makeResponse(
            template: "{{ .Tools }}",
            modelfile: "Supports tool calling."
        )
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions, "Template marker should promote past singleAction")
    }

    // MARK: - Authoritative capabilities field (Ollama 0.3.4+)

    func testCapabilities_LacksTools_ForcesNone_EvenWithCapableFamily() {
        // Server reports completion-only; family="qwen2" would otherwise fall through
        // to parallelActions. The authoritative signal must win.
        let response = makeResponse(
            template: "{{ .Tools }}",
            family: "qwen2",
            capabilities: ["completion"]
        )
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .none, "Missing 'tools' in /api/show capabilities must force .none")
        XCTAssertEqual(profile.dialect, .heuristicJson)
    }

    func testCapabilities_IncludesTools_AllowsCapableClassification() {
        // Server reports tool support; heuristic path should still classify correctly.
        let response = makeResponse(
            template: "{{ .Tools }}",
            family: "qwen2",
            capabilities: ["completion", "tools"]
        )
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions)
        XCTAssertEqual(profile.dialect, .nativeJSON)
    }

    func testCapabilities_Absent_FallsThroughToHeuristic() {
        // Older Ollama without the capabilities field — must not be forced to .none.
        let response = makeResponse(
            template: "{{ .Tools }}",
            family: "qwen2",
            capabilities: nil
        )
        let profile = response.cognitiveProfile
        XCTAssertEqual(profile.capability, .parallelActions, "No capabilities field → heuristic path decides")
    }

    // MARK: - Reasoning-only override (deepseek-r1 family with qwen2 base)

    func testReasoningOnly_DeepSeekR1_WithQwen2Family_ForcesNone() {
        // The exact deepseek-r1:14b case: family reports as the tool-capable base (qwen2),
        // but the model name carries the reasoning-only identity. Must force .none.
        let response = makeResponse(
            template: "{{ .Tools }}",
            family: "qwen2",
            capabilities: nil
        )
        let profile = response.cognitiveProfile(modelName: "deepseek-r1:14b")
        XCTAssertEqual(profile.capability, .none, "deepseek-r1 name must force .none regardless of qwen2 family")
        XCTAssertEqual(profile.dialect, .heuristicJson)
    }

    func testReasoningOnly_QwQ_ForcesNone() {
        let response = makeResponse(template: "{{ .Tools }}", family: "qwen2")
        let profile = response.cognitiveProfile(modelName: "qwq:32b")
        XCTAssertEqual(profile.capability, .none)
    }

    func testReasoningOnly_Qwen3_NotBlocked() {
        // qwen3 is BOTH thinking AND tool-capable — must NOT be forced to .none.
        // This locks in the explicit exclusion from the reasoning-only pattern list.
        let response = makeResponse(template: "{{ .Tools }}", family: "qwen3")
        let profile = response.cognitiveProfile(modelName: "qwen3:14b")
        XCTAssertEqual(profile.capability, .parallelActions, "qwen3 supports tools AND thinking — must not be force-denied")
    }

    func testReasoningOnly_DetectedViaFamilyEvenWithoutModelName() {
        // If the runtime caller doesn't pass modelName, family detection still catches
        // the base deepseek-r1 case (when Ollama reports family="deepseek-r1" directly).
        let response = makeResponse(family: "deepseek-r1")
        let profile = response.cognitiveProfile  // No modelName
        XCTAssertEqual(profile.capability, .none)
    }
}

//
//  CognitiveGeneratorRoutingTests.swift
//  DevgenticTests
//
//  Tests for generator property correctness and workflow routing.
//  Verifies that each generator has the expected dialect rules, tool adapter,
//  prompt wrapping, and parse dialect — and that WorkflowCognitiveGenerator
//  correctly delegates to all inner generator types including XMLNativeStructuredGenerator.
//

import XCTest
@testable import devgentic

// MARK: - Generator Property Tests

final class CognitiveGeneratorPropertyTests: XCTestCase {

    // MARK: - XMLNativeStructuredGenerator (NEW)

    func testXMLNative_HasDialectRules() {
        let generator = XMLNativeStructuredGenerator()
        XCTAssertNotNil(generator.dialectRules, "XMLNativeStructuredGenerator must have dialect rules")
    }

    func testXMLNative_DialectRules_ContainParallelInstruction() {
        let generator = XMLNativeStructuredGenerator()
        let rules = generator.dialectRules ?? ""
        XCTAssertTrue(rules.contains("MULTIPLE"), "Should explicitly encourage multiple tool_call blocks")
        XCTAssertTrue(rules.contains("<tool_call>"), "Should reference XML tool_call format")
    }

    func testXMLNative_UsesMarkdownWrapping() {
        let generator = XMLNativeStructuredGenerator()
        XCTAssertEqual(generator.promptWrapping, .markdown,
                       "Markdown wrapping avoids conflicts with XML tool output")
    }

    func testXMLNative_UsesPromptedMarkdownAdapter() {
        let generator = XMLNativeStructuredGenerator()
        XCTAssertTrue(generator.toolAdapter is PromptedMarkdownAdapter,
                      "Should use PromptedMarkdownAdapter (prompt-embedded tools, not API-native)")
    }

    func testXMLNative_PromptTrigger_ReferencesToolCallBlocks() {
        let generator = XMLNativeStructuredGenerator()
        let trigger = generator.promptTrigger(for: 1)
        XCTAssertTrue(trigger.contains("<tool_call>"),
                      "Prompt trigger should reference XML format")
    }

    // MARK: - XMLStructuredGenerator (singleAction Mistral)

    func testXML_HasDialectRules() {
        let generator = XMLStructuredGenerator()
        XCTAssertNotNil(generator.dialectRules)
    }

    func testXML_UsesLegacyPromptAdapter() {
        let generator = XMLStructuredGenerator()
        XCTAssertTrue(generator.toolAdapter is LegacyPromptAdapter)
    }

    func testXML_UsesXMLWrapping() {
        let generator = XMLStructuredGenerator()
        XCTAssertEqual(generator.promptWrapping, .xml, "Default wrapping should be XML")
    }

    // MARK: - MLXNativeStructuredGenerator (parallelActions JSON)

    func testMLXNative_HasDialectRules() {
        let generator = MLXNativeStructuredGenerator()
        XCTAssertNotNil(generator.dialectRules)
    }

    func testMLXNative_DialectRules_ContainParallelInstruction() {
        let generator = MLXNativeStructuredGenerator()
        let rules = generator.dialectRules ?? ""
        XCTAssertTrue(rules.contains("multiple tools"), "Should encourage parallel JSON tool calls")
        XCTAssertTrue(rules.contains("tool_calls"), "Should reference tool_calls JSON array")
    }

    func testMLXNative_UsesMarkdownWrapping() {
        let generator = MLXNativeStructuredGenerator()
        XCTAssertEqual(generator.promptWrapping, .markdown)
    }

    func testMLXNative_UsesPromptedMarkdownAdapter() {
        let generator = MLXNativeStructuredGenerator()
        XCTAssertTrue(generator.toolAdapter is PromptedMarkdownAdapter)
    }

    // MARK: - MarkdownStructuredGenerator (singleAction default)

    func testMarkdown_HasDialectRules() {
        let generator = MarkdownStructuredGenerator()
        XCTAssertNotNil(generator.dialectRules)
    }

    func testMarkdown_UsesMarkdownWrapping() {
        let generator = MarkdownStructuredGenerator()
        XCTAssertEqual(generator.promptWrapping, .markdown)
    }

    // MARK: - NativeStructuredGenerator (Cloud / Ollama parallel)

    func testNative_NoDialectRules() {
        let generator = NativeStructuredGenerator()
        XCTAssertNil(generator.dialectRules, "Native generators use API tools, not prompt rules")
    }

    func testNative_UsesNativeJSONSchemaAdapter() {
        let generator = NativeStructuredGenerator()
        XCTAssertTrue(generator.toolAdapter is NativeJSONSchemaAdapter)
    }

    // MARK: - JsonStructuredGenerator (none / bot fallback)

    func testJson_HasDialectRules() {
        let generator = JsonStructuredGenerator()
        XCTAssertNotNil(generator.dialectRules)
    }
}

// MARK: - Workflow Generator Routing Tests

final class WorkflowGeneratorRoutingTests: XCTestCase {

    /// Builds a minimal WorkflowExecutionContext for testing.
    private func makeWorkflowContext() -> WorkflowExecutionContext {
        WorkflowExecutionContext(
            taskDescription: "Test task",
            upstreamInput: "test input",
            isFirstNode: false,
            nodeName: "test-node"
        )
    }

    /// Builds a minimal SemanticContext for end-to-end workflow tests.
    private func makeSemanticContext() -> SemanticContext {
        SemanticContext(
            instructions: "Test assistant",
            environmentFacts: EnvironmentFacts(
                osVersion: "macOS 15.4",
                shellType: "zsh",
                userName: "testuser",
                currentDate: "2026-04-15"
            ),
            longTermMemory: StaticGroundingMemory(ragContext: ""),
            recentHistory: nil,
            nativeHistoryTurns: nil,
            originalQuery: "Test query",
            currentIteration: 1,
            compiledScratchpad: "",
            latestClarification: nil,
            negativeConstraints: [],
            hallucinatedTools: [],
            availableTools: [],
            userProfile: nil,
            skillManifests: nil,
            taskDescription: nil
        )
    }

    // MARK: - Inner Generator Delegation

    func testWorkflow_WrapsXMLNative_DelegatesDialectRules() {
        let inner = XMLNativeStructuredGenerator()
        let workflow = WorkflowCognitiveGenerator(
            inner: inner,
            workflowContext: makeWorkflowContext(),
            isNativeFlow: false
        )
        XCTAssertEqual(workflow.dialectRules, inner.dialectRules,
                       "Workflow should delegate dialectRules from inner XMLNativeStructuredGenerator")
    }

    func testWorkflow_WrapsXMLNative_DelegatesToolAdapter() {
        let inner = XMLNativeStructuredGenerator()
        let workflow = WorkflowCognitiveGenerator(
            inner: inner,
            workflowContext: makeWorkflowContext(),
            isNativeFlow: false
        )
        XCTAssertTrue(workflow.toolAdapter is PromptedMarkdownAdapter,
                      "Workflow should inherit PromptedMarkdownAdapter from inner XMLNativeStructuredGenerator")
    }

    func testWorkflow_WrapsMLXNative_DelegatesDialectRules() {
        let inner = MLXNativeStructuredGenerator()
        let workflow = WorkflowCognitiveGenerator(
            inner: inner,
            workflowContext: makeWorkflowContext(),
            isNativeFlow: false
        )
        XCTAssertNotNil(workflow.dialectRules)
        XCTAssertTrue(workflow.dialectRules?.contains("tool_calls") ?? false)
    }

    func testWorkflow_WrapsXML_DelegatesDialectRules() {
        let inner = XMLStructuredGenerator()
        let workflow = WorkflowCognitiveGenerator(
            inner: inner,
            workflowContext: makeWorkflowContext(),
            isNativeFlow: false
        )
        XCTAssertTrue(workflow.dialectRules?.contains("<tool_call>") ?? false)
    }

    func testWorkflow_WrapsMarkdown_DelegatesDialectRules() {
        let inner = MarkdownStructuredGenerator()
        let workflow = WorkflowCognitiveGenerator(
            inner: inner,
            workflowContext: makeWorkflowContext(),
            isNativeFlow: false
        )
        XCTAssertNotNil(workflow.dialectRules)
    }

    func testWorkflow_WrapsNative_NoDialectRules() {
        let inner = NativeStructuredGenerator()
        let workflow = WorkflowCognitiveGenerator(
            inner: inner,
            workflowContext: makeWorkflowContext(),
            isNativeFlow: true
        )
        XCTAssertNil(workflow.dialectRules, "Native flow should have nil dialect rules")
    }

    // MARK: - Parse Dialect Verification
    //
    // Verifies that the parser backing each generator's dialect correctly handles
    // the model output it would receive at runtime. Uses direct parser instantiation
    // via ParserFactory (the same factory the pipeline delegates to).

    func testParserFactory_MistralXML_SingleToolCall() {
        let xmlResponse = """
        <tool_call>
          <content>Listing the directory.</content>
          <tool_name>list_directory</tool_name>
          <arguments>{"path": "/tmp"}</arguments>
        </tool_call>
        """
        let parser = MistralXMLParser()
        let step = parser.parse(rawResponse: xmlResponse)
        XCTAssertEqual(step.toolCalls.count, 1, "MistralXML parser should parse single tool call")
        XCTAssertEqual(step.toolCalls.first?.name, "list_directory")
    }

    func testParserFactory_MistralXML_ParallelToolCalls() {
        let xmlResponse = """
        <tool_call>
          <content>Need to check two locations.</content>
          <tool_name>list_directory</tool_name>
          <arguments>{"path": "/tmp"}</arguments>
        </tool_call>
        <tool_call>
          <content>Also reading a file.</content>
          <tool_name>read_file</tool_name>
          <arguments>{"path": "/tmp/config.json"}</arguments>
        </tool_call>
        """
        let parser = MistralXMLParser()
        let step = parser.parse(rawResponse: xmlResponse)
        XCTAssertEqual(step.toolCalls.count, 2, "MistralXML parser should parse parallel tool calls")
        XCTAssertEqual(step.toolCalls[0].name, "list_directory")
        XCTAssertEqual(step.toolCalls[1].name, "read_file")
    }

    func testParserFactory_HeuristicJSON_SingleToolCall() {
        let jsonResponse = """
        {"content": "Checking the file.", "tool_calls": [{"name": "read_file", "arguments": {"path": "/a.txt"}}]}
        """
        let parser = HeuristicCognitiveParser()
        let step = parser.parse(rawResponse: jsonResponse)
        XCTAssertEqual(step.toolCalls.count, 1, "HeuristicJSON parser should parse single tool call")
        XCTAssertEqual(step.toolCalls.first?.name, "read_file")
    }

    func testParserFactory_DialectToParserMapping() {
        // Verify ParserFactory routes each dialect to the correct parser type
        XCTAssertTrue(ParserFactory.createParser(for: .mistralXML) is MistralXMLParser)
        XCTAssertTrue(ParserFactory.createParser(for: .reactMarkdown) is ReActMarkdownParser)
        XCTAssertTrue(ParserFactory.createParser(for: .nativeJSON) is NativeJSONParser)
        XCTAssertTrue(ParserFactory.createParser(for: .heuristicJson) is HeuristicCognitiveParser)
    }
}

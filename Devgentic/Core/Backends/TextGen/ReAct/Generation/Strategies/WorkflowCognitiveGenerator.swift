//
//  WorkflowCognitiveGenerator.swift
//  Devgentic
//
//  Created by Claude on 13/04/26.
//
//  Workflow-aware cognitive generator that produces clean task+input prompts
//  for workflow node execution. Unlike a decorator, this generator fully owns
//  both prompt construction AND the LLM call, because Swift struct method
//  dispatch is static — delegating generateCognitiveStep() to an inner
//  generator would cause it to call its own compileMessages(), bypassing
//  the workflow prompt entirely.
//
//  Architecture:
//  - compileMessages(): Builds workflow-specific prompt (task + input, no RAG/history)
//  - generateCognitiveStep(): Compiles workflow messages, appends dialect-specific
//    trigger, calls the model, and parses the response — all using the inner
//    generator's toolAdapter for schema compatibility.
//
//  Prompt structure:
//  - <system_instructions>: profile persona (WHO)
//  - <task>: per-node directive (WHAT)
//  - <available_skills>: skill discovery (if configured)
//  - <environment>: minimal (date only)
//  - <execution_contract> + <available_tools>: non-native only
//  - <input>/<query>: upstream data or user query (WITH)
//

import Foundation
import OSLog

private let wfGenLogger = DGLogger(category: "WorkflowGenerator")

// MARK: - Workflow Cognitive Generator

/// A workflow-aware generator that fully owns prompt construction AND model invocation.
///
/// The inner generator is retained only for:
/// - `toolAdapter`: Schema format (Claude/Gemini/OpenAI/Legacy adapters)
/// - Type identity: Determines prompt trigger style, model call path, and parse dialect
///
/// This generator does NOT delegate `generateCognitiveStep` to the inner generator,
/// because Swift struct dispatch would cause the inner generator to call its own
/// `compileMessages()` (the standard chat sandwich), bypassing the workflow prompt.
struct WorkflowCognitiveGenerator: CognitiveGenerator {

    /// The dialect-specific generator (Native, XML, Markdown, JSON, MLX).
    /// Retained for toolAdapter and type-based routing.
    let inner: any CognitiveGenerator

    /// Workflow execution context carrying task description, upstream input, and user query.
    let workflowContext: WorkflowExecutionContext

    /// True for cloud providers (Claude, GPT, Gemini) — tools sent via API, not in prompt.
    let isNativeFlow: Bool

    // MARK: - CognitiveGenerator Conformance

    var toolAdapter: ToolSchemaAdapter { inner.toolAdapter }
    var dialectRules: String? { inner.dialectRules }

    // MARK: - Prompt Construction

    /// Builds workflow-specific messages by delegating to the shared `buildStandardMessages()` builder.
    /// Workflow config strips RAG, episodic memory, and user profile. The user message prefix
    /// carries the workflow-specific trigger or upstream `<input>` data.
    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        wfGenLogger.info("Compiling workflow prompt: node='\(workflowContext.nodeName)', task=\(workflowContext.taskDescription.count) chars, isNativeFlow=\(isNativeFlow), tools=\(context.availableTools.count), isFirstNode=\(workflowContext.isFirstNode)")

        let wrapping = inner.promptWrapping

        // Compute workflow-specific user message prefix
        let prefix: String
        if workflowContext.isFirstNode {
            prefix = "Execute your task."
        } else if workflowContext.upstreamInput.isEmpty {
            prefix = "No input data provided. Execute your task based on the task description."
        } else {
            prefix = wrapping.section("input", content: workflowContext.upstreamInput)
        }

        let messages = buildStandardMessages(
            context: context,
            dialectRules: inner.dialectRules,
            isNativeFlow: isNativeFlow,
            layerConfig: .workflow,
            userMessagePrefix: prefix,
            wrapping: wrapping
        )

        wfGenLogger.debug("Workflow prompt compiled: \(messages.count) messages")
        return messages
    }

    // MARK: - Cognitive Step Generation (Full Ownership)

    /// Compiles workflow-specific messages, appends a dialect-appropriate trigger,
    /// calls the model, and parses the response.
    ///
    /// Unlike the broken delegation approach (where the inner generator would call
    /// its own `compileMessages()`), this method calls `self.compileMessages()` to
    /// ensure the clean workflow prompt is used.
    func generateCognitiveStep(
        model: any LLMProvider,
        context: SemanticContext,
        iteration: Int
    ) async throws -> ModernCognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        wfGenLogger.info("[Workflow:\(reqId)] generateCognitiveStep — iteration: \(iteration), node: '\(workflowContext.nodeName)', innerType: \(String(describing: type(of: inner)))")

        // 1. Compile workflow-specific messages (OUR override, not the inner generator's)
        var executionMessages = compileMessages(from: context)

        // 2. Determine execution path based on inner generator type
        let startTime = Date()

        // Trigger comes from the inner generator — single source of truth, no duplication.
        executionMessages.append(["role": "user", "content": inner.promptTrigger(for: iteration)])

        if isNativeFlow {
            // === NATIVE PATH (Claude, GPT, Gemini, Ollama parallel) ===
            // Tools sent as separate API parameter; model returns structured step.
            let nativeTools = toolAdapter.formatForNativeAPI(context.availableTools)

            wfGenLogger.debug("[Workflow:\(reqId)] Native path: \(executionMessages.count) messages, \(nativeTools?.count ?? 0) tools")

            let step = try await model.generateCognitiveStep(
                messages: executionMessages,
                tools: nativeTools
            )

            let duration = Date().timeIntervalSince(startTime)
            wfGenLogger.info("[Workflow:\(reqId)] Native response in \(String(format: "%.2f", duration))s — \(step.toolCalls.count) tool(s)")

            return step

        } else {
            // === NON-NATIVE PATH (XML, Markdown, JSON, MLX) ===
            // Tools embedded in system prompt; model returns raw text to parse.
            let (responseSchema, parseDialect) = resolveNonNativeConfig()

            wfGenLogger.debug("[Workflow:\(reqId)] Non-native path (\(String(describing: parseDialect))): \(executionMessages.count) messages, schema=\(responseSchema ?? "nil")")

            let responseText = try await model.generate(
                messages: executionMessages,
                tools: nil,
                responseSchema: responseSchema
            )

            let duration = Date().timeIntervalSince(startTime)
            wfGenLogger.info("[Workflow:\(reqId)] Non-native response in \(String(format: "%.2f", duration))s — \(responseText.count) chars")

            guard !responseText.isEmpty else {
                wfGenLogger.error("[Workflow:\(reqId)] Empty response from model")
                throw NSError(domain: "WorkflowGenerator", code: 422,
                              userInfo: [NSLocalizedDescriptionKey: "Empty response from model during workflow node execution."])
            }

            let pipeline = CognitiveParsePipeline(
                expectedDialect: parseDialect,
                modelId: model.modelName,
                iteration: iteration
            )
            return pipeline.parse(raw: responseText)
        }
    }

    // MARK: - Non-Native Configuration Resolution

    /// Determines response schema and parse dialect based on inner generator type.
    /// Prompt triggers are now handled by `inner.promptTrigger(for:)` — single source of truth.
    private func resolveNonNativeConfig() -> (
        responseSchema: String?,
        parseDialect: ModelDialect
    ) {
        switch inner {
        case is XMLStructuredGenerator, is XMLNativeStructuredGenerator:
            return (nil, .mistralXML)
        case is MarkdownStructuredGenerator:
            return (nil, .reactMarkdown)
        case is MLXNativeStructuredGenerator:
            return ("json", .heuristicJson)
        case let json as JsonStructuredGenerator:
            return ("json", json.dialect)
        default:
            wfGenLogger.warning("Unknown inner generator type: \(type(of: inner)). Falling back to JSON mode.")
            return ("json", .heuristicJson)
        }
    }
}

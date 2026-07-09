//
//  AgentConnect.swift
//  Devgentic
//
//  Created by Raj Singh on 23/01/26.
//  Updated: Enforced strict Agent vs Bot capability routing.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "AgentConnect")
private let logToolExecution = DGLogger(category: "ToolExecution")

/// A unified agent connection service that serves as the central controller for
/// all LLM interactions (Bots, Agents, Workflows).
/// It acts as the Hub, initializing models, resolving tools, and routing to the correct Executor.
@Observable
class AgentConnect: @unchecked Sendable {
    
    // MARK: - Initialization
    
    init() {
        logger.info("AgentConnect initialized. Unified Pipeline Ready.")
    }
    
    // MARK: - Unified Stream Handling
    
    /// The single entry point for all LLM streaming requests.
    /// Routes automatically to the correct Executor (Chat vs ReAct) based on the profile.
    func streamAgentResponse(
        for profile: BackendProfileModel,
        userInput: String,
        chatHistory: [ChatMessage],
        conversationID: UUID,
        ragContext: String? = nil,
        userPayload: Payload? = nil,
        resumeState: TimelineReconstruction? = nil,
        traceContext: TraceContext,
        onTraceUpdate: (@Sendable (AgentTraceLog) -> Void)? = nil
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {

        logger.info("Request reached TextGen Unified Pipeline for profile: \(profile.displayName)")
        
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 1. Extract Configuration & Tools based on Profile Type
                    let llmConfig: ProviderConfig
                    var instructions: String?
                    let rawTools: [Tool]
                    let isBotFlow: Bool
                    var skillManifests: [SkillManifest]?
                    var skillFolderPath: String?
                    
                    switch profile.details {
                    case .bot(let config):
                        llmConfig = config.llmConfig
                        instructions = config.instructions
                        rawTools = []
                        isBotFlow = true
                        skillManifests = nil
                        skillFolderPath = nil

                    case .agent(let config):
                        llmConfig = config.llmConfig
                        instructions = config.instructions
                        rawTools = config.tools
                        isBotFlow = false
                        skillManifests = config.skillConfig?.manifests.filter(\.isEnabled)
                        skillFolderPath = config.skillConfig?.folderURL.path

                    case .workflow:
                        // Workflow: each node resolves its own model, tools, and generator.
                        // Bypass the single-model pipeline entirely. Layout is the source of truth.
                        let workflowExecutor = WorkflowExecutor(workflowProfileID: profile.id)
                        let wfStream = workflowExecutor.executeWorkflow(
                            userInput: userInput,
                            chatHistory: chatHistory,
                            conversationID: conversationID,
                            ragContext: ragContext,
                            traceContext: traceContext,
                            onTraceUpdate: { log in onTraceUpdate?(log) }
                        )

                        for try await event in wfStream {
                            continuation.yield(event)
                        }
                        continuation.finish()
                        return

                    case .imageGen:
                        // ImageGen profiles are handled by BackendOrchestrationService directly.
                        // They should never reach AgentConnect.
                        continuation.yield(.error("ImageGen profiles should not be routed through AgentConnect. Use BackendOrchestrationService instead."))
                        continuation.finish()
                        return

                    case .code(let config):
                        // Code mode uses the agent pipeline with pre-configured coding tools.
                        llmConfig = config.llmConfig
                        instructions = config.instructions
                        rawTools = config.tools
                        isBotFlow = false
                        skillManifests = nil
                        skillFolderPath = nil
                        logger.info("[CODE] AgentConnect extracted Code config — provider: \(config.llmConfig.apiProvider.rawValue), model: \(config.llmConfig.modelName), tools: \(config.tools.count), projectPath: \(config.projectPath ?? "nil"), traceID: \(traceContext.traceID)")
                    }

                    // 2. Select Cognitive Strategy & Rate Limit Boundary
                    let rateLimitCategory = RateLimitCategory.from(provider: llmConfig.apiProvider)
                    let rateLimitKey = RateLimitCategory.deriveBucketKey(
                        provider: llmConfig.apiProvider,
                        apiKey: llmConfig.apiKey,
                        baseURL: llmConfig.baseURL
                    )
                    
                    // Resolve Cognitive Strategy via our 2D routing matrix
                    let generatorStrategy = try self.resolveCognitiveGenerator(
                        llmConfig: llmConfig,
                        isBotFlow: isBotFlow
                    )
                    
                    // 3. Memory & Model Initialization
                    let modelTier = llmConfig.modelMetadata?.tier ?? .medium
                    let contextWindow = max(2048, llmConfig.modelMetadata?.contextWindow
                        ?? KnownModelContextWindows.lookup(llmConfig.modelName)
                        ?? 128_000)
                    let fallbackRag = ragContext ?? "No static context provided."
                    
                    // Instantiate the correct Long-Term Memory Strategy
                    let longTermMemory: any LongTermMemoryStrategy
                    if modelTier == .tiny || modelTier == .small {
                        longTermMemory = StaticGroundingMemory(ragContext: fallbackRag)
                    } else {
                        longTermMemory = ToolAugmentedMemory(
                            ragContext: fallbackRag,
                            memoryTools: [
                                wrapTool(ReadSessionHistoryTool(conversationID: conversationID), requiresConfirmation: false)
                            ]
                        )
                    }

                    // --- UI Progress: Model initialization ---
                    switch llmConfig.apiProvider {
                    case .mlx:
                        continuation.yield(.thought("Loading local model: \(llmConfig.modelName)…"))
                    case .ollama:
                        continuation.yield(.thought("Connecting to Ollama: \(llmConfig.modelName)…"))
                    default:
                        break
                    }

                    // 4. Initialize the Language Model (before tool resolution — delegation needs the model)
                    let model = try await self.initializeModel(config: llmConfig, isBotFlow: isBotFlow)

                    // --- UI Progress: Model ready ---
                    if llmConfig.apiProvider == .mlx || llmConfig.apiProvider == .ollama {
                        continuation.yield(.thought("Model loaded. Starting execution…"))
                    }

                    // --- UI Progress: Preparing tools ---
                    continuation.yield(.thought("Preparing agent tools…"))

                    // Extract capabilities for tool injection (delegation)
                    let agentCapabilities: AgentCapabilities?
                    if case .agent(let agentConfig) = profile.details {
                        agentCapabilities = agentConfig.capabilities
                    } else {
                        agentCapabilities = nil
                    }

                    // 5. Resolve Tools (model passed for delegation tool to reuse)
                    var activeTools = await self.resolveExecutableTools(
                        profileTools: rawTools,
                        conversationID: conversationID,
                        longTermMemory: longTermMemory,
                        agentCapabilities: agentCapabilities,
                        parentModel: model,
                        generatorStrategy: generatorStrategy,
                        rateLimitKey: rateLimitKey,
                        rateLimitCategory: rateLimitCategory,
                        parentProvider: llmConfig.apiProvider,
                        skillManifests: skillManifests,
                        modelTier: modelTier
                    )

                    // 5.5 Inject `final_answer` terminator for all tool-supporting flows.
                    // Pinned to index 0 so weak local models see it first when scanning the
                    // tool schema (ordering bias is real on 7-14B models). It's the ONLY
                    // clean exit from the ReAct loop — without it, local tool-calling models
                    // emit tool calls indefinitely and trip the circuit breaker (G1).
                    //
                    // Scope: Agent / Code / Workflow profiles (all ReAct-based executors).
                    // Bot profiles are excluded — they run on ChatExecutor with no tool
                    // dispatch loop, so terminator semantics don't apply.
                    if !isBotFlow {
                        let finalAnswerTool = self.wrapTool(FinalAnswerTool(), requiresConfirmation: false)
                        activeTools.insert(finalAnswerTool, at: 0)
                    }

                    // 5.6 Code mode: inject project context tool.
                    if case .code(let codeConfig) = profile.details, let projectPath = codeConfig.projectPath {
                        let contextTool = UpdateProjectContextTool(projectPath: projectPath)
                        activeTools.append(self.wrapTool(contextTool, requiresConfirmation: false))
                        let toolNames = activeTools.map(\.name).joined(separator: ", ")
                        logger.info("[CODE] Tool resolution complete — \(activeTools.count) tools (incl. final_answer, update_project_context): [\(toolNames)]")
                    }

                    // 6. Initialize Evaluation Session (Metrics)
                    let evalSessionID = UUID()
                    if !activeTools.isEmpty {
                        EvaluationLogger.shared.startSession(id: evalSessionID, availableTools: activeTools)
                    }

                    defer {
                        if !activeTools.isEmpty {
                            _ = EvaluationLogger.shared.endSession(id: evalSessionID)
                        }
                    }

                    // NEW: Log Full Configuration Visibility
                    self.logFullConfiguration(
                        profile: profile,
                        config: llmConfig,
                        isBotFlow: isBotFlow,
                        tools: activeTools,
                        instructions: instructions
                    )
                    
                    // 6. Instantiate the Executor
                    let executor = ExecutorFactory.create(for: profile)
                    
                    logger.info("Starting execution using executor strategy: \(executor.executorLabel)")
                    
                    // 7. Prepare Input (State Injection)
                    var activeState: SessionGraph? = nil
                    var recentHistory: String? = nil
                    
                    // Provision budget-aware Working Memory Strategy
                    let memoryConfig = MemoryBudgetConfig.derive(contextWindow: contextWindow, tier: modelTier)
                    let workingMemory: any WorkingMemoryStrategy = WindowedLinearMemory(config: memoryConfig)

                    // #22: native turn-payload budget (~75% of context window as chars).
                    // Distinct from the small scratchpad budget above — the native path
                    // sends the full conversation, so it gets the larger slice; the ReAct
                    // loop compacts oldest tool exchanges past this to bound growth.
                    let nativeContextBudgetChars = max(8000, Int(Double(contextWindow) * 0.75) * 4)

                    // Resolve history strategy from profile (default: .recentHistory)
                    let historyStrategy: HistoryStrategy
                    if case .agent(let agentConfig) = profile.details {
                        historyStrategy = agentConfig.historyStrategy ?? .recentHistory
                    } else {
                        historyStrategy = .recentHistory
                    }

                    // Determine if this is a native provider (supports turn-by-turn history)
                    let isNativeProvider: Bool = {
                        switch llmConfig.apiProvider {
                        case .anthropic, .openAI, .google, .openRouter, .openAICompatible: return true
                        case .ollama: return llmConfig.cognitiveCapability != .none
                        case .mlx: return false
                        }
                    }()

                    var nativeHistoryTurns: [[String: String]]? = nil

                    // History building is independent of tool availability.
                    // Even tool-less agents benefit from conversation context.
                    var effectiveHistory = chatHistory // Mutable copy — compaction may insert a checkpoint
                    if !effectiveHistory.isEmpty {
                        let charBudget = max(4000, Int(Double(contextWindow) * 0.6) * 4) // 60% of context, ~4 chars/token, floor 4K

                        // --- IC-Powered History Compaction (Synchronous) ---
                        // Runs before history building so the current request benefits from compacted context.
                        let compactionEnabled = UserDefaults.standard.object(forKey: AppSettings.ciFeatureHistoryCompactionKey) as? Bool ?? true
                        if compactionEnabled,
                           await IntelligenceCoreService.shared.hasModelSelected {
                            do {
                                if let result = try await HistoryCompactionService.shared.compactIfNeeded(
                                    chatHistory: effectiveHistory,
                                    conversationID: conversationID,
                                    charBudget: charBudget
                                ) {
                                    continuation.yield(.compactionStarted(
                                        turnsToCompact: result.turnsCompacted,
                                        checkpointNumber: result.checkpointNumber
                                    ))

                                    // Insert checkpoint into effective history for this request.
                                    effectiveHistory.append(result.checkpointMessage)
                                    effectiveHistory.sort(by: { $0.timestamp < $1.timestamp })

                                    continuation.yield(.compactionCompleted(
                                        turnsCompacted: result.turnsCompacted,
                                        summaryPreview: result.summaryPreview
                                    ))
                                }
                            } catch {
                                logger.warning("History compaction failed: \(error.localizedDescription). Continuing without compaction.")
                            }
                        }

                        // SessionGraph tracks tool failures (Ghost Protocol) — only relevant when tools exist.
                        // Built AFTER compaction so it operates on checkpoint-aware history.
                        if !activeTools.isEmpty {
                            activeState = EpisodicHistoryFormatter.buildGraph(
                                from: effectiveHistory,
                                sessionID: conversationID.uuidString
                            )
                        }

                        // Hybrid history channel policy:
                        //   - `recentHistory` (episodic XML) → embedded in system prompt
                        //     for EVERY flow. Carries tool-execution context without
                        //     priming the model to mimic a prose tool-call format.
                        //   - `nativeHistoryTurns` (user/assistant prose pairs) → appended
                        //     as real turn pairs for native providers only. Prose-only now
                        //     (no `[Used:]` markers) so the model sees natural conversation
                        //     flow and learns tool-call structure from the in-request
                        //     iteration scratchpad alone.
                        //   - MLX (non-native): keeps `recentHistory` only, no turn pairs.
                        switch historyStrategy {
                        case .recentHistory:
                            recentHistory = EpisodicHistoryFormatter.buildRecentHistoryString(
                                from: effectiveHistory, limit: 10
                            )
                            if isNativeProvider {
                                nativeHistoryTurns = NativeHistoryConverter.buildNativeTurns(
                                    from: effectiveHistory, limit: 10, charBudget: charBudget
                                )
                            }
                        case .fullHistory:
                            recentHistory = EpisodicHistoryFormatter.buildRecentHistoryString(
                                from: effectiveHistory, limit: effectiveHistory.count
                            )
                            if isNativeProvider {
                                nativeHistoryTurns = NativeHistoryConverter.buildNativeTurns(
                                    from: effectiveHistory, limit: nil, charBudget: charBudget
                                )
                            }

                        case .pointer:
                            recentHistory = EpisodicHistoryFormatter.buildPointerHistoryString(
                                from: effectiveHistory
                            )
                            if isNativeProvider {
                                nativeHistoryTurns = NativeHistoryConverter.buildPointerTurns(
                                    from: effectiveHistory
                                )
                            }

                        case .hybrid:
                            recentHistory = EpisodicHistoryFormatter.buildHybridHistoryString(
                                from: effectiveHistory, inlineCount: 3
                            )
                            if isNativeProvider {
                                nativeHistoryTurns = NativeHistoryConverter.buildHybridTurns(
                                    from: effectiveHistory, inlineCount: 3, charBudget: charBudget
                                )
                            }
                        }

                        // Only inject get_conversation_history tool if pointer references
                        // were actually emitted in the built history. This avoids a dead tool
                        // when history is too short for pointers (e.g. hybrid with <= 3 turns).
                        let hasPointers: Bool = {
                            if let turns = nativeHistoryTurns {
                                return turns.contains { $0["content"]?.contains("get_conversation_history(") == true }
                            }
                            return recentHistory?.contains("get_conversation_history(") == true
                        }()

                        if hasPointers {
                            activeTools.append(
                                wrapTool(ConversationHistoryTool(chatHistory: effectiveHistory), requiresConfirmation: false)
                            )
                        }
                    }
                    
                    // Extract resilience config from agent profile
                    let retryPolicy: RetryPolicy
                    let errorRecovery: ErrorRecovery
                    let resilienceOverrides: ResilienceOverrides?
                    if case .agent(let agentConfig) = profile.details {
                        retryPolicy = agentConfig.retryPolicy ?? RetryPolicy()
                        errorRecovery = agentConfig.errorRecovery ?? ErrorRecovery()
                        resilienceOverrides = agentConfig.resilienceOverrides
                    } else {
                        retryPolicy = RetryPolicy()
                        errorRecovery = ErrorRecovery()
                        resilienceOverrides = nil
                    }

                    // Resolve the three-tier resilience policy ONCE, here, where the
                    // provider class is known. Transport budgets are provider-derived
                    // (cloud: bounded patience; Ollama: connection-refused is fatal
                    // with guidance; MLX: fast-fail); cognitive/loop caps take the
                    // user's per-tier overrides, falling back to the legacy RetryPolicy.
                    let resiliencePolicy = ResolvedResiliencePolicy.resolved(
                        for: ProviderClass(apiProvider: llmConfig.apiProvider),
                        overrides: resilienceOverrides,
                        legacy: retryPolicy,
                        endpointHint: llmConfig.baseURL
                    )

                    // Resolve IC-powered response synthesis.
                    // Global toggle from Core Intelligence settings, gated on IC availability.
                    let icAvailable = await IntelligenceCoreService.shared.hasModelSelected
                    let icEnabled = UserDefaults.standard.bool(forKey: AppSettings.isIntelligenceCoreEnabledKey)
                    let synthToggle = UserDefaults.standard.bool(forKey: AppSettings.ciFeatureResponseSynthesisKey)
                    let responseSynthesisEnabled = icAvailable && icEnabled && synthToggle

                    let input = AgentInput(
                        userInput: userInput,
                        userPayload: userPayload,
                        chatHistory: chatHistory,
                        conversationID: conversationID,
                        tools: activeTools,
                        longTermMemory: longTermMemory,
                        activeState: activeState,
                        recentHistory: recentHistory,
                        generatorStrategy: generatorStrategy,
                        workingMemory: workingMemory,
                        rateLimitKey: rateLimitKey,
                        rateLimitCategory: rateLimitCategory,
                        instructions: instructions,
                        skillManifests: skillManifests,
                        skillFolderPath: skillFolderPath,
                        retryPolicy: retryPolicy,
                        errorRecovery: errorRecovery,
                        resiliencePolicy: resiliencePolicy,
                        responseSynthesisEnabled: responseSynthesisEnabled,
                        nativeHistoryTurns: nativeHistoryTurns,
                        resumeState: resumeState,
                        traceContext: traceContext,
                        modelTier: llmConfig.modelMetadata?.tier,
                        nativeContextBudgetChars: nativeContextBudgetChars
                    )

                    // 8. Execute & Stream
                    let traceHandler: @Sendable (AgentTraceLog) -> Void = { log in
                        logger.debug("[\(log.state.headline)] \(log.content) (span: \(log.spanID))")
                        if !activeTools.isEmpty {
                            EvaluationLogger.shared.logStep(id: evalSessionID, log: log)
                        }
                        onTraceUpdate?(log)
                    }
                    
                    try Task.checkCancellation()

                    // Extract execution timeout from agent config
                    let executionTimeout: TimeInterval?
                    if case .agent(let agentConfig) = profile.details {
                        executionTimeout = agentConfig.executionTimeout
                    } else {
                        executionTimeout = nil
                    }

                    if case .code = profile.details {
                        logger.info("[CODE] Executor handoff — executor: \(executor.executorLabel), traceID: \(traceContext.traceID), spanID: \(traceContext.spanID), conversationID: \(conversationID.uuidString.prefix(8))")
                    }

                    let stream = executor.execute(model: model, input: input, onTraceUpdate: traceHandler)

                    let finalOutputAccumulator: String

                    if let timeout = executionTimeout {
                        // Enforce execution timeout via Task race.
                        // The typed TaskGroup returns the accumulated output from whichever
                        // task completes first, avoiding shared mutable state across tasks.
                        finalOutputAccumulator = try await withThrowingTaskGroup(of: String.self) { group in
                            // Timeout sentinel
                            group.addTask {
                                try await Task.sleep(for: .seconds(timeout))
                                throw AgentExecutionError(reason: .executionTimeout(
                                    elapsed: timeout,
                                    limit: timeout
                                ))
                            }
                            // Actual execution — accumulates output and returns it
                            group.addTask {
                                var accumulated = ""
                                for try await event in stream {
                                    if case .content(let chunk) = event {
                                        accumulated += chunk
                                    }
                                    continuation.yield(event)
                                }
                                return accumulated
                            }
                            // First to finish (or throw) wins; cancel the other
                            let result = try await group.next() ?? ""
                            group.cancelAll()
                            return result
                        }
                    } else {
                        var accumulated = ""
                        for try await event in stream {
                            if case .content(let chunk) = event {
                                accumulated += chunk
                            }
                            continuation.yield(event)
                        }
                        finalOutputAccumulator = accumulated
                    }
                    
                    let outputPreview = String(finalOutputAccumulator.prefix(200))
                    logger.info("--- TEXTGEN RESPONSE COMPLETE --- traceID: \(traceContext.traceID), model: \(llmConfig.modelName), outputLen: \(finalOutputAccumulator.count)")
                    logger.debug("Output preview: \(outputPreview)")
                    
                    continuation.finish()
                    
                } catch is CancellationError {
                    logger.info("AgentConnect Stream Cancelled.")
                    continuation.finish()
                } catch {
                    logger.error("Unified Stream Error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
    
    // MARK: - Workflow Node Streaming

    /// Workflow-aware streaming that bypasses RAG, history, compaction, and episode management.
    /// Uses the same generator/parser the agent or bot path would — workflow specifics
    /// are applied via `SemanticContext.workflowContext`, which `buildStandardMessages`
    /// reads to derive the per-node user-message prefix and force `.workflow` layer
    /// config. Any improvement to a dialect's generator, parser, or native tool
    /// injection is inherited automatically.
    func streamWorkflowNodeResponse(
        for profile: BackendProfileModel,
        workflowContext: WorkflowExecutionContext,
        conversationID: UUID,
        traceContext: TraceContext,
        onTraceUpdate: (@Sendable (AgentTraceLog) -> Void)? = nil
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {

        logger.info("[Workflow] Node stream: profile='\(profile.displayName)' type=\(profile.profileType.rawValue) node='\(workflowContext.nodeName)'")

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 1. Extract profile config (same switch as streamAgentResponse lines 54-96)
                    let llmConfig: ProviderConfig
                    var instructions: String?
                    let rawTools: [Tool]
                    let isBotFlow: Bool
                    var skillManifests: [SkillManifest]?
                    var skillFolderPath: String?

                    switch profile.details {
                    case .bot(let config):
                        llmConfig = config.llmConfig
                        instructions = config.instructions
                        rawTools = []
                        isBotFlow = true
                        skillManifests = nil
                        skillFolderPath = nil

                    case .agent(let config):
                        llmConfig = config.llmConfig
                        instructions = config.instructions
                        rawTools = config.tools
                        isBotFlow = false
                        skillManifests = config.skillConfig?.manifests.filter(\.isEnabled)
                        skillFolderPath = config.skillConfig?.folderURL.path

                    case .code(let config):
                        llmConfig = config.llmConfig
                        instructions = config.instructions
                        rawTools = config.tools
                        isBotFlow = false
                        skillManifests = nil
                        skillFolderPath = nil

                    case .workflow, .imageGen:
                        continuation.yield(.error("Unsupported profile type for workflow node: \(profile.profileType.rawValue)"))
                        continuation.finish()
                        return
                    }

                    logger.info("[Workflow] Pipeline: skipping RAG, history, compaction, episode management")

                    // 2. Resolve generator strategy (dialect-specific).
                    //
                    // No workflow-specific wrapper: workflow behavior is applied via
                    // `SemanticContext.workflowContext` (set by the executor below),
                    // which `buildStandardMessages` reads to:
                    //   • force `PromptLayerConfig.workflow` (skip RAG/episodic/profile)
                    //   • derive the per-node user-message prefix
                    // Each dialect's own generator handles its native tool injection,
                    // trigger suffix, response schema, and parser — so workflow
                    // automatically inherits every agent/bot improvement.
                    let generator = try self.resolveCognitiveGenerator(
                        llmConfig: llmConfig,
                        isBotFlow: isBotFlow
                    )

                    // 3. Initialize model
                    let model = try await self.initializeModel(config: llmConfig, isBotFlow: isBotFlow)

                    // 6. Resolve tools (still needed for agent nodes)
                    let longTermMemory: any LongTermMemoryStrategy = StaticGroundingMemory(ragContext: "")
                    let agentCapabilities: AgentCapabilities? = {
                        if case .agent(let config) = profile.details { return config.capabilities }
                        return nil
                    }()

                    let rateLimitCategory = RateLimitCategory.from(provider: llmConfig.apiProvider)
                    let rateLimitKey = RateLimitCategory.deriveBucketKey(
                        provider: llmConfig.apiProvider,
                        apiKey: llmConfig.apiKey,
                        baseURL: llmConfig.baseURL
                    )

                    var activeTools = await self.resolveExecutableTools(
                        profileTools: rawTools,
                        conversationID: conversationID,
                        longTermMemory: longTermMemory,
                        agentCapabilities: agentCapabilities,
                        parentModel: model,
                        generatorStrategy: generator,
                        rateLimitKey: rateLimitKey,
                        rateLimitCategory: rateLimitCategory,
                        parentProvider: llmConfig.apiProvider,
                        skillManifests: skillManifests,
                        modelTier: llmConfig.modelMetadata?.tier ?? .medium
                    )

                    // 6.5 Inject `final_answer` terminator for workflow nodes that run on
                    // ReAct (agent/code profiles). Mirrors the streaming chat path —
                    // workflow node output relies on `finalAgentThought`, which is
                    // populated cleanly when the model calls `final_answer`.
                    if !isBotFlow {
                        let finalAnswerTool = self.wrapTool(FinalAnswerTool(), requiresConfirmation: false)
                        activeTools.insert(finalAnswerTool, at: 0)
                    }

                    // 7. Build AgentInput — workflow-aware, no history/RAG/compaction
                    // taskDescription contains the merged user query for first nodes.
                    // For downstream nodes, upstreamInput is the primary data.
                    let userInputForNode = workflowContext.isFirstNode
                        ? workflowContext.taskDescription
                        : workflowContext.upstreamInput

                    let contextWindow = max(2048, llmConfig.modelMetadata?.contextWindow
                        ?? KnownModelContextWindows.lookup(llmConfig.modelName)
                        ?? 128_000)
                    let modelTier = llmConfig.modelMetadata?.tier ?? .medium
                    let memoryConfig = MemoryBudgetConfig.derive(contextWindow: contextWindow, tier: modelTier)
                    // #22: native turn-payload budget (~75% of context window as chars) —
                    // bounds liveConversationTurns growth on workflow agent nodes too.
                    let nativeContextBudgetChars = max(8000, Int(Double(contextWindow) * 0.75) * 4)

                    // Resilience config
                    let retryPolicy: RetryPolicy
                    let errorRecovery: ErrorRecovery
                    let resilienceOverrides: ResilienceOverrides?
                    if case .agent(let agentConfig) = profile.details {
                        retryPolicy = agentConfig.retryPolicy ?? RetryPolicy()
                        errorRecovery = agentConfig.errorRecovery ?? ErrorRecovery()
                        resilienceOverrides = agentConfig.resilienceOverrides
                    } else {
                        retryPolicy = RetryPolicy()
                        errorRecovery = ErrorRecovery()
                        resilienceOverrides = nil
                    }

                    // Image payload (Phase 3): upstream image artifacts become native
                    // image blocks so vision-capable bot nodes "see" them. Reference-
                    // backed — the provider resolves+encodes at send time (a failed
                    // resolve throws there and fails the node, never a silent drop).
                    let workflowImagePayload: Payload? = {
                        let imageArtifacts = workflowContext.upstreamArtifacts.filter { $0.kind == .image }
                        guard !imageArtifacts.isEmpty else { return nil }
                        return imageArtifacts.map { .image(ImagePayload(reference: $0.reference, mimeType: $0.mimeType, alt: $0.label)) }
                    }()

                    let input = AgentInput(
                        userInput: userInputForNode,
                        userPayload: workflowImagePayload,
                        chatHistory: [],
                        conversationID: conversationID,
                        tools: activeTools,
                        longTermMemory: longTermMemory,
                        recentHistory: nil,
                        generatorStrategy: generator,
                        workingMemory: WindowedLinearMemory(config: memoryConfig),
                        rateLimitKey: rateLimitKey,
                        rateLimitCategory: rateLimitCategory,
                        instructions: instructions,
                        skillManifests: skillManifests,
                        skillFolderPath: skillFolderPath,
                        retryPolicy: retryPolicy,
                        errorRecovery: errorRecovery,
                        resiliencePolicy: ResolvedResiliencePolicy.resolved(
                            for: ProviderClass(apiProvider: llmConfig.apiProvider),
                            overrides: resilienceOverrides,
                            legacy: retryPolicy,
                            endpointHint: llmConfig.baseURL
                        ),
                        responseSynthesisEnabled: false,
                        nativeHistoryTurns: nil,
                        suppressEpisodeManagement: true,
                        workflowContext: workflowContext,
                        traceContext: traceContext,
                        modelTier: llmConfig.modelMetadata?.tier,
                        nativeContextBudgetChars: nativeContextBudgetChars
                    )

                    logger.info("[Workflow] AgentInput: tools=\(activeTools.count), generator=\(type(of: generator)), node='\(workflowContext.nodeName)'")

                    // 8. Execute
                    let executor = ExecutorFactory.create(for: profile)
                    logger.info("[Workflow] Executor: \(executor.executorLabel) for '\(workflowContext.nodeName)'")

                    let traceHandler: @Sendable (AgentTraceLog) -> Void = { log in
                        onTraceUpdate?(log)
                    }

                    try Task.checkCancellation()

                    let stream = executor.execute(model: model, input: input, onTraceUpdate: traceHandler)

                    for try await event in stream {
                        continuation.yield(event)
                    }

                    continuation.finish()

                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    logger.error("[Workflow] Node '\(workflowContext.nodeName)' stream error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Cognitive Strategy Resolution
    
    /// Evaluates the model configuration and isolates the routing logic for the generator.
    private func resolveCognitiveGenerator(
        llmConfig: ProviderConfig,
        isBotFlow: Bool
    ) throws -> any CognitiveGenerator {
        
        switch llmConfig.apiProvider {
        // NOTE (register #1): the cloud arms intentionally have NO pre-flight
        // chat-only guard. `cognitiveCapability` is populated only by the LOCAL
        // analyzers (Ollama /api/show, MLXTokenizerAnalyzer) — cloud model
        // selection leaves it at the default `.none`, so guarding on it here
        // would 405 every existing cloud profile. The runtime guard lives in
        // ProviderErrorClassifier.classify(statusCode:rawBody:): a 400/422 whose
        // body rejects tool definitions classifies fatal with an actionable
        // "doesn't support tool calling" message. The silent-ignore shape
        // (endpoint accepts `tools` but the model never calls one) is the
        // register-#3 zero-tool-call detector, tracked separately.
        case .anthropic:
            return NativeStructuredGenerator(
                toolAdapter: ClaudeToolSchemaAdapter(),
                toolTurnAdapter: ClaudeToolTurnAdapter()
            )

        case .google:
            return NativeStructuredGenerator(
                toolAdapter: GeminiToolSchemaAdapter(),
                toolTurnAdapter: GeminiToolTurnAdapter()
            )

        case .openAI, .openRouter, .openAICompatible:
            // OpenRouter and custom OpenAI-compatible endpoints speak the OpenAI
            // chat schema, so they share the OpenAI tool encoding and native turn
            // adapter.
            return NativeStructuredGenerator(
                toolAdapter: NativeJSONSchemaAdapter(),
                toolTurnAdapter: OpenAIToolTurnAdapter()
            )

        case .mlx, .ollama:
            let cognitiveProfile = llmConfig.cognitiveProfile
            
            // Primary Routing Dimension: Structural Capability
            switch cognitiveProfile.capability {
            case .none:
                // Strictly prevent chat-only models from ever executing inside an Agent loop
                if !isBotFlow {
                    throw NSError(
                        domain: "AgentConnect",
                        code: 405,
                        userInfo: [NSLocalizedDescriptionKey: "The selected model (\(llmConfig.modelName)) is a conversational model and lacks the cognitive capabilities required for Agent tasks. Please switch to a Bot profile or select a tool-capable model."]
                    )
                }
                return JsonStructuredGenerator()
                
            case .singleAction:
                // Secondary Dimension: Dialect matching for single-action text constraints.
                // Default is ReAct Markdown — the most universal format for weak/unknown models
                // that have basic tool awareness but no proven structured-output training.
                switch cognitiveProfile.dialect {
                case .mistralXML:
                    return XMLStructuredGenerator()
                default:
                    return MarkdownStructuredGenerator()
                }
                
            case .parallelActions:
                // Ollama: API layer abstracts the model's native format — always use NativeStructuredGenerator.
                // MLX: No intermediary API — must match the model's trained output dialect via chat_template.
                //
                // Native-template dialects all share one generator (NativeToolTemplateGenerator)
                // parameterized by `(expectedDialect, triggerSuffix, logTag)`. The dialect-specific
                // parsing lives in the parser (routed via CognitiveParsePipeline).
                if llmConfig.apiProvider == .mlx {
                    switch cognitiveProfile.dialect {
                    case .qwenHermesToolCall:
                        logger.info("🧩 Resolved Generator Strategy: NativeToolTemplateGenerator[QwenHermes] for model: \(llmConfig.modelName)")
                        return NativeToolTemplateGenerator.qwenHermes()

                    case .llama3JsonSingle:
                        logger.info("🧩 Resolved Generator Strategy: NativeToolTemplateGenerator[Llama3] for model: \(llmConfig.modelName)")
                        return NativeToolTemplateGenerator.llama3Json()

                    case .mistralV3Array:
                        logger.info("🧩 Resolved Generator Strategy: NativeToolTemplateGenerator[MistralV3] for model: \(llmConfig.modelName)")
                        return NativeToolTemplateGenerator.mistralV3()

                    case .mistralV11Flat:
                        logger.info("🧩 Resolved Generator Strategy: NativeToolTemplateGenerator[MistralV11] for model: \(llmConfig.modelName)")
                        return NativeToolTemplateGenerator.mistralV11()

                    case .phiFunctoolsBracket:
                        logger.info("🧩 Resolved Generator Strategy: NativeToolTemplateGenerator[PhiFunctools] for model: \(llmConfig.modelName)")
                        return NativeToolTemplateGenerator.phiFunctools()

                    case .deepseekV3JsonFence:
                        logger.info("🧩 Resolved Generator Strategy: NativeToolTemplateGenerator[DeepSeekV3] for model: \(llmConfig.modelName)")
                        return NativeToolTemplateGenerator.deepseekV3()

                    case .pythonicBracketList:
                        logger.info("🧩 Resolved Generator Strategy: NativeToolTemplateGenerator[Pythonic] for model: \(llmConfig.modelName)")
                        return NativeToolTemplateGenerator.pythonic()

                    case .graniteLegacyArray:
                        logger.info("🧩 Resolved Generator Strategy: NativeToolTemplateGenerator[GraniteLegacy] for model: \(llmConfig.modelName)")
                        return NativeToolTemplateGenerator.graniteLegacy()

                    case .granite4ToolCall:
                        logger.info("🧩 Resolved Generator Strategy: NativeToolTemplateGenerator[Granite4] for model: \(llmConfig.modelName)")
                        return NativeToolTemplateGenerator.granite4()

                    case .commandRAction:
                        logger.info("🧩 Resolved Generator Strategy: NativeToolTemplateGenerator[CommandR] for model: \(llmConfig.modelName)")
                        return NativeToolTemplateGenerator.commandR()

                    case .commandR7BAction:
                        logger.info("🧩 Resolved Generator Strategy: NativeToolTemplateGenerator[CommandR7B] for model: \(llmConfig.modelName)")
                        return NativeToolTemplateGenerator.commandR7B()

                    case .qwen3CoderDeepXml:
                        logger.info("🧩 Resolved Generator Strategy: NativeToolTemplateGenerator[Qwen3Coder] for model: \(llmConfig.modelName)")
                        return NativeToolTemplateGenerator.qwen3Coder()

                    case .deepseekV31Flat:
                        logger.info("🧩 Resolved Generator Strategy: NativeToolTemplateGenerator[DeepSeekV31] for model: \(llmConfig.modelName)")
                        return NativeToolTemplateGenerator.deepseekV31()

                    case .deepseekV32Dsml:
                        logger.info("🧩 Resolved Generator Strategy: NativeToolTemplateGenerator[DeepSeekV32] for model: \(llmConfig.modelName)")
                        return NativeToolTemplateGenerator.deepseekV32()

                    case .mistralXML:
                        // Legacy hybrid-XML path — pre-dates the native-template refactor.
                        // Retained for models misclassified as mistralXML before the fingerprinter
                        // could route them more precisely. Emits <tool_call><content>/<tool_name>/<arguments>.
                        logger.info("🧩 Resolved Generator Strategy: XMLNativeStructuredGenerator for model: \(llmConfig.modelName)")
                        return XMLNativeStructuredGenerator()

                    case .nativeJSON, .heuristicJson, .reactMarkdown:
                        // Models without a native chat_template tools branch — use prompt-injection.
                        logger.info("🧩 Resolved Generator Strategy: MLXNativeStructuredGenerator for model: \(llmConfig.modelName)")
                        return MLXNativeStructuredGenerator()
                    }
                } else {
                    // Ollama-native path uses the Ollama-shaped turn adapter (dict args).
                    logger.info("🧩 Resolved Generator Strategy: NativeStructuredGenerator for model: \(llmConfig.modelName)")
                    return NativeStructuredGenerator(
                        toolAdapter: NativeJSONSchemaAdapter(),
                        toolTurnAdapter: OllamaToolTurnAdapter()
                    )
                }
            }
        }
    }
    
    // MARK: - Model Initialization
    
    func initializeModel(config llmConfig: ProviderConfig, isBotFlow: Bool) async throws -> any LLMProvider {
        let rlKey = RateLimitCategory.deriveBucketKey(
            provider: llmConfig.apiProvider,
            apiKey: llmConfig.apiKey,
            baseURL: llmConfig.baseURL
        )

        switch llmConfig.apiProvider {
        case .anthropic:
            guard let apiKey = llmConfig.apiKey, !apiKey.isEmpty else {
                throw NSError(domain: "AgentConnect", code: 401, userInfo: [NSLocalizedDescriptionKey: "Anthropic API Key is required."])
            }
            let baseURL: URL
            if let baseURLString = llmConfig.baseURL {
                guard let parsed = URL(string: baseURLString) else {
                    throw NSError(domain: "AgentConnect", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Anthropic Base URL: \(baseURLString)"])
                }
                baseURL = parsed
            } else {
                baseURL = ProviderDefaults.anthropicBaseURL
            }
            var options: [String: JSONValue]? = nil
            if let advConfig = llmConfig.advancedConfiguration {
                options = advConfig
            }
            let config = LLMProviderConfig(apiKey: apiKey, baseURL: baseURL, modelName: llmConfig.modelName, timeout: 300.0, options: options, rateLimitKey: rlKey)
            return ClaudeLLMProvider(config: config)
            
        case .ollama:
            let baseURLString = llmConfig.baseURL ?? ProviderDefaults.ollamaBaseURL.absoluteString
            guard let baseURL = URL(string: baseURLString) else {
                throw NSError(domain: "AgentConnect", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Base URL: \(baseURLString)"])
            }
            
            // Extract options for Ollama
            var options: [String: JSONValue]? = nil
            if let advConfig = llmConfig.advancedConfiguration {
                options = advConfig
            }
            
            let config = LLMProviderConfig(baseURL: baseURL, modelName: llmConfig.modelName, timeout: 300.0, options: options, rateLimitKey: rlKey, thinkingEnabled: llmConfig.thinkingEnabled)
            return OllamaLLMProvider(config: config)
            
        case .openAI:
            guard let apiKey = llmConfig.apiKey, !apiKey.isEmpty else {
                throw NSError(domain: "AgentConnect", code: 401, userInfo: [NSLocalizedDescriptionKey: "OpenAI API Key is required."])
            }
            let baseURL: URL
            if let baseURLString = llmConfig.baseURL {
                guard let parsed = URL(string: baseURLString) else {
                    throw NSError(domain: "AgentConnect", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid OpenAI Base URL: \(baseURLString)"])
                }
                baseURL = parsed
            } else {
                baseURL = ProviderDefaults.openAIBaseURL
            }
            var options: [String: JSONValue]? = nil
            if let advConfig = llmConfig.advancedConfiguration {
                options = advConfig
            }
            let config = LLMProviderConfig(apiKey: apiKey, baseURL: baseURL, modelName: llmConfig.modelName, timeout: 300.0, options: options, rateLimitKey: rlKey)
            return OpenAILLMProvider(config: config)

        case .openRouter:
            guard let apiKey = llmConfig.apiKey, !apiKey.isEmpty else {
                throw NSError(domain: "AgentConnect", code: 401, userInfo: [NSLocalizedDescriptionKey: "OpenRouter API Key is required."])
            }
            let baseURL: URL
            if let baseURLString = llmConfig.baseURL {
                guard let parsed = URL(string: baseURLString) else {
                    throw NSError(domain: "AgentConnect", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid OpenRouter Base URL: \(baseURLString)"])
                }
                baseURL = parsed
            } else {
                baseURL = ProviderDefaults.openRouterBaseURL
            }
            var options: [String: JSONValue]? = nil
            if let advConfig = llmConfig.advancedConfiguration {
                options = advConfig
            }
            let config = LLMProviderConfig(
                apiKey: apiKey,
                baseURL: baseURL,
                modelName: llmConfig.modelName,
                timeout: 300.0,
                options: options,
                rateLimitKey: rlKey,
                // Optional OpenRouter attribution. HTTP-Referer is omitted until the
                // app has a public homepage to point at.
                extraHeaders: ["X-Title": "Devgentic"]
            )
            return OpenAILLMProvider(config: config, providerCategory: .openRouter)

        case .openAICompatible:
            // Any OpenAI-compatible endpoint (LM Studio, vLLM, llama.cpp server,
            // Groq, DeepSeek, …). Base URL is REQUIRED (no canonical default);
            // the API key is OPTIONAL (local servers usually need none — a nil
            // key simply omits the Authorization header in OpenAILLMProvider).
            guard let baseURLString = llmConfig.baseURL,
                  !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let baseURL = URL(string: baseURLString) else {
                throw NSError(domain: "AgentConnect", code: 400, userInfo: [NSLocalizedDescriptionKey: "A valid Base URL is required for an OpenAI-Compatible provider (e.g. http://localhost:1234/v1)."])
            }
            var options: [String: JSONValue]? = nil
            if let advConfig = llmConfig.advancedConfiguration {
                options = advConfig
            }
            let config = LLMProviderConfig(
                apiKey: llmConfig.apiKey,
                baseURL: baseURL,
                modelName: llmConfig.modelName,
                timeout: 300.0,
                options: options,
                rateLimitKey: rlKey
            )
            return OpenAILLMProvider(config: config, providerCategory: .openAICompatible)

        case .google:
            guard let apiKey = llmConfig.apiKey, !apiKey.isEmpty else {
                throw NSError(domain: "AgentConnect", code: 401, userInfo: [NSLocalizedDescriptionKey: "Gemini API Key is required."])
            }

            // Use native Gemini endpoint exclusively to prevent 429 schema compatibility errors
            let googleBaseURL = ProviderDefaults.geminiBaseURL.appendingPathComponent("models/\(llmConfig.modelName)")
            var options: [String: JSONValue]? = nil
            if let advConfig = llmConfig.advancedConfiguration {
                options = advConfig
            }
            let config = LLMProviderConfig(apiKey: apiKey, baseURL: googleBaseURL, modelName: llmConfig.modelName, timeout: 300.0, options: options, rateLimitKey: rlKey)
            return GeminiLLMProvider(config: config)
            
        case .mlx:
            let modelName = llmConfig.modelName
            let modelPath: URL? = await MainActor.run {
                if MLXModelService.shared.installedModels.isEmpty {
                    MLXModelService.shared.refreshInstalledModels()
                }
                return MLXModelService.shared.installedModels.first(where: { $0.displayName == modelName })?.localPath
            }
            guard let path = modelPath else {
                throw NSError(domain: "AgentConnect", code: 404, userInfo: [NSLocalizedDescriptionKey: "Local MLX model '\(modelName)' not found."])
            }
            try await MLXService.shared.loadModel(from: path)

            // Decode MLX advanced parameters from the stored configuration.
            // If the user hasn't customized settings, use model-aware recommended defaults
            // based on tier and quantization (e.g., 3-bit models get stronger repetition penalty).
            let mlxConfig: MLXAdvancedConfig = {
                if let advDict = llmConfig.advancedConfiguration {
                    let rawDict = advDict.mapValues { $0.rawValue }
                    if let data = try? JSONSerialization.data(withJSONObject: rawDict),
                       let decoded = try? JSONDecoder().decode(MLXAdvancedConfig.self, from: data) {
                        return decoded
                    }
                }
                // No user override — use dynamic defaults tuned to model characteristics
                if let metadata = llmConfig.cognitiveProfile.metadata {
                    return .recommended(for: metadata)
                }
                return .default()
            }()

            return MLXLLMProvider(
                modelName: modelName,
                dialect: llmConfig.cognitiveProfile.dialect,
                chatTemplateSource: llmConfig.cognitiveProfile.chatTemplateSource,
                stopSequences: llmConfig.cognitiveProfile.stopSequences,
                advancedConfig: mlxConfig
            )
        }
    }
    
    // MARK: - Tool Resolution
    
    private func resolveExecutableTools(
        profileTools: [Tool],
        conversationID: UUID,
        longTermMemory: any LongTermMemoryStrategy,
        agentCapabilities: AgentCapabilities? = nil,
        parentModel: (any LLMProvider)? = nil,
        generatorStrategy: (any CognitiveGenerator)? = nil,
        rateLimitKey: String? = nil,
        rateLimitCategory: RateLimitCategory? = nil,
        parentProvider: ApiProvider? = nil,
        skillManifests: [SkillManifest]? = nil,
        modelTier: ModelTier = .medium
    ) async -> [AgentTool] {

        var activeTools: [AgentTool] = []

        // -----------------------------------------------------------------
        // 1. Core System Tools (Inherently Safe & Required for ALL models)
        // -----------------------------------------------------------------
        // Note: VectorSearchTool (recall_conversation_history) was removed here.
        // It was redundant — the same HNSW vector store is already queried by the
        // RAG pipeline pre-request (contextualRAG / directInjection), and recent
        // turns are auto-injected via EpisodicHistoryFormatter XML. Keeping the
        // tool wasted a tool slot and caused small models to call it reflexively.
        // Small/tiny local models fumble the optional `options`/`multiline` fields (truncating the
        // question to dump content into options, emitting `multiline` as a string), so advertise only
        // `question` to them. Capable models keep the richer one-tap-choices schema.
        let askUserRichFields = !(modelTier == .small || modelTier == .tiny)
        activeTools.append(wrapTool(AskUserTool(richFields: askUserRichFields), requiresConfirmation: false))

        // -----------------------------------------------------------------
        // 2. Deep Episodic Memory (Delegated to Strategy)
        // -----------------------------------------------------------------
        activeTools.append(contentsOf: longTermMemory.memoryCapabilities)

        // -----------------------------------------------------------------
        // 2.5. Skill Loading Tool (conditional — only when skills are configured)
        // -----------------------------------------------------------------
        if let manifests = skillManifests, !manifests.isEmpty {
            let loadSkillTool = LoadSkillTool(manifests: manifests)
            activeTools.append(wrapTool(loadSkillTool, requiresConfirmation: false))
            logger.info("Registered load_skill tool with \(manifests.count) available skill(s)")
        }

        // -----------------------------------------------------------------
        // 3. User-Configured / External Tools (Standard resolution)
        // -----------------------------------------------------------------
        let allToolSources = await UnifiedToolStore.shared.sources

        for toolConfig in profileTools where toolConfig.isEnabled {
            if let agentTool = self.resolveNativeTool(toolName: toolConfig.name, conversationID: conversationID, requiresConfirmation: toolConfig.requiresConfirmation, timeout: toolConfig.timeout, timeoutMessage: toolConfig.timeoutMessage) {
                activeTools.append(agentTool)
                logger.debug("Enabled Native Tool: \(toolConfig.name)")
            } else if let agentTool = self.resolveMCPTool(toolConfig: toolConfig, availableSources: allToolSources) {
                activeTools.append(agentTool)
                logger.debug("Enabled MCP Tool: \(toolConfig.name)")
            } else {
                logger.warning("Failed to resolve tool: \(toolConfig.name)")
            }
        }

        // -----------------------------------------------------------------
        // 4. Agent Delegation Tool (when capability is ON)
        // -----------------------------------------------------------------
        if let delegation = agentCapabilities?.agentDelegation,
           let model = parentModel,
           let generator = generatorStrategy,
           let rlKey = rateLimitKey,
           let rateLimit = rateLimitCategory,
           let provider = parentProvider {
            let callAgentTool = CallAgentTool.create(
                config: delegation,
                parentModel: model,
                parentTools: activeTools,
                parentGeneratorStrategy: generator,
                parentRateLimitKey: rlKey,
                parentRateLimitCategory: rateLimit,
                parentProvider: provider,
                conversationID: conversationID
            )
            activeTools.append(callAgentTool)
            logger.debug("Enabled call_agent delegation tool (max \(delegation.maxConcurrentAgents) concurrent)")
        }

        return activeTools
    }
    
    // MARK: - Tool Wrapping
    
    /// Wraps a concrete DevgenticTool into an AgentTool with type-erased execution closure.
    private func wrapTool<T: DevgenticTool>(_ tool: T, requiresConfirmation: Bool, timeout: TimeInterval? = nil, timeoutMessage: String? = nil) -> AgentTool {
        let toolName = tool.name
        let requiredKeys = tool.parameterSchema.required

        return AgentTool(
            name: tool.name,
            description: tool.description,
            parameters: tool.parameterSchema,
            requiresConfirmation: requiresConfirmation,
            timeout: timeout,
            timeoutMessage: timeoutMessage,
            contentMayLookLikeError: tool.outputMayContainErrorText
        ) { dataArgs in
            let args: T.Arguments
            do {
                args = try JSONDecoder().decode(T.Arguments.self, from: dataArgs)
            } catch let decodingError as DecodingError {
                let paramHint = requiredKeys.isEmpty ? "" : " Required parameters: [\(requiredKeys.joined(separator: ", "))]."
                let rawJSON = String(data: dataArgs, encoding: .utf8) ?? "{}"

                logToolExecution.error("❌ Tool Argument Decoding Failed. Tool: \(toolName). Expected Keys: \(requiredKeys). Raw Payload: \(rawJSON). Error: \(decodingError.localizedDescription)")

                throw ToolArgumentError(
                    toolName: toolName,
                    detail: "Argument decoding failed for '\(toolName)'.\(paramHint) Received: \(rawJSON). Underlying: \(decodingError.localizedDescription)"
                )
            }
            return try await tool.execute(arguments: args)
        }
    }
    
    /// OVERLOAD: Wraps an already-constructed `AgentTool` (like MCP tools).
    /// Resolves the Swift compiler's generic type inference failures for external tool protocols.
    private func wrapTool(_ tool: AgentTool, requiresConfirmation: Bool, timeout: TimeInterval? = nil, timeoutMessage: String? = nil) -> AgentTool {
        return AgentTool(
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters,
            requiresConfirmation: requiresConfirmation,
            timeout: timeout,
            timeoutMessage: timeoutMessage,
            contentMayLookLikeError: tool.contentMayLookLikeError,
            run: tool.run
        )
    }
    
    // MARK: - Native Tool Resolution
    
    func resolveNativeTool(toolName: String, conversationID: UUID, requiresConfirmation: Bool, timeout: TimeInterval? = nil, timeoutMessage: String? = nil) -> AgentTool? {
        switch toolName {
        case "list_directory": return wrapTool(ListDirectoryTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "read_file": return wrapTool(ReadFileTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "write_file": return wrapTool(WriteFileTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "delete_file": return wrapTool(DeleteFileTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "move_file": return wrapTool(MoveFileTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "copy_file": return wrapTool(CopyFileTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "create_folder": return wrapTool(CreateFolderTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "execute_shell": return wrapTool(TerminalTool(conversationID: conversationID), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "open_application": return wrapTool(OpenApplicationTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "run_applescript": return wrapTool(RunAppleScriptTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "get_system_stats": return wrapTool(GetSystemStatsTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "fs_watch_folder": return wrapTool(WatchFolderTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "fs_smart_search": return wrapTool(SmartSearchTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "fs_read_metadata": return wrapTool(ReadMetadataTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "fs_organize_batch": return wrapTool(OrganizeBatchTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "read_session_history": return wrapTool(ReadSessionHistoryTool(conversationID: conversationID), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
            
        // MACOS SYSTEM COMMANDING TOOLS
        case "read_screen_state": return wrapTool(ReadScreenStateTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "click_ui_element": return wrapTool(ClickUIElementTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "manage_windows": return wrapTool(ManageWindowsTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "manage_calendar": return wrapTool(ManageCalendarTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "manage_reminders": return wrapTool(ManageRemindersTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "read_contacts": return wrapTool(ManageContactsTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "manage_contacts": return wrapTool(ManageContactsTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "run_mac_shortcut": return wrapTool(RunMacShortcutTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "manage_clipboard": return wrapTool(ManageClipboardTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "push_local_notification": return wrapTool(PushLocalNotificationTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "get_focus_context": return wrapTool(GetFocusContextTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "get_power_state": return wrapTool(GetPowerStateTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "manage_processes": return wrapTool(ManageProcessesTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "manage_safari_tabs": return wrapTool(ManageSafariTabsTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "read_safari_bookmarks": return wrapTool(ReadSafariBookmarksTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "extract_safari_reader_view": return wrapTool(ExtractSafariReaderViewTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)

        // VISION INPUT TOOLS
        case "type_text": return wrapTool(TypeTextTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "press_key_combo": return wrapTool(PressKeyComboTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "scroll_ui": return wrapTool(ScrollUITool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "read_ui_element_tree": return wrapTool(ReadUIElementTreeTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)

        // NETWORK TOOLS
        case "check_network_status": return wrapTool(CheckNetworkStatusTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "http_request": return wrapTool(HTTPRequestTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "dns_lookup": return wrapTool(DNSLookupTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)

        // AUDIO & MEDIA TOOLS
        case "manage_audio": return wrapTool(ManageAudioTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "media_control": return wrapTool(MediaControlTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "text_to_speech": return wrapTool(TextToSpeechTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)

        // SYSTEM TOGGLE TOOLS
        case "toggle_dark_mode": return wrapTool(ToggleDarkModeTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "toggle_do_not_disturb": return wrapTool(ToggleDoNotDisturbTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "get_wifi_info": return wrapTool(GetWiFiInfoTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "manage_bluetooth": return wrapTool(ManageBluetoothTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)

        // FILE UTILITY TOOLS
        case "grep_files": return wrapTool(GrepFilesTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "diff_files": return wrapTool(DiffFilesTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "preview_file": return wrapTool(PreviewFileTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "get_file_hash": return wrapTool(GetFileHashTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)

        // GIT INTEGRATION
        case "git_tool": return wrapTool(GitTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)

        // CODING ASSISTANT TOOLS
        case "edit_code": return wrapTool(EditCodeTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "code_search": return wrapTool(CodeSearchTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "glob_files": return wrapTool(GlobFilesTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "find_definition": return wrapTool(FindDefinitionTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "batch_command": return wrapTool(BatchCommandTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "create_file": return wrapTool(CreateFileTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "file_overview": return wrapTool(FileOverviewTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "codebase_map": return wrapTool(CodebaseMapTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)

        // CODE-INTERFACE-ONLY SPLITS (not registered in LocalToolManager — hidden from Tool Library)
        case "edit_code_single": return wrapTool(EditCodeSingleTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "edit_code_batch": return wrapTool(EditCodeBatchTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "code_search_text": return wrapTool(CodeSearchTextTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "code_search_symbol": return wrapTool(CodeSearchSymbolTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "code_search_files": return wrapTool(CodeSearchFilesTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "create_new_file": return wrapTool(CreateNewFileTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "overwrite_file": return wrapTool(OverwriteFileTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)

        // MACOS UTILITY TOOLS
        case "screen_capture": return wrapTool(ScreenCaptureTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "finder_tags": return wrapTool(FinderTagsTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "disk_usage": return wrapTool(DiskUsageTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "display_management": return wrapTool(DisplayManagementTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "open_system_settings": return wrapTool(OpenSystemSettingsTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "login_items": return wrapTool(LoginItemsTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "external_devices": return wrapTool(ExternalDevicesTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
        case "apple_notes": return wrapTool(AppleNotesTool(), requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)

        default: return nil
        }
    }
    
    // MARK: - MCP Tool Resolution
    
    func resolveMCPTool(toolConfig: Tool, availableSources: [ToolSource]) -> AgentTool? {
        guard let source = availableSources.first(where: { $0.id == toolConfig.sourceId }),
              let definition = source.tools.first(where: { $0.name == toolConfig.name }) else {
            return nil
        }
        return wrapTool(DynamicMCPTool(source: source, toolDefinition: definition), requiresConfirmation: toolConfig.requiresConfirmation, timeout: toolConfig.timeout, timeoutMessage: toolConfig.timeoutMessage)
    }

    // MARK: - Logging Helper
    
    /// Logs the complete configuration for tracking and debugging purposes.
    private func logFullConfiguration(
        profile: BackendProfileModel,
        config: ProviderConfig,
        isBotFlow: Bool,
        tools: [AgentTool],
        instructions: String?
    ) {
        let toolNames = tools.isEmpty ? "None" : tools.map { $0.name }.joined(separator: ", ")
        let metadata = config.modelMetadata.map { "\($0.tier.rawValue) tier, \($0.quantization ?? "unknown quant"), \($0.family ?? "unknown family")" } ?? "None"

        // Show the effective config that will actually be used at runtime,
        // including auto-detected defaults when no user override exists.
        let advConfig: String = {
            if let advDict = config.advancedConfiguration {
                let rawDict = advDict.mapValues { $0.rawValue }
                if let data = try? JSONSerialization.data(withJSONObject: rawDict),
                   let decoded = try? JSONDecoder().decode(MLXAdvancedConfig.self, from: data) {
                    return "User Override (temp: \(decoded.temperature), topP: \(decoded.topP), repPenalty: \(decoded.repetitionPenalty), repCtx: \(decoded.repetitionContextSize), maxTok: \(decoded.maxTokens))"
                }
            }
            if config.apiProvider == .mlx, let meta = config.modelMetadata {
                let rec = MLXAdvancedConfig.recommended(for: meta)
                return "Auto-Detected (temp: \(rec.temperature), topP: \(rec.topP), repPenalty: \(rec.repetitionPenalty), repCtx: \(rec.repetitionContextSize), maxTok: \(rec.maxTokens))"
            }
            return "None"
        }()
        
        let logMsg = """
        
        --- 🚀 FULL REQUEST CONFIGURATION 🚀 ---
        Profile: \(profile.displayName) (ID: \(profile.id))
        Type: \(profile.profileType.rawValue) (BotFlow: \(isBotFlow))
        Provider: \(config.apiProvider.rawValue)
        Model: \(config.modelName)
        Base URL: \(baseURLDisplay(config))
        Capabilities: \(config.cognitiveCapability.rawValue) (Dialect: \(effectiveDialect(config)))
        Metadata: \(metadata)
        Advanced Options: \(advConfig)
        Tools Enabled: [\(toolNames)]
        System Instructions: \(instructions?.prefix(100) ?? "None")\( (instructions?.count ?? 0) > 100 ? "..." : "") (\(instructions?.count ?? 0) chars)
        -----------------------------------------
        """
        logger.notice("\(logMsg)")
    }

    /// Returns the dialect label used in the startup config log. Cloud providers always
    /// speak native JSON; local providers (MLX/Ollama) route by the dialect stored on
    /// ProviderConfig, so we surface that value directly. `.none` capability has no
    /// dialect in play — it runs through the heuristic JSON fallback.
    private func effectiveDialect(_ config: ProviderConfig) -> String {
        switch config.apiProvider {
        case .anthropic, .google, .openAI, .openRouter, .openAICompatible:
            return "Native JSON (Cloud)"
        case .mlx, .ollama:
            switch config.cognitiveCapability {
            case .parallelActions, .singleAction:
                return config.modelDialect.rawValue
            case .none:
                return "Heuristic JSON (Prompted)"
            }
        }
    }

    /// Returns a display string for the configured base URL. MLX runs in-process and
    /// has no endpoint, so showing an Ollama-default URL for MLX profiles is misleading
    /// during triage.
    private func baseURLDisplay(_ config: ProviderConfig) -> String {
        if config.apiProvider == .mlx {
            return "In-Process (MLX)"
        }
        return config.baseURL ?? "Default"
    }

}

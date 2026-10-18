// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AgentConnect.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    // Why: the runtime gate is the mere presence of `capabilities.agentDelegation`;
    // a stored preference is ignored, never rewritten.
    /// Whether agent delegation (`call_agent` / sub-agents) is available at all.
    static let agentDelegationSupported = false
    
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
        attachmentContext: String? = nil,
        knowledgeBaseContext: String? = nil,
        toolGuidanceContext: String? = nil,
        userPayload: Payload? = nil,
        resumeState: TimelineReconstruction? = nil,
        traceContext: TraceContext,
        onTraceUpdate: (@Sendable (AgentTraceLog) -> Void)? = nil
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {

        logger.info("Request reached TextGen Unified Pipeline for profile: \(profile.displayName)")
        let requestedProfile = profile

        return AsyncThrowingStream { continuation in
            let task = Task {
                // A local model's capability is looked up NOW, not trusted from the profile — see
                // `LiveModelDetection`. Idempotent when the orchestrator already resolved it.
                let profile = await LiveModelDetection.resolving(requestedProfile)
                do {
                    // 1. Extract Configuration & Tools based on Profile Type
                    let llmConfig: ProviderConfig
                    var instructions: String?
                    // Code only: AGENTS.md + the memory listing, rendered as its own layer.
                    var projectKnowledge: String?
                    let rawTools: [Tool]
                    let isBotFlow: Bool
                    var skillManifests: [SkillManifest]?
                    
                    switch profile.details {
                    case .bot(let config):
                        llmConfig = config.llmConfig
                        instructions = config.instructions
                        rawTools = []
                        isBotFlow = true
                        skillManifests = nil

                    case .agent(let config):
                        llmConfig = config.llmConfig
                        instructions = config.instructions
                        rawTools = config.tools
                        isBotFlow = false
                        // Skill references resolve against the global registry; a profile without a registry entry uses its manifest copies.
                        // The registry is authoritative for `description`, the text the model routes on.
                        skillManifests = await MainActor.run {
                            SkillResolution.resolve(for: config, profileName: profile.displayName)?.manifests
                        }

                    case .workflow:
                        // Workflow: each node resolves its own model, tools, and generator; the layout is the source of truth.
                        // Attachments travel their own channel to the entry node; a workflow profile defines no knowledge sources.
                        let workflowExecutor = WorkflowExecutor(workflowProfileID: profile.id)
                        // `chatHistory`/`ragContext` are deliberately not passed: a workflow run is conversation-stateless.
                        let wfStream = workflowExecutor.executeWorkflow(
                            userInput: userInput,
                            conversationID: conversationID,
                            attachmentContext: attachmentContext,
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
                        projectKnowledge = Self.codeProjectKnowledge(config, traceTag: traceContext.traceID)
                        rawTools = config.tools
                        isBotFlow = false
                        // Code profiles get no skills; skills stored on a converted profile are logged and discarded here.
                        skillManifests = nil
                        let unique = CodeModeSkillDiagnostics.inertSkillNames(in: config)
                        if !unique.isEmpty {
                            logger.notice("[CODE] Profile carries \(unique.count) enabled skill(s) that Code mode does NOT load: \(unique.joined(separator: ", ")). CONSEQUENCE: they are absent from <available_skills> and `load_skill` is not registered, so the model cannot reach them — the skills are configured but inert. Move the work to an Agent profile if they are needed.")
                        }
                        logger.info("[CODE] AgentConnect extracted Code config — provider: \(config.llmConfig.apiProvider.rawValue), model: \(config.llmConfig.modelName), tools: \(config.tools.count), projectPath: \(config.projectPath ?? "nil"), traceID: \(traceContext.traceID)")
                    }

                    // A new Code run makes the previous answer's memory pass moot (and it would
                    // compete with this run for a local model).
                    if case .code = profile.details {
                        await ProjectMemorySuggester.shared.cancel(conversationID: conversationID)
                    }
                    // What this run's tools did, for the optional end-of-run memory pass.
                    let memoryEvidence = ProjectMemoryRunEvidence()

                    // 2. Select Cognitive Strategy & Rate Limit Boundary
                    let rateLimitCategory = RateLimitCategory.from(provider: llmConfig.apiProvider, modelName: llmConfig.modelName)
                    let rateLimitKey = RateLimitCategory.deriveBucketKey(
                        provider: llmConfig.apiProvider,
                        apiKey: llmConfig.apiKey,
                        baseURL: llmConfig.baseURL,
                        modelName: llmConfig.modelName
                    )
                    
                    // Resolve Cognitive Strategy via our 2D routing matrix
                    let generatorStrategy = try self.resolveCognitiveGenerator(
                        llmConfig: llmConfig,
                        isBotFlow: isBotFlow
                    )
                    
                    // 3. Memory & Model Initialization
                    let modelTier = llmConfig.modelMetadata?.tier ?? .medium
                    // Uses the effective window (num_ctx-aware for Ollama, 8K local fallback) to size compaction and native-turn budgets.
                    let contextWindow = EffectiveContextWindow.resolve(
                        for: llmConfig, flavour: isBotFlow ? .chat : .agent)
                    // Empty when nothing was retrieved; PromptBuilder skips the <semantic_context> layer for empty grounding.
                    let staticGrounding = ragContext ?? ""

                    // Long-term grounding is pre-fetched RAG injected into the prompt; there is no tier branch.
                    let longTermMemory: any LongTermMemoryStrategy =
                        StaticGroundingMemory(ragContext: staticGrounding)

                    // --- UI Progress: Model initialization ---
                    switch llmConfig.apiProvider {
                    case .mlx:
                        continuation.yield(.thought("Loading local model: \(llmConfig.modelName)."))
                    case .ollama:
                        continuation.yield(.thought("Connecting to Ollama: \(llmConfig.modelName)."))
                    default:
                        break
                    }

                    // 4. Initialize the Language Model (before tool resolution — delegation needs the model)
                    let model = try await self.initializeModel(config: llmConfig, isBotFlow: isBotFlow)

                    // Capabilities for tool injection (delegation), taken from every profile type that carries them, `.code` included.
                    let agentCapabilities: AgentCapabilities? = profile.details.agentCapabilities

                    // Records which profile and model service an MCP server's out-of-band `sampling/createMessage` for this run,
                    // so the approval banner is raised in the right conversation and the call is billed to the chosen profile.
                    let samplingContext = MCPSamplingContext(
                        conversationID: conversationID,
                        providerConfig: llmConfig,
                        profileID: profile.id,
                        runMessageID: traceContext.messageID,
                        registeredAt: Date()
                    )
                    await MCPSamplingBroker.shared.register(context: samplingContext)
                    // Withdrawn when this run ends, on every exit; a context outliving its run would serve sampling with a stale profile.
                    defer { Task { await MCPSamplingBroker.shared.unregister(samplingContext) } }

                    var activeTools = await self.resolveExecutableTools(
                        profileTools: ReportOnlyRun.allowedProfileTools(rawTools),
                        conversationID: conversationID,
                        longTermMemory: longTermMemory,
                        agentCapabilities: agentCapabilities,
                        parentModel: model,
                        generatorStrategy: generatorStrategy,
                        rateLimitKey: rateLimitKey,
                        rateLimitCategory: rateLimitCategory,
                        parentProvider: llmConfig.apiProvider,
                        skillManifests: skillManifests,
                        modelTier: modelTier,
                        profileID: profile.id
                    )

                    // Injects `final_answer` at index 0 for Agent/Code/Workflow flows; it is the only clean exit from the ReAct loop.
                    // Bot profiles are excluded: ChatExecutor has no tool dispatch loop.
                    if !isBotFlow {
                        let finalAnswerTool = self.wrapTool(FinalAnswerTool(), requiresConfirmation: false)
                        activeTools.insert(finalAnswerTool, at: 0)
                    }

                    // Code mode: the project-memory tools are offered on every Code run, for every model.
                    // `remember` validates what it is told; see `RememberTool.validate`.
                    let memoryTools = Self.codeMemoryTools(for: profile.details, conversationID: conversationID,
                                                           messageID: traceContext.messageID)
                    if !memoryTools.isEmpty {
                        activeTools.append(contentsOf: memoryTools)
                        logger.info("[CODE] Code tool set assembled — \(activeTools.count) tools so far, incl. final_answer, remember, forget and recall. CONSEQUENCE: this is NOT the final loadout — get_conversation_history is appended later, once the history is known. The authoritative list is the [TOOLS] line below.")
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
                    
                    // Native turn-payload budget (~75% of the context window as chars); the ReAct loop compacts the oldest tool
                    // exchanges past it.
                    let nativeContextBudgetChars = PromptFitCheck.nativePayloadCharBudget(forContextWindow: contextWindow)

                    // History strategy comes from the profile (default `.recentHistory`), for every profile type that carries one.
                    let historyStrategy: HistoryStrategy = profile.details.historyStrategy

                    // Determine if this is a native provider (supports turn-by-turn history)
                    let isNativeProvider: Bool = {
                        switch llmConfig.apiProvider {
                        case .anthropic, .openAI, .google, .openRouter, .openAICompatible: return true
                        case .ollama: return llmConfig.cognitiveCapability != .none
                        case .mlx: return false
                        }
                    }()

                    var nativeHistoryTurns: [HistoryTurn]? = nil

                    // Vision gate for prior-turn images: they are dropped when the target model cannot see them, for every provider.
                    let historyImagesEnabled = isNativeProvider && profile.supportsVisionInput
                    if isNativeProvider && !profile.supportsVisionInput {
                        logger.info("[HISTORY] conv:\(conversationID.uuidString.prefix(8)) trace:\(traceContext.traceID) Vision gate: prior-turn images omitted for '\(llmConfig.modelName)' (no visionInput modality) — the model will not see images from earlier turns in this conversation")
                    }

                    // History building is independent of tool availability.
                    // Even tool-less agents benefit from conversation context.
                    var effectiveHistory = chatHistory // Mutable copy — compaction may insert a checkpoint
                    // Planned during history building, STARTED after the answer (see below).
                    var pendingCompaction: CompactionPlan?
                    if !effectiveHistory.isEmpty {
                        // Shared with the fit gauges via PromptFitCheck so the number they
                        // report is measured against the same allocation this spends.
                        let charBudget = PromptFitCheck.historyCharBudget(forContextWindow: contextWindow)

                        // Compaction is planned here but runs in the background after this turn's stream finishes, so it never competes
                        // with the turn for the model; this request proceeds with uncompacted history and the summary applies next turn.
                        if let plan = await HistoryCompactionService.shared.evaluate(
                            chatHistory: effectiveHistory,
                            charBudget: charBudget
                        ) {
                            pendingCompaction = plan
                            logger.info("[COMPACTION] Planned — \(plan.turnPairsInBatch) turn pairs, checkpoint #\(plan.checkpointNumber); it starts after this turn's answer. THIS turn proceeds with uncompacted history (\(effectiveHistory.count) messages, trimmed to budget by the builders). conversationID: \(conversationID.uuidString.prefix(8)), traceID: \(traceContext.traceID)")
                        }

                        // SessionGraph tracks tool failures (Ghost Protocol) — only relevant when tools exist.
                        // Built AFTER compaction so it operates on checkpoint-aware history.
                        if !activeTools.isEmpty {
                            activeState = EpisodicHistoryFormatter.buildGraph(
                                from: effectiveHistory,
                                sessionID: conversationID.uuidString
                            )
                        }

                        // Episodic XML history goes into the system prompt for every flow; native providers also get prose turn pairs.
                        // Native turns are built first so the XML can omit the `<outcome>` clips of answers they already carry.
                        var answersCarriedNatively = Set<UUID>()
                        if isNativeProvider {
                            let native = NativeHistoryConverter.buildCarryingProvenance(
                                strategy: historyStrategy,
                                from: effectiveHistory,
                                charBudget: charBudget,
                                includeImages: historyImagesEnabled,
                                correlation: "conv:\(conversationID.uuidString.prefix(8)) trace:\(traceContext.traceID)",
                                // Must match the episodic build below: both emit the `get_conversation_history(N)` instruction,
                                // and a mismatch makes the prompt contradict itself.
                                toolsAvailable: !isBotFlow
                            )
                            nativeHistoryTurns = native.turns
                            answersCarriedNatively = native.fullAnswerMessageIDs
                        }

                        // Episodic XML — one dispatch for all four strategies, shared with
                        // the fit gauges so what they measure is what ships.
                        recentHistory = EpisodicHistoryFormatter.build(
                            strategy: historyStrategy,
                            from: effectiveHistory,
                            includeImageNames: profile.supportsVisionInput,
                            effectBudget: ActionEffect.diffBudget(forHistoryCharBudget: charBudget),
                            correlation: "conv:\(conversationID.uuidString.prefix(8)) trace:\(traceContext.traceID)",
                            toolsAvailable: !isBotFlow,
                            // `.live` only on this request path: it stats each effect's file to check the stored diff is still current.
                            // `ContextWindowGauge` takes the `.unknown` default so the composer never touches the filesystem.
                            staleness: .live,
                            answersCarriedNatively: answersCarriedNatively
                        )

                        // Inject `get_conversation_history` only if pointer references were emitted in the built history.
                        let hasPointers: Bool = {
                            if let turns = nativeHistoryTurns {
                                return turns.contains { $0.text.contains("get_conversation_history(") }
                            }
                            return recentHistory?.contains("get_conversation_history(") == true
                        }()

                        if hasPointers {
                            activeTools.append(
                                wrapTool(ConversationHistoryTool(chatHistory: effectiveHistory, correlation: "conv:\(conversationID.uuidString.prefix(8)) trace:\(traceContext.traceID)"), requiresConfirmation: false)
                            )
                        }
                    }

                    // The authoritative tool list: logged after the last thing that can append (`get_conversation_history`).
                    logger.info("[TOOLS] Final loadout for \(profile.profileType.rawValue) run — \(activeTools.count) tool(s): [\(activeTools.map(\.name).joined(separator: ", "))]. CONSEQUENCE: this is exactly what the model is offered; anything named in the prompt but missing here cannot be called.")
                    // Names what the instructions mention but the loadout lacks; the line above lists only what is offered.
                    for reference in InstructionToolReferences.check(
                        instructions: instructions, enabledToolNames: Set(activeTools.map(\.name))
                    ) {
                        logger.warning("[TOOLS] Instructions reference '\(reference.name)' — \(reference.message) CONSEQUENCE: the model is told to use a tool it cannot call; expect a wasted step or a guess.")
                    }
                    
                    // Resilience config from the profile, `.code` included.
                    let retryPolicy = profile.details.retryPolicy
                    let errorRecovery = profile.details.errorRecovery
                    let resilienceOverrides = profile.details.resilienceOverrides

                    // Resolves the three-tier resilience policy once, where the provider class is known: transport budgets are
                    // provider-derived; cognitive/loop caps take the user's per-tier overrides.
                    let resiliencePolicy = ResolvedResiliencePolicy.resolved(
                        for: ProviderClass(apiProvider: llmConfig.apiProvider),
                        overrides: resilienceOverrides,
                        legacy: retryPolicy,
                        endpointHint: llmConfig.baseURL
                    )

                    // IC response synthesis is strictly opt-in per provider family (see SynthesisOptIn); nothing else turns it on.
                    let icAvailable = await IntelligenceCoreService.shared.hasModelSelected
                    let icEnabled = UserDefaults.standard.bool(forKey: AppSettings.isIntelligenceCoreEnabledKey)
                    let synthDecision = SynthesisOptIn.resolved(
                        provider: llmConfig.apiProvider,
                        icModelSelected: icAvailable,
                        icEnabled: icEnabled
                    )
                    let responseSynthesisEnabled = synthDecision.optedIn
                    logger.info("[SYNTH] provider-family: \(synthDecision.family.rawValue), opted-in: \(synthDecision.optedIn) (\(synthDecision.reason)) → \(synthDecision.optedIn ? "IC synthesis pass" : "raw passthrough"), traceID: \(traceContext.traceID), conversationID: \(conversationID.uuidString.prefix(8))")

                    // Only a `.code` profile has a user-chosen folder, so only it is confined; other types resolve to nil (no boundary).
                    let codeWorkspaceRoot: String? = {
                        guard case .code(let codeConfig) = profile.details else { return nil }
                        return codeConfig.projectPath
                    }()
                    if let codeWorkspaceRoot {
                        logger.info("[WORKSPACE] Code run confined to \(codeWorkspaceRoot) — conv \(conversationID.uuidString.prefix(8)). CONSEQUENCE: relative tool paths resolve against this folder instead of the home directory; writes outside it are refused and reads outside it ask the user first.")
                    } else if case .code = profile.details {
                        // A Code profile with no folder is unconfined (filesystem tools see the whole disk); this should be unreachable.
                        logger.error("[WORKSPACE] Code run has NO project folder — conv \(conversationID.uuidString.prefix(8)). CONSEQUENCE: this run is UNCONFINED — no path is checked, nothing is refused, and a relative path resolves against the home directory. A send should have been refused before reaching here.")
                    }

                    // Working memory (the scratchpad of the text-tools path) gets whatever room the fixed prompt leaves, so it is built
                    // after history and every context block exist. See `MemoryBudgetConfig.derive`.
                    let reservedPromptChars = (instructions?.count ?? 0)
                        + (projectKnowledge?.count ?? 0)
                        + (recentHistory?.count ?? 0)
                        + (attachmentContext?.count ?? 0)
                        + (knowledgeBaseContext?.count ?? 0)
                        + (toolGuidanceContext?.count ?? 0)
                        + userInput.count
                        + ToolSchemaSizes.chars(for: activeTools.map(\.name))
                    let memoryConfig = MemoryBudgetConfig.derive(
                        contextWindow: contextWindow, tier: modelTier, reservedChars: reservedPromptChars)
                    // Which part of an oversized result survives: the gauge's global setting plus this
                    // profile's per-tool overrides. One policy for both paths.
                    let cutPolicy = ToolCutPolicy.forRun(tools: rawTools)
                    var windowed = WindowedLinearMemory(config: memoryConfig)
                    windowed.cutPolicy = cutPolicy
                    let workingMemory: any WorkingMemoryStrategy = windowed
                    logger.info("[MEMORY] Scratchpad sized to \(memoryConfig.totalBudgetChars) chars (payload budget \(nativeContextBudgetChars) − fixed prompt \(reservedPromptChars)); one result may use all of it. CONSEQUENCE: on the text-tools path, tool results are cut only when they exceed the room actually left.")

                    var input = AgentInput(
                        userInput: userInput,
                        userPayload: userPayload,
                        attachmentContext: attachmentContext,
                        knowledgeBaseContext: knowledgeBaseContext,
                        toolGuidanceContext: toolGuidanceContext,
                        chatHistory: chatHistory,
                        // Vision bots re-attach prior-turn images; gated on vision alone, not tool capability.
                        // Non-vision models omit history images.
                        botHistoryImagesEnabled: isBotFlow && profile.supportsVisionInput,
                        conversationID: conversationID,
                        tools: activeTools,
                        longTermMemory: longTermMemory,
                        workspaceRoot: codeWorkspaceRoot,
                        activeState: activeState,
                        recentHistory: recentHistory,
                        generatorStrategy: generatorStrategy,
                        workingMemory: workingMemory,
                        rateLimitKey: rateLimitKey,
                        rateLimitCategory: rateLimitCategory,
                        instructions: instructions,
                        skillManifests: skillManifests,
                        retryPolicy: retryPolicy,
                        errorRecovery: errorRecovery,
                        resiliencePolicy: resiliencePolicy,
                        responseSynthesisEnabled: responseSynthesisEnabled,
                        nativeHistoryTurns: nativeHistoryTurns,
                        resumeState: resumeState,
                        traceContext: traceContext,
                        modelTier: llmConfig.modelMetadata?.tier,
                        nativeContextBudgetChars: nativeContextBudgetChars,
                        contextWindowTokens: contextWindow,
                        cutPolicy: cutPolicy
                    )
                    input.projectKnowledge = projectKnowledge
                    input.largeRequestConfirmChars = LargeRequestGate.confirmChars(
                        provider: llmConfig.apiProvider, baseURL: llmConfig.baseURL)

                    // 8. Execute & Stream
                    let traceHandler: @Sendable (AgentTraceLog) -> Void = { log in
                        logger.debug("[\(log.state.headline)] \(log.content) (span: \(log.spanID))")
                        if !activeTools.isEmpty {
                            EvaluationLogger.shared.logStep(id: evalSessionID, log: log)
                        }
                        onTraceUpdate?(log)
                    }
                    
                    try Task.checkCancellation()

                    // Execution timeout from the profile's agent configuration, read through `ProfileDetails.agentConfig`,
                    // which covers every profile type that carries an `AgentConfig` (`.code` included).
                    let executionTimeout: TimeInterval? = TimeLimit.usable(profile.details.executionTimeout,
                                                                           "Profile '\(profile.displayName)' execution timeout")

                    if let executionTimeout {
                        logger.info("""
                            [EXEC_LIMITS] Execution timeout \(Int(executionTimeout))s armed for \
                            conversation \(conversationID.uuidString.prefix(8)) \
                            (\(profile.profileType.rawValue)). CONSEQUENCE: the run is aborted if it \
                            exceeds this much COMPUTE — time parked awaiting a human (tool \
                            confirmations, clarifications, plan review) is excluded and extends the \
                            budget.
                            """)
                    } else {
                        logger.notice("""
                            [EXEC_LIMITS] No execution timeout configured for conversation \
                            \(conversationID.uuidString.prefix(8)) \
                            (\(profile.profileType.rawValue)). CONSEQUENCE: the run has no \
                            wall-clock bound — a stalled tool call streams until the user cancels.
                            """)
                    }

                    if case .code = profile.details {
                        logger.info("[CODE] Executor handoff — executor: \(executor.executorLabel), traceID: \(traceContext.traceID), spanID: \(traceContext.spanID), conversationID: \(conversationID.uuidString.prefix(8))")
                    }

                    // Every turn gets an owner-chain scope and its stream is created inside it so the producer task inherits the chain;
                    // approval banners then pause only this turn's clocks, never another run's.
                    let turnScope = UUID()
                    await ExecutionSuspensionService.shared.registerScope(turnScope, conversationID: conversationID)
                    defer { Task { await ExecutionSuspensionService.shared.unregisterScope(turnScope) } }
                    // Nesting: a limited turn is an outer budget, so a tool call inside it is shortened to fit and fires first,
                    // leaving `ExecutionBudget.reserve` for the model to reply.
                    let turnFrame: ExecutionBudget.Frame? = if let executionTimeout {
                        await ExecutionBudget.frame(
                            owner: "the turn's \(ToolExecutionMediator.describe(executionTimeout)) limit",
                            limit: executionTimeout, scope: turnScope)
                    } else { nil }
                    let stream = ParkScope.bind(turnScope) {
                        ExecutionBudget.bind(turnFrame) {
                            executor.execute(model: model, input: input, onTraceUpdate: traceHandler)
                        }
                    }

                    let finalOutputAccumulator: String

                    if let timeout = executionTimeout {
                        // Enforces the execution timeout via a Task race; the typed TaskGroup returns the accumulated output of
                        // whichever task completes first.
                        let timeoutSubject = "Conversation \(conversationID.uuidString.prefix(8)) (\(profile.profileType.rawValue))"
                        finalOutputAccumulator = try await withThrowingTaskGroup(of: String.self) { group in
                            // Timeout sentinel: bounds compute time and extends itself by however long tool confirmations were parked,
                            // since they suspend inside this raced task.
                            group.addTask {
                                try await ComputeTimeoutSentinel.sleepUntilComputeExceeded(
                                    limit: timeout,
                                    scope: turnScope,
                                    logTag: "EXEC_LIMITS",
                                    subject: timeoutSubject,
                                    consequence: "the run is aborted and the timeout surfaces to the user; time spent awaiting a human was excluded from the budget."
                                )
                            }
                            // Actual execution — accumulates output and returns it
                            group.addTask {
                                var accumulated = ""
                                for try await event in stream {
                                    if case .content(let chunk) = event {
                                        accumulated += chunk
                                    }
                                    memoryEvidence.observe(event)
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
                            memoryEvidence.observe(event)
                            continuation.yield(event)
                        }
                        finalOutputAccumulator = accumulated
                    }
                    
                    let outputPreview = String(finalOutputAccumulator.prefix(200))
                    logger.info("--- TEXTGEN RESPONSE COMPLETE --- traceID: \(traceContext.traceID), model: \(llmConfig.modelName), outputLen: \(finalOutputAccumulator.count)")
                    logger.debug("Output preview: \(outputPreview)")
                    
                    continuation.finish()

                    // The answer is out — now summarize, in the background, off this turn.
                    if let plan = pendingCompaction {
                        await HistoryCompactionService.shared.scheduleExecution(
                            plan: plan, conversationID: conversationID, conversationModel: llmConfig)
                    }

                    // …and, when the project asks for it, propose memories from what the run did.
                    if ProjectMemorySuggester.isEnabled(for: profile.details),
                       case .code(let codeConfig) = profile.details, let projectPath = codeConfig.projectPath,
                       let answerID = traceContext.messageID {
                        let modelConfig = llmConfig
                        await ProjectMemorySuggester.shared.schedule(
                            evidence: memoryEvidence, userRequest: userInput, answer: finalOutputAccumulator,
                            projectPath: projectPath, conversationID: conversationID, messageID: answerID
                        ) { messages in
                            // A background run of its own on the local lock, not this finished turn's identity; see
                            // `LocalInferenceCoordinator.runBackgroundLocal`.
                            try await LocalInferenceCoordinator.shared.runBackgroundLocal(
                                feature: "Project memory suggestions", conversationID: conversationID, config: modelConfig
                            ) {
                                let model = try await AgentConnect().initializeModel(config: modelConfig, isBotFlow: true)
                                return try await model.generate(messages: messages, tools: nil, responseSchema: nil)
                            }
                        }
                    }
                    
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

    /// Streams a workflow node's response, bypassing RAG, history, compaction, and episode management.
    /// Uses the same generator/parser as the agent or bot path; workflow specifics come from
    /// `SemanticContext.workflowContext`.
    func streamWorkflowNodeResponse(
        for profile: BackendProfileModel,
        workflowContext: WorkflowExecutionContext,
        conversationID: UUID,
        traceContext: TraceContext,
        onTraceUpdate: (@Sendable (AgentTraceLog) -> Void)? = nil
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {

        logger.info("[Workflow] Node stream: profile='\(profile.displayName)' type=\(profile.profileType.rawValue) node='\(workflowContext.nodeName)'")
        let requestedProfile = profile

        return AsyncThrowingStream { continuation in
            let task = Task {
                // Workflow nodes never open an editor, so they are exactly the runs a stale stored
                // capability would otherwise follow forever — see `LiveModelDetection`.
                let profile = await LiveModelDetection.resolving(requestedProfile)
                do {
                    // 1. Extract profile config (same switch as streamAgentResponse lines 54-96)
                    let llmConfig: ProviderConfig
                    var instructions: String?
                    // Code only: AGENTS.md + the memory listing, rendered as its own layer.
                    var projectKnowledge: String?
                    let rawTools: [Tool]
                    let isBotFlow: Bool
                    var skillManifests: [SkillManifest]?
                    // Code only: the project folder that confines this node's file tools.
                    var nodeWorkspaceRoot: String?

                    switch profile.details {
                    case .bot(let config):
                        llmConfig = config.llmConfig
                        instructions = config.instructions
                        rawTools = []
                        isBotFlow = true
                        skillManifests = nil

                    case .agent(let config):
                        llmConfig = config.llmConfig
                        instructions = config.instructions
                        rawTools = config.tools
                        isBotFlow = false
                        // Skill references resolve against the global registry; a profile without a registry entry uses its manifest copies.
                        // The registry is authoritative for `description`, the text the model routes on.
                        skillManifests = await MainActor.run {
                            SkillResolution.resolve(for: config, profileName: profile.displayName)?.manifests
                        }

                    case .code(let config):
                        llmConfig = config.llmConfig
                        instructions = config.instructions
                        projectKnowledge = Self.codeProjectKnowledge(config, traceTag: "workflow-node")
                        rawTools = config.tools
                        isBotFlow = false
                        // A Code profile used as a workflow node is confined to its project folder, as on the chat path.
                        nodeWorkspaceRoot = config.projectPath
                        if let root = config.projectPath {
                            logger.info("[WORKSPACE] Workflow node '\(workflowContext.nodeName)' (Code profile) confined to \(root) — conv \(conversationID.uuidString.prefix(8)). CONSEQUENCE: relative tool paths resolve against this folder; writes outside it are refused and reads outside it ask the user (or are refused when nobody can answer).")
                        } else {
                            logger.error("[WORKSPACE] Workflow node '\(workflowContext.nodeName)' uses a Code profile with NO project folder — conv \(conversationID.uuidString.prefix(8)). CONSEQUENCE: this node is UNCONFINED — no path is checked and a relative path resolves against the home directory. Set the profile's project folder.")
                        }
                        // Same deliberate exclusion as the chat path above; see the note there.
                        skillManifests = nil
                        let orphaned = CodeModeSkillDiagnostics.inertSkillNames(in: config)
                        if !orphaned.isEmpty {
                            logger.notice("[CODE] Workflow-node Code profile carries \(orphaned.count) enabled skill(s) that Code mode does NOT load: \(orphaned.joined(separator: ", ")). CONSEQUENCE: they are absent from <available_skills> and unreachable by the model for this node.")
                        }

                    case .workflow, .imageGen:
                        continuation.yield(.error("Unsupported profile type for workflow node: \(profile.profileType.rawValue)"))
                        continuation.finish()
                        return
                    }

                    logger.info("[Workflow] Pipeline: skipping RAG, history, compaction, episode management")

                    // Resolves the dialect-specific generator. Workflow behavior is applied via `SemanticContext.workflowContext`,
                    // so nodes inherit each dialect's native tool injection, trigger suffix, schema, and parser.
                    let generator = try self.resolveCognitiveGenerator(
                        llmConfig: llmConfig,
                        isBotFlow: isBotFlow
                    )

                    // 3. Initialize model
                    let model = try await self.initializeModel(config: llmConfig, isBotFlow: isBotFlow)

                    // 6. Resolve tools (still needed for agent nodes)
                    let longTermMemory: any LongTermMemoryStrategy = StaticGroundingMemory(ragContext: "")
                    let agentCapabilities: AgentCapabilities? = profile.details.agentCapabilities

                    let rateLimitCategory = RateLimitCategory.from(provider: llmConfig.apiProvider, modelName: llmConfig.modelName)
                    let rateLimitKey = RateLimitCategory.deriveBucketKey(
                        provider: llmConfig.apiProvider,
                        apiKey: llmConfig.apiKey,
                        baseURL: llmConfig.baseURL,
                        modelName: llmConfig.modelName
                    )

                    // Records which profile and model service an MCP server's out-of-band `sampling/createMessage` for this run,
                    // so the approval banner is raised in the right conversation and the call is billed to the chosen profile.
                    let samplingContext = MCPSamplingContext(
                        conversationID: conversationID,
                        providerConfig: llmConfig,
                        profileID: profile.id,
                        runMessageID: traceContext.messageID,
                        registeredAt: Date()
                    )
                    await MCPSamplingBroker.shared.register(context: samplingContext)
                    // Withdrawn when this run ends, on every exit; a context outliving its run would serve sampling with a stale profile.
                    defer { Task { await MCPSamplingBroker.shared.unregister(samplingContext) } }

                    var activeTools = await self.resolveExecutableTools(
                        profileTools: ReportOnlyRun.allowedProfileTools(rawTools),
                        conversationID: conversationID,
                        longTermMemory: longTermMemory,
                        agentCapabilities: agentCapabilities,
                        parentModel: model,
                        generatorStrategy: generator,
                        rateLimitKey: rateLimitKey,
                        rateLimitCategory: rateLimitCategory,
                        parentProvider: llmConfig.apiProvider,
                        skillManifests: skillManifests,
                        modelTier: llmConfig.modelMetadata?.tier ?? .medium,
                        profileID: profile.id
                    )

                    // Injects the `final_answer` terminator for ReAct workflow nodes (agent/code);
                    // node output relies on `finalAgentThought`, which is populated when the model calls it.
                    if !isBotFlow {
                        let finalAnswerTool = self.wrapTool(FinalAnswerTool(), requiresConfirmation: false)
                        activeTools.insert(finalAnswerTool, at: 0)
                    }

                    // Builds the node's AgentInput: workflow-aware, no history/RAG/compaction. The node's input is simply its input.
                    let userInputForNode = workflowContext.input

                    // EFFECTIVE window — see the main-path note; workflow nodes get the
                    // same num_ctx-aware sizing so per-node budgets match reality.
                    let contextWindow = EffectiveContextWindow.resolve(
                        for: llmConfig, flavour: isBotFlow ? .chat : .agent)
                    let modelTier = llmConfig.modelMetadata?.tier ?? .medium
                    // #22: native turn-payload budget (~75% of context window as chars) —
                    // bounds liveConversationTurns growth on workflow agent nodes too.
                    let nativeContextBudgetChars = PromptFitCheck.nativePayloadCharBudget(forContextWindow: contextWindow)

                    let retryPolicy = profile.details.retryPolicy
                    let errorRecovery = profile.details.errorRecovery
                    let resilienceOverrides = profile.details.resilienceOverrides

                    // Upstream image artifacts become native image blocks so vision-capable bot nodes see them; the provider resolves
                    // and encodes at send time, and a failed resolve fails the node.
                    let workflowImagePayload: Payload? = {
                        let imageArtifacts = workflowContext.upstreamArtifacts.filter { $0.kind == .image }
                        guard !imageArtifacts.isEmpty else { return nil }
                        return imageArtifacts.map { .image(ImagePayload(reference: $0.reference, mimeType: $0.mimeType, alt: $0.label)) }
                    }()

                    // Per-node MCP guidance: gated on this node's own tool list, so a node with no MCP tools gets no `<tool_guidance>`.
                    let nodeToolSourceIDs = Set((rawTools ?? []).filter(\.isEnabled).map(\.sourceId))
                    var nodeToolGuidance: String? = nil
                    if !nodeToolSourceIDs.isEmpty {
                        let text = await MCPClientService.shared
                            .connectedServerInstructions(forSourceIDs: nodeToolSourceIDs)
                        nodeToolGuidance = text.isEmpty ? nil : text
                        logger.debug("[MCP-INSTRUCTIONS] node '\(workflowContext.nodeName)': \(text.count) chars of guidance from \(nodeToolSourceIDs.count) tool source(s). CONSEQUENCE: servers whose tools this node does not hold contribute nothing to its prompt.")
                    }

                    // The node's own per-tool overrides plus the gauge's global setting.
                    let nodeCutPolicy = ToolCutPolicy.forRun(tools: rawTools)
                    var input = AgentInput(
                        userInput: userInputForNode,
                        userPayload: workflowImagePayload,
                        // Attachments render as `<attachments>` — the same section the chat path
                        // uses — instead of being fused into this node's task.
                        attachmentContext: workflowContext.attachmentContext,
                        // Gated on THIS NODE's own tools, not the workflow profile's (it has none):
                        // each node picks its own profile and therefore its own MCP servers.
                        toolGuidanceContext: nodeToolGuidance,
                        chatHistory: [],
                        conversationID: conversationID,
                        tools: activeTools,
                        longTermMemory: longTermMemory,
                        workspaceRoot: nodeWorkspaceRoot,
                        recentHistory: nil,
                        generatorStrategy: generator,
                        workingMemory: {
                            var memory = WindowedLinearMemory(config: MemoryBudgetConfig.derive(
                                contextWindow: contextWindow, tier: modelTier,
                                // Same rule as the main path: the room the node's fixed prompt leaves.
                                reservedChars: (instructions?.count ?? 0)
                                    + (projectKnowledge?.count ?? 0)
                                    + (workflowContext.attachmentContext?.count ?? 0)
                                    + (nodeToolGuidance?.count ?? 0)
                                    + userInputForNode.count
                                    + ToolSchemaSizes.chars(for: activeTools.map(\.name))))
                            memory.cutPolicy = nodeCutPolicy
                            return memory
                        }(),
                        rateLimitKey: rateLimitKey,
                        rateLimitCategory: rateLimitCategory,
                        instructions: instructions,
                        skillManifests: skillManifests,
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
                        nativeContextBudgetChars: nativeContextBudgetChars,
                        contextWindowTokens: contextWindow,
                        cutPolicy: nodeCutPolicy
                    )
                    input.projectKnowledge = projectKnowledge
                    input.largeRequestConfirmChars = LargeRequestGate.confirmChars(
                        provider: llmConfig.apiProvider, baseURL: llmConfig.baseURL)

                    // Logs tool names, not just a count. The sampling config is not repeated: the ReAct banner below prints it.
                    let toolNames = activeTools.map(\.name).sorted().joined(separator: ", ")
                    logger.info("[Workflow] AgentInput node='\(workflowContext.nodeName)': tools=\(activeTools.count) [\(toolNames)], generator=\(type(of: generator)), model=\(llmConfig.modelName)")

                    // 8. Execute
                    let executor = ExecutorFactory.create(for: profile)
                    logger.info("[Workflow] Executor: \(executor.executorLabel) for '\(workflowContext.nodeName)'")

                    // EvaluationLogger bridge, as on the chat path: records thought/toolCall/stateChange as span events.
                    let evalSessionID = UUID()
                    if !activeTools.isEmpty {
                        EvaluationLogger.shared.startSession(id: evalSessionID, availableTools: activeTools)
                    }
                    defer {
                        if !activeTools.isEmpty {
                            _ = EvaluationLogger.shared.endSession(id: evalSessionID)
                        }
                    }

                    let traceHandler: @Sendable (AgentTraceLog) -> Void = { log in
                        if !activeTools.isEmpty {
                            EvaluationLogger.shared.logStep(id: evalSessionID, log: log)
                        }
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
        // Cloud arms have no pre-flight chat-only guard: `cognitiveCapability` is set only by local analyzers, so guarding
        // would reject every cloud profile. A 400/422 rejecting tools is classified fatal by ProviderErrorClassifier.
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
            // OpenRouter and custom OpenAI-compatible endpoints share the OpenAI tool encoding and native turn adapter.
            return NativeStructuredGenerator(
                toolAdapter: NativeJSONSchemaAdapter(),
                toolTurnAdapter: OpenAIToolTurnAdapter()
            )

        case .mlx, .ollama:
            let cognitiveProfile = llmConfig.cognitiveProfile
            
            // Primary Routing Dimension: Structural Capability
            switch cognitiveProfile.capability {
            case .none:
                // A capability classification labels, never gates: the run proceeds and a model that cannot call tools fails visibly.
                // Do not reinstate a gate: `ProviderConfig.cognitiveProfile` never persists `toolSupportCaveat`.
                if !isBotFlow {
                    logger.warning(
                        "[AGENT] Running an AGENT turn on \(llmConfig.apiProvider.rawValue) model "
                        + "'\(llmConfig.modelName)' whose detected capability is .none — detection "
                        + "believes it cannot call tools. CONSEQUENCE: proceeding anyway (the verdict "
                        + "is a heuristic and the user may have overridden it); tool calls may be "
                        + "emitted as plain text or rejected by the server with a 400. This is no "
                        + "longer refused up front — see AgentConnect G94."
                    )
                }
                return JsonStructuredGenerator()
                
            case .singleAction:
                // Dialect matching for single-action text constraints; the default is ReAct Markdown, the most universal format
                // for weak or unknown models.
                switch cognitiveProfile.dialect {
                case .mistralXML:
                    return XMLStructuredGenerator()
                default:
                    return MarkdownStructuredGenerator()
                }
                
            case .parallelActions:
                // Ollama: the API abstracts the model's native format, so always use NativeStructuredGenerator.
                // MLX: no intermediary API; the generator must match the model's trained dialect via chat_template.
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
                        // Legacy hybrid-XML path for models classified as mistralXML; emits <tool_call><content>/<tool_name>/<arguments>.
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
        // Never send one vendor's key to another (see `ProviderKeyShape`). Checked before any
        // provider is built, so no request — model list or generation — can carry it.
        if let keyVendor = ProviderKeyShape.mismatchedVendor(key: llmConfig.apiKey, provider: llmConfig.apiProvider) {
            logger.error("[SECRETS] REFUSED to send a \(keyVendor.rawValue)-shaped API key to \(llmConfig.apiProvider.rawValue). CONSEQUENCE: no request was made; the profile needs a \(llmConfig.apiProvider.rawValue) key.")
            throw NSError(domain: "AgentConnect", code: 401, userInfo: [NSLocalizedDescriptionKey:
                ProviderKeyShape.refusalMessage(keyVendor: keyVendor, provider: llmConfig.apiProvider)])
        }
        let rlKey = RateLimitCategory.deriveBucketKey(
            provider: llmConfig.apiProvider,
            apiKey: llmConfig.apiKey,
            baseURL: llmConfig.baseURL,
            modelName: llmConfig.modelName
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
            
            // Ollama options are resolved by `OllamaRequestOptions`, so the request and the context budgets share one resolver.
            // `isBotFlow` picks the ladder: the agent preset would pin a bot to temperature 0.1 with a fixed seed.
            let flavour: OllamaConfigDefaultProfile = isBotFlow ? .chat : .agent
            let resolvedOptions = OllamaRequestOptions.resolve(
                stored: llmConfig.advancedConfiguration,
                metadata: llmConfig.modelMetadata,
                modelName: llmConfig.modelName,
                flavour: flavour,
                numCtxOverride: llmConfig.numCtxOverride
            )
            let options = resolvedOptions.options

            if let applied = resolvedOptions.presetApplied {
                logger.info("""
                    [PROFILE] No stored advanced configuration for Ollama model \
                    '\(llmConfig.modelName)' — applying the \(applied == .agent ? "agent" : "chat") \
                    preset the Advanced panel displays. CONSEQUENCE: the request now matches what \
                    the UI shows instead of falling back to Ollama's own sampling defaults.
                    """)
            }
            if let auto = resolvedOptions.autoNumCtx {
                logger.info("[num_ctx] Auto-defaulting num_ctx=\(auto) for '\(llmConfig.modelName)' (no user-configured value).")
            }
            // The window every budget in this run will be sized against — logged so a truncated
            // prompt can be diagnosed from the log alone instead of inferred from a short reply.
            logger.info("[num_ctx] '\(llmConfig.modelName)' runs under num_ctx=\(OllamaContextWindowPolicy.configuredNumCtx(in: options).map(String.init) ?? "server default (~\(OllamaContextWindowPolicy.assumedServerDefault))") — source: \(resolvedOptions.overrideNumCtx != nil ? "Code context size (per project)" : (resolvedOptions.presetApplied != nil ? "\(flavour == .agent ? "agent" : "chat") preset" : (llmConfig.advancedConfiguration != nil ? "profile Advanced settings" : "auto-default"))). CONSEQUENCE: the context gauge, the compaction budget and the native-turn budget all price against this exact number; a prompt exceeding it is HEAD-truncated by Ollama, system instructions first, with no error.")

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
                // OpenRouter attribution: both headers are static project identifiers;
                // nothing about the user, machine or prompt is sent.
                extraHeaders: [
                    "X-Title": "Devgentic",
                    "HTTP-Referer": GlobalConstants.homepageURL,
                ]
            )
            // Must match the category AgentConnect's executor uses for the same `rlKey` — the
            // first caller to touch a bucket fixes its rate, and `:free` models get the 20 RPM one.
            return OpenAILLMProvider(
                config: config,
                providerCategory: RateLimitCategory.from(provider: .openRouter, modelName: llmConfig.modelName)
            )

        case .openAICompatible:
            // Any OpenAI-compatible endpoint (LM Studio, vLLM, llama.cpp server, Groq, DeepSeek, ...). Base URL is required;
            // the API key is optional, and a nil key omits the Authorization header in OpenAILLMProvider.
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

            // Uses the native Gemini API shape exclusively (avoids 429 schema errors); the host is the configured base URL,
            // so a gateway-scoped key is only sent to the configured gateway.
            let googleBaseURL = ProviderDefaults
                .resolvedBaseURL(configured: llmConfig.baseURL, fallback: ProviderDefaults.geminiBaseURL)
                .appendingPathComponent("models/\(llmConfig.modelName)")
            var options: [String: JSONValue]? = nil
            if let advConfig = llmConfig.advancedConfiguration {
                options = advConfig
            } else {
                // Advanced-config default (see the Ollama arm): the panel shows these values on an unconfigured profile,
                // so they are sent rather than leaving the account defaults in effect.
                options = AdvancedConfigEncoder.encode(GeminiAdvancedConfig.default())
                logger.info("""
                    [PROFILE] No stored advanced configuration for Gemini model \
                    '\(llmConfig.modelName)' — applying the defaults the Advanced panel displays, \
                    including its safety thresholds. CONSEQUENCE: the request now matches the UI \
                    instead of silently using account defaults.
                    """)
            }
            let config = LLMProviderConfig(apiKey: apiKey, baseURL: googleBaseURL, modelName: llmConfig.modelName, timeout: 300.0, options: options, rateLimitKey: rlKey)
            return GeminiLLMProvider(config: config)
            
        case .mlx:
            let modelName = llmConfig.modelName
            // `ensureLoaded()` rather than a fire-and-forget refresh: the scan is off-actor, so an immediate read could see an
            // empty list and fail the turn with a 404 for an installed model.
            await MLXModelService.shared.ensureLoaded()
            let modelPath: URL? = await MainActor.run {
                MLXModelService.shared.installedModel(named: modelName)?.localPath
            }
            guard let path = modelPath else {
                throw NSError(domain: "AgentConnect", code: 404, userInfo: [NSLocalizedDescriptionKey: "Local MLX model '\(modelName)' not found."])
            }
            try await MLXService.shared.loadModel(from: path)

            // MLX advanced parameters come from the stored configuration, else model-aware defaults by tier and quantization.
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
                    return .recommended(for: metadata, profile: isBotFlow ? .chat : .agent)
                }
                return .default()
            }()

            return MLXLLMProvider(
                modelName: modelName,
                // Pin the provider to the model we just resolved and loaded, so a lazy
                // reload cannot substitute whatever another caller loaded meanwhile.
                modelDirectory: path,
                dialect: llmConfig.cognitiveProfile.dialect,
                chatTemplateSource: llmConfig.cognitiveProfile.chatTemplateSource,
                stopSequences: llmConfig.cognitiveProfile.stopSequences,
                advancedConfig: mlxConfig
            )
        }
    }
    
    // MARK: - Tool Resolution
    
    /// Names a configured tool may never take, because `AgentConnect` injects a tool under each.
    /// Derived from `NativeToolCatalog.injectedToolNames`, never written out by hand; internal so tests can reach it.
    static var reservedInjectedToolNames: Set<String> { NativeToolCatalog.injectedToolNames }

    /// What `deduplicatingToolNames` kept and why it dropped the rest.
    struct ToolNameDeduplication {
        var kept: [AgentTool] = []
        /// Names a later tool repeated; the first registration won.
        var duplicates: [String] = []
        /// Configured tools dropped because their name is reserved for an injected tool.
        var shadowingReserved: [String] = []
    }

    /// Deduplicates tool names, reserving injected names against configured tools.
    /// `firstConfiguredIndex` splits the list: tools before it were injected by `resolveExecutableTools` (`ask_user`,
    /// `load_skill`) and keep their names; a tool at or after it is user-configured and may not take one.
    static func deduplicatingToolNames(
        _ tools: [AgentTool],
        firstConfiguredIndex: Int,
        reserved: Set<String> = reservedInjectedToolNames
    ) -> ToolNameDeduplication {
        var result = ToolNameDeduplication()
        var seen = Set<String>()
        for (index, tool) in tools.enumerated() {
            if index >= firstConfiguredIndex, reserved.contains(tool.name) {
                result.shadowingReserved.append(tool.name)
                continue
            }
            guard seen.insert(tool.name).inserted else {
                result.duplicates.append(tool.name)
                continue
            }
            result.kept.append(tool)
        }
        return result
    }

    func resolveExecutableTools(
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
        modelTier: ModelTier = .medium,
        /// Correlation only — carried so an unresolved-tool error names the profile that asked
        /// for it. Without it a "capability silently missing" log cannot be traced to a profile.
        profileID: UUID? = nil
    ) async -> [AgentTool] {

        var activeTools: [AgentTool] = []

        // Small/tiny local models fumble the optional `options`/`multiline` fields, so only `question` is advertised to them.
        let askUserRichFields = !(modelTier == .small || modelTier == .tiny)
        activeTools.append(wrapTool(AskUserTool(richFields: askUserRichFields), requiresConfirmation: false))

        if let manifests = skillManifests, !manifests.isEmpty {
            let loadSkillTool = LoadSkillTool(manifests: manifests)
            activeTools.append(wrapTool(loadSkillTool, requiresConfirmation: false))
            logger.info("Registered load_skill tool with \(manifests.count) available skill(s)")
        }

        let allToolSources = await UnifiedToolStore.shared.sources

        // Everything from here on is a user-configured tool; everything before is injected.
        let firstConfiguredToolIndex = activeTools.count

        var unresolved: [String] = []
        for toolConfig in profileTools where toolConfig.isEnabled {
            // Resolve by source, and only within that source: MCP servers choose their own tool names, so a same-named
            // tool from another source is a different program.
            let isBuiltIn = toolConfig.sourceId == ToolSource.builtInSourceID

            // Skip tools from a disabled server before resolving: a deliberately disabled server is not a dropped capability
            // and must not be reported as one.
            if !isBuiltIn,
               let source = allToolSources.first(where: { $0.id == toolConfig.sourceId }),
               !source.isEnabled {
                logger.info("""
                    [TOOLRESOLVE] '\(toolConfig.name)' skipped — server '\(source.serverName)' \
                    (\(source.id)) is DISABLED by the user. This is deliberate, not a failure: the \
                    agent runs without this tool until the server is re-enabled. [conv \(conversationID)]
                    """)
                continue
            }

            // Resolves strictly within the declared source, with no cross-source fallback: a missing tool is dropped and reported.
            // Built-ins resolve through the declared rename map between catalogue versions.
            let resolved: AgentTool? = isBuiltIn
                ? self.resolveNativeTool(toolName: toolConfig.name, conversationID: conversationID, requiresConfirmation: toolConfig.requiresConfirmation, timeout: toolConfig.timeout, timeoutMessage: toolConfig.timeoutMessage)
                : self.resolveMCPTool(toolConfig: toolConfig, availableSources: allToolSources, conversationID: conversationID)

            if let agentTool = resolved {
                activeTools.append(agentTool)
                logger.debug("[TOOLRESOLVE] \(isBuiltIn ? "native" : "MCP") '\(toolConfig.name)' enabled from source \(toolConfig.sourceId) (confirm: \(toolConfig.requiresConfirmation)) [conv \(conversationID)]")
            } else {
                // A silent capability drop: the profile asked for this tool and the agent runs without it; it is collected
                // into `unresolved` and reported loudly below.
                unresolved.append(toolConfig.name)

                // Names the other side explicitly when it would have matched, so the user can re-add the tool from the Tool Library.
                let shadowCandidate: String? = isBuiltIn
                    ? (allToolSources.first { $0.id != ToolSource.builtInSourceID && $0.tools.contains { $0.name == toolConfig.name } }
                        .map { "MCP server '\($0.serverName)' (\($0.id))" })
                    : (NativeToolCatalog.entry(named: toolConfig.name) != nil ? "the built-in catalogue" : nil)

                if let shadowCandidate {
                    logger.error("""
                        [TOOLRESOLVE] ⚠️ '\(toolConfig.name)' NOT RESOLVED from its declared \
                        \(isBuiltIn ? "built-in source" : "MCP source \(toolConfig.sourceId)") — the agent \
                        will run WITHOUT this capability. A tool of the SAME NAME exists in \
                        \(shadowCandidate), and it is deliberately NOT substituted: a same-named tool \
                        from a different source is a different implementation with different limits \
                        (sandboxing, allow-lists, credentials). To use that one, add it from the Tool \
                        Library so the profile declares its real source. \
                        [profile \(profileID?.uuidString ?? "unknown") conv \(conversationID)]
                        """)
                } else {
                    logger.error("""
                        [TOOLRESOLVE] ⚠️ '\(toolConfig.name)' NOT RESOLVED — the agent will run WITHOUT \
                        this capability. \(isBuiltIn ? "`NativeToolCatalog`" : "MCP source \(toolConfig.sourceId)") \
                        does not know the name, and no other source offers it either. Usual cause: a \
                        tool deleted or renamed since this profile was saved. \
                        [profile \(profileID?.uuidString ?? "unknown") conv \(conversationID)]
                        """)
                }
            }
        }
        if !unresolved.isEmpty {
            // Summary line so one grep answers "did this run lose anything?" without reading
            // every per-tool line.
            logger.error("[TOOLRESOLVE] \(unresolved.count) of \(profileTools.filter(\.isEnabled).count) enabled tool(s) unresolved: \(unresolved.sorted().joined(separator: ", ")) [conv \(conversationID)]")
        }

        // Enforces name uniqueness before anything reaches a provider (Anthropic rejects duplicate tool names outright).
        // Keeps the first occurrence, built-ins first; injected names are reserved and win over configured tools.
        let deduplicated = Self.deduplicatingToolNames(activeTools, firstConfiguredIndex: firstConfiguredToolIndex)
        activeTools = deduplicated.kept
        let duplicates = deduplicated.duplicates
        let shadowingReserved = deduplicated.shadowingReserved
        if !shadowingReserved.isEmpty {
            logger.error("""
                [TOOLRESOLVE] ⚠️ Dropped \(shadowingReserved.count) configured tool(s) whose name \
                Devgentic reserves for a tool it injects itself: \(shadowingReserved.sorted().joined(separator: ", ")). \
                CONSEQUENCE: the built-in keeps the name and the configured tool is unreachable this \
                run — two tools sharing a name fail the whole request on Anthropic and crashed every \
                other provider. Rename the tool on its MCP server to use it. \
                [profile \(profileID?.uuidString ?? "unknown") conv \(conversationID)]
                """)
        }
        if !duplicates.isEmpty {
            logger.error("""
                [TOOLRESOLVE] ⚠️ Dropped \(duplicates.count) tool(s) whose name was already taken: \
                \(duplicates.sorted().joined(separator: ", ")). Tool names must be unique per \
                request — providers reject duplicates outright, which would have failed EVERY \
                turn in this conversation, not just calls to the colliding tool. The first \
                registration won; rename the tool on the MCP server to expose both. \
                [profile \(profileID?.uuidString ?? "unknown") conv \(conversationID)]
                """)
        }

        // Agent delegation is withdrawn: the stored config is logged and ignored, never rewritten,
        // while `agentDelegationSupported` is false.
        if !Self.agentDelegationSupported, agentCapabilities?.agentDelegation != nil {
            logger.notice("""
                [PROFILE] Ignoring the stored Agent Delegation configuration — the capability is \
                withdrawn (register B15) and `call_agent` is NOT being injected. CONSEQUENCE: this \
                agent runs without sub-agents; its stored settings are preserved untouched, and the \
                Capabilities card offers a one-way switch to clear them.
                """)
        }

        if Self.agentDelegationSupported,
           let delegation = agentCapabilities?.agentDelegation,
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
    
    /// Wraps a DevgenticTool into an AgentTool with a type-erased execution closure.
    /// Thin alias for `AgentToolFactory.wrap`, used for the injected control-plane tools built with run-scoped data.
    private func wrapTool<T: DevgenticTool>(_ tool: T, requiresConfirmation: Bool, timeout: TimeInterval? = nil, timeoutMessage: String? = nil) -> AgentTool {
        AgentToolFactory.wrap(tool, requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
    }

    /// Wraps an already-erased `AgentTool` (the MCP path) with this profile's settings.
    private func wrapTool(_ tool: AgentTool, requiresConfirmation: Bool, timeout: TimeInterval? = nil, timeoutMessage: String? = nil) -> AgentTool {
        AgentToolFactory.rewrap(tool, requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
    }

    // MARK: - Code project knowledge

    /// `remember`, `forget` and `recall` for a Code profile with a folder; empty for anything else.
    /// `messageID` is the answer the run streams into; each change is recorded against it so that
    /// answer can show "Saved 1 memory" and undo it.
    static func codeMemoryTools(for details: ProfileDetails, conversationID: UUID, messageID: UUID?) -> [AgentTool] {
        guard case .code(let config) = details, let projectPath = config.projectPath else { return [] }
        let remember = RememberTool(projectPath: projectPath, conversationID: conversationID, messageID: messageID)
        let forget = ForgetTool(projectPath: projectPath, conversationID: conversationID, messageID: messageID)
        let recall = RecallTool(projectPath: projectPath)
        // Goes through `ReportOnlyRun` here so no caller can hand an unwatched run `remember`/`forget`;
        // attended runs are unchanged.
        return ReportOnlyRun.allowedInjectedTools([
            AgentToolFactory.wrap(remember, requiresConfirmation: CodeToolPreset.injectedToolRequiresConfirmation(remember.name)),
            AgentToolFactory.wrap(forget, requiresConfirmation: CodeToolPreset.injectedToolRequiresConfirmation(forget.name)),
            AgentToolFactory.wrap(recall, requiresConfirmation: CodeToolPreset.injectedToolRequiresConfirmation(recall.name)),
        ])
    }

    // Why: kept as its own layer (`AgentInput.projectKnowledge`), not appended to the instructions;
    // its text changes with every saved memory.
    /// A Code run's project knowledge: the project's `AGENTS.md` and memory listing, read from disk on each run.
    /// Nil when the project has neither, or the run has no folder.
    static func codeProjectKnowledge(_ config: AgentConfig, traceTag: String) -> String? {
        guard let projectPath = config.projectPath else { return nil }
        let knowledge = CodeSystemPrompt.projectKnowledge(forProject: projectPath, apiProvider: config.llmConfig.apiProvider)
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        if let section = knowledge.section {
            logger.info("[CODE] Project knowledge for '\(name)' added to the prompt — \(section.count) chars (AGENTS.md + \(knowledge.memoryEntries) memory entr(ies)), trace \(traceTag).")
        } else {
            logger.info("[CODE] '\(name)' has no AGENTS.md and no memory entries — nothing added, trace \(traceTag).")
        }
        return knowledge.section
    }

    // MARK: - Native Tool Resolution
    
    /// Resolves a native tool by name through `NativeToolCatalog`, the only place a native tool is declared.
    /// Decides only which per-profile settings to hand the tool.
    func resolveNativeTool(toolName: String, conversationID: UUID, requiresConfirmation: Bool, timeout: TimeInterval? = nil, timeoutMessage: String? = nil) -> AgentTool? {
        guard let entry = NativeToolCatalog.entry(named: toolName) else { return nil }
        return entry.agentTool(
            conversationID: conversationID,
            requiresConfirmation: requiresConfirmation,
            timeout: timeout,
            timeoutMessage: timeoutMessage
        )
    }

    func resolveMCPTool(toolConfig: Tool, availableSources: [ToolSource], conversationID: UUID) -> AgentTool? {
        guard let source = availableSources.first(where: { $0.id == toolConfig.sourceId }),
              let definition = source.tools.first(where: { $0.name == toolConfig.name }) else {
            return nil
        }

        // A disabled server contributes nothing; its rows stay in the Tool Library so the user can switch it back on.
        guard source.isEnabled else {
            logger.info("""
                [TOOLRESOLVE] '\(toolConfig.name)' skipped — its server '\(source.serverName)' \
                (\(source.id)) is disabled by the user. The agent runs without this tool by \
                design; re-enable the server in the Tool Library to restore it. [conv \(conversationID)]
                """)
            return nil
        }

        // Ties this source to the conversation now: a server's later sampling/elicitation request carries neither.
        // Fire-and-forget on the main actor is fine; the association only has to exist before the server issues a request.
        let sourceID = source.id
        Task { @MainActor in
            MCPSamplingBroker.shared.noteActivity(sourceID: sourceID, conversationID: conversationID)
            MCPElicitationBroker.shared.noteActivity(sourceID: sourceID, conversationID: conversationID)
        }

        // Synthetic resource/prompt tools have no server-side counterpart — `tools/call`
        // with these names would fail. Route them to the resource/prompt executor instead.
        if let kind = MCPSyntheticTool.kind(fromQualified: definition.name) {
            return wrapTool(
                MCPResourcePromptTool(source: source, definition: definition, kind: kind),
                requiresConfirmation: toolConfig.requiresConfirmation,
                timeout: toolConfig.timeout,
                timeoutMessage: toolConfig.timeoutMessage
            )
        }

        return wrapTool(DynamicMCPTool(source: source, toolDefinition: definition), requiresConfirmation: toolConfig.requiresConfirmation, timeout: toolConfig.timeout, timeoutMessage: toolConfig.timeoutMessage)
    }

    // MARK: - Logging Helper
    
    /// The `Metadata:` line of the configuration banner.
    /// Quantization and family come only from local analyzers; a cloud model's tier is the seeded default and is labelled so.
    static func metadataSummary(for config: ProviderConfig) -> String {
        let meta = config.modelMetadata
        let window = meta?.contextWindow.map { "\($0.formatted()) token window" } ?? "window unknown"
        if ProviderClass(apiProvider: config.apiProvider) == .cloud {
            return "cloud model, \(window) (tier: default \(meta?.tier.rawValue ?? ModelTier.medium.rawValue); quantization/family not applicable)"
        }
        guard let meta else { return "None" }
        return "\(meta.tier.rawValue) tier, \(meta.quantization ?? "unknown quant"), \(meta.family ?? "unknown family"), \(window)"
    }

    /// Logs the complete configuration for tracking and debugging purposes.
    private func logFullConfiguration(
        profile: BackendProfileModel,
        config: ProviderConfig,
        isBotFlow: Bool,
        tools: [AgentTool],
        instructions: String?
    ) {
        let toolNames = tools.isEmpty ? "None" : tools.map { $0.name }.joined(separator: ", ")
        let metadata = Self.metadataSummary(for: config)

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
                let rec = MLXAdvancedConfig.recommended(for: meta, profile: .forProfileType(profile.profileType))
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
        Tools Enabled (pre-flight — see the [TOOLS] line for the final loadout): [\(toolNames)]
        System Instructions: \(instructions.map { "\($0.count) chars" } ?? "None")
        -----------------------------------------
        """
        logger.notice("\(logMsg)")
    }

    /// Returns the dialect label used in the startup config log: cloud providers speak native JSON, local providers
    /// surface the dialect stored on `ProviderConfig`, and `.none` capability uses the heuristic JSON fallback.
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

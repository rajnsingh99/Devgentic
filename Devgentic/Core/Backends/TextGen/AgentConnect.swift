// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// Whether agent delegation (`call_agent` / sub-agents) is available at all. Register B15.
    ///
    /// ⚠️ **Deliberately `false`.** The capability was withdrawn from the UI, but the runtime gate
    /// is the mere PRESENCE of `capabilities.agentDelegation` — there is no `isEnabled` flag — so
    /// legacy "Supervisor" profiles kept injecting `call_agent` forever with no control and no
    /// indication. Withdrawing a toggle is only half a decision; this is the other half.
    ///
    /// One constant so restoring the feature is one line, not an archaeology exercise. Same shape
    /// as `PlanningCapability.parallelSubtasksSupported` (register A67), and the same reason: a
    /// stored preference is ignored, never rewritten.
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
        
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 1. Extract Configuration & Tools based on Profile Type
                    let llmConfig: ProviderConfig
                    var instructions: String?
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
                        // Dual-read cut-over (v8): references resolve against the global registry,
                        // and a profile that predates v8 falls back to its blob's manifest copies.
                        // ⚠️ The registry is authoritative for `description` — the text the model
                        // ROUTES on — so a skill edited on disk now changes every linked profile at
                        // once instead of only whichever one last pressed Rescan.
                        skillManifests = await MainActor.run {
                            SkillResolution.resolve(for: config, profileName: profile.displayName)?.manifests
                        }

                    case .workflow:
                        // Workflow: each node resolves its own model, tools, and generator.
                        // Bypass the single-model pipeline entirely. Layout is the source of truth.
                        // Workflows have no layered per-node prompt for chat context, and the
                        // engine merges userInput into the FIRST node's task only — so knowledge
                        // and attachment payloads must ride userInput here or they'd be dropped.
                        // ⚠️ THE FUSION IS GONE (2026-08-20). This used to build
                        // `[knowledgeBase, attachments, userInput].joined()` and pass the result as
                        // `userInput`, because a node had no other route to those payloads. The
                        // entry-node merge then folded that whole string into `taskDescription`, so
                        // `<task>` — the first and most heavily attended section of the prompt —
                        // opened with reference material and buried the real question at the end.
                        // A 3B model derailed on it five times running and the workflow aborted,
                        // while the SAME agent profile answered fine in chat, where the identical
                        // payloads sit in their own labelled sections.
                        //
                        // Attachments now travel their own channel to the ENTRY node and render as
                        // `<attachments>`. Profile knowledge does NOT ride along: `WorkflowConfig`
                        // has no `knowledgeSources` field, so a workflow profile cannot define any
                        // — the old `kb` term here was always nil for the workflow arm.
                        let workflowExecutor = WorkflowExecutor(workflowProfileID: profile.id)
                        // ⚠️ `chatHistory`/`ragContext` are deliberately NOT passed and no longer
                        // exist on this signature (register EXA-9): a workflow run is
                        // conversation-stateless by design and consumed neither at any depth. Both
                        // are still in scope on this arm for the chat path above; passing them here
                        // advertised a capability the engine does not have.
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
                        rawTools = config.tools
                        isBotFlow = false
                        // ⚠️ Code profiles do NOT get skills, and this is a decision, not an
                        // oversight — but persistence disagrees with it: the `.code` arm of
                        // ProfileDetails encodes and decodes `skillConfig` like any other, so a
                        // profile converted from `.agent`, or one written by an older build, can
                        // carry skills the runtime then discards here in silence. The config
                        // editor never offers the section for `.code` (its binding matches
                        // `case .agent` only), so a user in this state has no way to see it.
                        // Logged rather than honoured: turning it on is a product decision about
                        // Code mode's ephemeral profile identity, not a bug fix.
                        skillManifests = nil
                        // ⚠️⚠️ READ BOTH SHAPES. This looked ONLY at `config.skillConfig?.manifests`
                        // — the pre-V6 blob — so after the migration moved every profile's skills
                        // into `skillSelections` it could never fire again. The one state it exists
                        // to make visible, a Code profile carrying skills the runtime discards, went
                        // silent for exactly the profiles that reach it. The legacy arm stays for a
                        // profile that has not been through the sweep.
                        let unique = CodeModeSkillDiagnostics.inertSkillNames(in: config)
                        if !unique.isEmpty {
                            logger.notice("[CODE] Profile carries \(unique.count) enabled skill(s) that Code mode does NOT load: \(unique.joined(separator: ", ")). CONSEQUENCE: they are absent from <available_skills> and `load_skill` is not registered, so the model cannot reach them — the skills are configured but inert. Move the work to an Agent profile if they are needed.")
                        }
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
                    // EFFECTIVE window (num_ctx-aware for Ollama, 8K local fallback) —
                    // sizing compaction and native-turn budgets to a 128K assumption on
                    // a ~4-8K local allocation meant turn arrays never compacted and
                    // Ollama truncated silently mid-run.
                    let contextWindow = EffectiveContextWindow.resolve(
                        for: llmConfig, flavour: isBotFlow ? .chat : .agent)
                    // Empty (not a sentinel) when nothing was retrieved — PromptBuilder
                    // skips the <semantic_context> layer for empty grounding, so non-RAG
                    // turns no longer carry a hollow "No static context provided." block.
                    let staticGrounding = ragContext ?? ""

                    // Long-term grounding is pre-fetched RAG, injected into the prompt. There is
                    // no tier branch: the "deep memory tools" axis and its `ToolAugmentedMemory`
                    // strategy were removed 2026-07-31 with the only tool that populated them
                    // (`read_session_history`) — see `LongTermMemoryStrategy` for why.
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

                    // Extract capabilities for tool injection (delegation)
                    // ⚠️ register B44 — was `if case .agent … else { nil }`, which dropped `.code`.
                    // Latent rather than live (a Code session's `AgentCapabilities()` is all-nil,
                    // so nil and default behaved alike), but it is the same omission as the four
                    // below and would go live the moment a Code session enabled planning.
                    let agentCapabilities: AgentCapabilities? = profile.details.agentCapabilities

                    // 5. Resolve Tools (model passed for delegation tool to reuse)
                    // An MCP server's `sampling/createMessage` arrives out-of-band on the client
                    // connection with no conversation attached. Record which profile and model
                    // should service it for this run, so the approval banner can be raised in the
                    // right conversation and the call billed to the profile the user chose.
                    await MCPSamplingBroker.shared.register(context: MCPSamplingContext(
                        conversationID: conversationID,
                        providerConfig: llmConfig,
                        profileID: profile.id,
                        runMessageID: traceContext.messageID,
                        registeredAt: Date()
                    ))

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
                        // ⚠️⚠️ `true` since 2026-09-20. This was the ONE write in Code mode that
                        // ran unreviewed, and it is the only write that outlives the conversation:
                        // `.devgentic/context.md` is injected into the system prompt of every
                        // future conversation for this project. A small model asserting something
                        // false about the code therefore contaminated every later run, with no
                        // banner, no diff and no undo. The banner previews it as a real diff
                        // against the file on disk — see `FileChange.parse`.
                        activeTools.append(self.wrapTool(
                            contextTool,
                            requiresConfirmation: CodeToolPreset.injectedToolRequiresConfirmation(contextTool.name)))
                        logger.info("[CODE] Code tool set assembled — \(activeTools.count) tools so far, incl. final_answer and update_project_context. CONSEQUENCE: this is NOT the final loadout — get_conversation_history is appended later, once the history is known. The authoritative list is the [TOOLS] line below.")
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
                    
                    // #22: native turn-payload budget (~75% of context window as chars).
                    // Distinct from the small scratchpad budget above — the native path
                    // sends the full conversation, so it gets the larger slice; the ReAct
                    // loop compacts oldest tool exchanges past this to bound growth.
                    let nativeContextBudgetChars = PromptFitCheck.nativePayloadCharBudget(forContextWindow: contextWindow)

                    // Resolve history strategy from profile (default: .recentHistory)
                    // ⚠️ register B44 — LIVE defect: `CodeSessionManager` configures
                    // `historyStrategy: .pointer`, and `.code` fell into the `else`, so every Code
                    // session ran on `.recentHistory` instead of the strategy it was built with.
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

                    // Vision gate for PRIOR-TURN images. Carrying history images is
                    // pointless — and actively wasteful of the char budget — when the
                    // target model can't see them, so the decision is made once here,
                    // next to `isNativeProvider`, and the converter stays a pure function.
                    //
                    // Mirrors the current-turn gate in BackendOrchestrationService, with
                    // one deliberate difference: that gate is local-only (cloud is left
                    // to error on its own), whereas this one applies to every provider.
                    // Spending budget on images a model will ignore costs the user real
                    // context either way.
                    let historyImagesEnabled = isNativeProvider && profile.supportsVisionInput
                    if isNativeProvider && !profile.supportsVisionInput {
                        logger.info("[HISTORY] conv:\(conversationID.uuidString.prefix(8)) trace:\(traceContext.traceID) Vision gate: prior-turn images omitted for '\(llmConfig.modelName)' (no visionInput modality) — the model will not see images from earlier turns in this conversation")
                    }

                    // History building is independent of tool availability.
                    // Even tool-less agents benefit from conversation context.
                    var effectiveHistory = chatHistory // Mutable copy — compaction may insert a checkpoint
                    if !effectiveHistory.isEmpty {
                        // Shared with the fit gauges via PromptFitCheck so the number they
                        // report is measured against the same allocation this spends.
                        let charBudget = PromptFitCheck.historyCharBudget(forContextWindow: contextWindow)

                        // --- IC-Powered History Compaction (Background) ---
                        // Moved OFF the request path (2026-07-20). The 30s "timeout" around
                        // the IC call was verified to be a cancellation request, not a
                        // wall-clock bound (cold load and prompt prefill are uninterruptible),
                        // so a synchronous compaction could stall this turn unboundedly. The
                        // only real bound is not entering: this request proceeds with
                        // uncompacted history (the history builders trim to charBudget), the
                        // summarization runs in the background, and the checkpoint — persisted
                        // via the service's sink, never via this stream, which may end first —
                        // pays off from the next turn on. The trigger fires at ~36% of the
                        // context window, so skipping one turn's relief costs little.
                        //
                        // Gated on the Core Intelligence MASTER toggle as well as the feature
                        // toggle. Without the master check, turning Core Intelligence OFF still
                        // loaded the IC model on every long-history turn: the feature key
                        // defaults to true, and its toggle isn't even rendered while the master
                        // switch is off — so the user had no way to see or stop it.
                        let compactionEnabled = UserDefaults.standard.object(forKey: AppSettings.ciFeatureHistoryCompactionKey) as? Bool ?? true
                        let icMasterEnabled = UserDefaults.standard.bool(forKey: AppSettings.isIntelligenceCoreEnabledKey)
                        let icModelSelected = await IntelligenceCoreService.shared.hasModelSelected
                        if compactionEnabled, icMasterEnabled, icModelSelected {
                            if let plan = await HistoryCompactionService.shared.evaluate(
                                chatHistory: effectiveHistory,
                                charBudget: charBudget
                            ) {
                                // No `.compactionStarted` chip in background mode: if the
                                // stream ended before completion, a persisted "Compacting…"
                                // row with no terminal row would read as a hang forever.
                                // The completed/failed chip stands alone; the checkpoint
                                // card in the transcript is the durable evidence.
                                await HistoryCompactionService.shared.scheduleExecution(
                                    plan: plan,
                                    conversationID: conversationID
                                ) { event in
                                    // Best-effort chips only — a yield after the stream
                                    // finishes is a harmless no-op.
                                    continuation.yield(event)
                                }
                                logger.info("[COMPACTION] Scheduled in background — \(plan.turnPairsInBatch) turn pairs, checkpoint #\(plan.checkpointNumber). THIS turn proceeds with uncompacted history (\(effectiveHistory.count) messages, trimmed to budget by the builders); the checkpoint applies from the next turn. conversationID: \(conversationID.uuidString.prefix(8)), traceID: \(traceContext.traceID)")
                            }
                        } else {
                            // Silent-skip logging: the consequence (history stays uncompacted,
                            // so a long conversation is trimmed rather than summarized) is
                            // invisible from the outside otherwise.
                            logger.info("[COMPACTION] Skipped — feature: \(compactionEnabled), ic-master: \(icMasterEnabled), ic-model-selected: \(icModelSelected) → history stays uncompacted (\(effectiveHistory.count) messages), conversationID: \(conversationID.uuidString.prefix(8))")
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
                        // Episodic XML — one dispatch for all four strategies, shared with
                        // the fit gauges so what they measure is what ships.
                        recentHistory = EpisodicHistoryFormatter.build(
                            strategy: historyStrategy,
                            from: effectiveHistory,
                            includeImageNames: profile.supportsVisionInput,
                            effectBudget: ActionEffect.diffBudget(forHistoryCharBudget: charBudget),
                            correlation: "conv:\(conversationID.uuidString.prefix(8)) trace:\(traceContext.traceID)",
                            toolsAvailable: !isBotFlow,
                            // ⚠️ `.live` HERE and nowhere else. It stats each effect's file to
                            // decide whether the stored diff still describes it. This is the
                            // request path — once per send. `ContextWindowGauge` builds the same
                            // XML to SIZE it, on every recompute, and takes the `.unknown`
                            // default so the composer never touches the filesystem.
                            staleness: .live
                        )

                        if isNativeProvider {
                            nativeHistoryTurns = NativeHistoryConverter.build(
                                strategy: historyStrategy,
                                from: effectiveHistory,
                                charBudget: charBudget,
                                includeImages: historyImagesEnabled,
                                correlation: "conv:\(conversationID.uuidString.prefix(8)) trace:\(traceContext.traceID)",
                                // Same value the episodic build above is given. These two are the
                                // only emitters of the `get_conversation_history(N)` instruction,
                                // and they must agree — one gated and one not is how a prompt
                                // comes to contradict itself.
                                toolsAvailable: !isBotFlow
                            )
                        }

                        // Only inject get_conversation_history tool if pointer references
                        // were actually emitted in the built history. This avoids a dead tool
                        // when history is too short for pointers (e.g. hybrid with <= 3 turns).
                        let hasPointers: Bool = {
                            if let turns = nativeHistoryTurns {
                                // Probes the same lowered text the model will see. Previously a
                                // `["content"]?` dict subscript; `HistoryTurn.text` is non-optional,
                                // so the "key absent" case collapses into "empty text" — which
                                // never contained the marker anyway.
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

                    // ⚠️⚠️ THE authoritative tool list, and the only one logged after the last
                    // thing that can append. Both earlier lines — `[CODE] Code tool set
                    // assembled` and the `Tools Enabled` row in the configuration block — fire
                    // BEFORE `get_conversation_history` is added, and both used to read as
                    // complete. Field-observed 2026-09-20: a Code run logged "Tool resolution
                    // complete — 19 tools" with `get_conversation_history` absent, while the
                    // prompt it built told the model "Call get_conversation_history(N) for
                    // details." Delivery was fine — `activeTools` is consumed further down — so
                    // the only thing wrong was the log, which is the thing an operator has.
                    logger.info("[TOOLS] Final loadout for \(profile.profileType.rawValue) run — \(activeTools.count) tool(s): [\(activeTools.map(\.name).joined(separator: ", "))]. CONSEQUENCE: this is exactly what the model is offered; anything named in the prompt but missing here cannot be called.")
                    
                    // Extract resilience config from agent profile
                    // ⚠️ register B44 — THE live defect, and it sat 85 lines above A7's own
                    // `.code` fix in this same function. `.code` fell into the `else`, so a Code
                    // session got `ErrorRecovery()` (`onToolFailure: .abort`) in place of the
                    // `.fallbackPrompt` `CodeSessionManager` configures, and `resilienceOverrides`
                    // was nil so its Loop Safety caps were discarded too — with nothing logged.
                    let retryPolicy = profile.details.retryPolicy
                    let errorRecovery = profile.details.errorRecovery
                    let resilienceOverrides = profile.details.resilienceOverrides

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

                    // Resolve IC-powered response synthesis: strictly opt-in, per provider
                    // family (see SynthesisOptIn). Nothing else may turn it on — tool
                    // failures and circuit-breaker aborts no longer force it.
                    let icAvailable = await IntelligenceCoreService.shared.hasModelSelected
                    let icEnabled = UserDefaults.standard.bool(forKey: AppSettings.isIntelligenceCoreEnabledKey)
                    let synthDecision = SynthesisOptIn.resolved(
                        provider: llmConfig.apiProvider,
                        icModelSelected: icAvailable,
                        icEnabled: icEnabled
                    )
                    let responseSynthesisEnabled = synthDecision.optedIn
                    logger.info("[SYNTH] provider-family: \(synthDecision.family.rawValue), opted-in: \(synthDecision.optedIn) (\(synthDecision.reason)) → \(synthDecision.optedIn ? "IC synthesis pass" : "raw passthrough"), traceID: \(traceContext.traceID), conversationID: \(conversationID.uuidString.prefix(8))")

                    // Only a `.code` profile has a user-chosen folder, so only it is confined.
                    // Every other type resolves to nil, which `WorkspaceBoundaryDecision` reads as
                    // "no boundary" and leaves behaving exactly as before.
                    let codeWorkspaceRoot: String? = {
                        guard case .code(let codeConfig) = profile.details else { return nil }
                        return codeConfig.projectPath
                    }()
                    if let codeWorkspaceRoot {
                        logger.info("[WORKSPACE] Code run confined to \(codeWorkspaceRoot) — conv \(conversationID.uuidString.prefix(8)). CONSEQUENCE: relative tool paths resolve against this folder instead of the home directory; writes outside it are refused and reads outside it ask the user first.")
                    } else if case .code = profile.details {
                        // ⚠️ The state the original escape ran in. A Code profile with no folder is
                        // UNCONFINED — every filesystem tool sees the whole disk and relative paths
                        // fall back to the home directory. It should be unreachable now
                        // (`prepareCodeProfileForSend` refuses, and the composer blocks on a missing
                        // folder), so if this ever prints, one of those guards has a hole.
                        logger.error("[WORKSPACE] Code run has NO project folder — conv \(conversationID.uuidString.prefix(8)). CONSEQUENCE: this run is UNCONFINED — no path is checked, nothing is refused, and a relative path resolves against the home directory. A send should have been refused before reaching here.")
                    }

                    // Working memory (the scratchpad the text-tools path carries — MLX, and Ollama
                    // models without tool calling) gets WHATEVER ROOM THE FIXED PROMPT LEAVES. Built
                    // here, after history and every context block exist, because those are exactly
                    // what it must be sized around. See `MemoryBudgetConfig.derive`.
                    let reservedPromptChars = (instructions?.count ?? 0)
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

                    let input = AgentInput(
                        userInput: userInput,
                        userPayload: userPayload,
                        attachmentContext: attachmentContext,
                        knowledgeBaseContext: knowledgeBaseContext,
                        toolGuidanceContext: toolGuidanceContext,
                        chatHistory: chatHistory,
                        // Vision BOTS re-attach prior-turn images (ChatExecutor reads
                        // chatHistory). Gated on vision alone — NOT tool capability —
                        // because a vision model can see images regardless of whether it
                        // supports tools (qwen2.5vl etc. are vision-but-.none → Bot-only).
                        // Non-vision → false → history images omitted (safe on model swap).
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

                    // 8. Execute & Stream
                    let traceHandler: @Sendable (AgentTraceLog) -> Void = { log in
                        logger.debug("[\(log.state.headline)] \(log.content) (span: \(log.spanID))")
                        if !activeTools.isEmpty {
                            EvaluationLogger.shared.logStep(id: evalSessionID, log: log)
                        }
                        onTraceUpdate?(log)
                    }
                    
                    try Task.checkCancellation()

                    // Execution timeout from the profile's agent configuration.
                    //
                    // ⚠️ `.code` carries an `AgentConfig` too and MUST be matched. It used to fall
                    // into an `else`, so a Code session's persisted `executionTimeout` (300 s, set
                    // by `CodeSessionManager`) was silently discarded and the run had NO wall-clock
                    // bound at all (register A7).
                    //
                    // ⚠️ register B44 — A7's fix was an exhaustive `switch` written HERE, at the one
                    // site the row named, while four more sites in this same file kept the `if case
                    // .agent … else` shape and kept dropping `.code`. Fixing the site rather than
                    // the class is why the trap survived. The switch now lives once, in
                    // `ProfileDetails.agentConfig`, and every agent-setting accessor derives from it.
                    let executionTimeout: TimeInterval? = profile.details.executionTimeout

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

                    let stream = executor.execute(model: model, input: input, onTraceUpdate: traceHandler)

                    let finalOutputAccumulator: String

                    if let timeout = executionTimeout {
                        // Enforce execution timeout via Task race.
                        // The typed TaskGroup returns the accumulated output from whichever
                        // task completes first, avoiding shared mutable state across tasks.
                        let timeoutConversationID = conversationID
                        let timeoutSubject = "Conversation \(conversationID.uuidString.prefix(8)) (\(profile.profileType.rawValue))"
                        finalOutputAccumulator = try await withThrowingTaskGroup(of: String.self) { group in
                            // Timeout sentinel.
                            //
                            // ⚠️⚠️ This raced a bare `Task.sleep(for: .seconds(timeout))` until now,
                            // which charged HITL wait time against the execution budget. Tool
                            // confirmations park INSIDE this raced task (`ToolExecutionLoop` awaits
                            // `ExecutionSuspensionService.suspend`), so the clock ran while the user
                            // read an approval banner — a run could die at 300 s having computed for
                            // 90. `WorkflowExecutor.computeTimeoutSentinel` fixed exactly this for
                            // workflow nodes on 2026-08-13 and its own doc comment called the profile
                            // path's plain sleep "a live defect", but the fix never crossed over.
                            // Both paths now call the same sentinel, which bounds COMPUTE and extends
                            // itself by whatever was parked.
                            group.addTask {
                                try await ComputeTimeoutSentinel.sleepUntilComputeExceeded(
                                    limit: timeout,
                                    conversationID: timeoutConversationID,
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
                        // Dual-read cut-over (v8): references resolve against the global registry,
                        // and a profile that predates v8 falls back to its blob's manifest copies.
                        // ⚠️ The registry is authoritative for `description` — the text the model
                        // ROUTES on — so a skill edited on disk now changes every linked profile at
                        // once instead of only whichever one last pressed Rescan.
                        skillManifests = await MainActor.run {
                            SkillResolution.resolve(for: config, profileName: profile.displayName)?.manifests
                        }

                    case .code(let config):
                        llmConfig = config.llmConfig
                        instructions = config.instructions
                        rawTools = config.tools
                        isBotFlow = false
                        // Same deliberate exclusion as the chat path above; see the note there.
                        skillManifests = nil
                        if let orphaned = config.skillConfig?.manifests.filter(\.isEnabled), !orphaned.isEmpty {
                            logger.notice("[CODE] Workflow-node Code profile carries \(orphaned.count) enabled skill(s) that Code mode does NOT load: \(orphaned.map(\.name).joined(separator: ", ")). CONSEQUENCE: they are absent from <available_skills> and unreachable by the model for this node.")
                        }

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
                    // ⚠️ register B44 — the fifth copy, in closure form. Same omission.
                    let agentCapabilities: AgentCapabilities? = profile.details.agentCapabilities

                    let rateLimitCategory = RateLimitCategory.from(provider: llmConfig.apiProvider)
                    let rateLimitKey = RateLimitCategory.deriveBucketKey(
                        provider: llmConfig.apiProvider,
                        apiKey: llmConfig.apiKey,
                        baseURL: llmConfig.baseURL
                    )

                    // An MCP server's `sampling/createMessage` arrives out-of-band on the client
                    // connection with no conversation attached. Record which profile and model
                    // should service it for this run, so the approval banner can be raised in the
                    // right conversation and the call billed to the profile the user chose.
                    await MCPSamplingBroker.shared.register(context: MCPSamplingContext(
                        conversationID: conversationID,
                        providerConfig: llmConfig,
                        profileID: profile.id,
                        runMessageID: traceContext.messageID,
                        registeredAt: Date()
                    ))

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

                    // 6.5 Inject `final_answer` terminator for workflow nodes that run on
                    // ReAct (agent/code profiles). Mirrors the streaming chat path —
                    // workflow node output relies on `finalAgentThought`, which is
                    // populated cleanly when the model calls `final_answer`.
                    if !isBotFlow {
                        let finalAnswerTool = self.wrapTool(FinalAnswerTool(), requiresConfirmation: false)
                        activeTools.insert(finalAnswerTool, at: 0)
                    }

                    // 7. Build AgentInput — workflow-aware, no history/RAG/compaction
                    //
                    // ⚠️ ONE CHANNEL (2026-08-29). This used to branch on `isFirstNode` between
                    // `taskDescription` and `upstreamInput` — the two-channel model. The executor
                    // now resolves that question at the graph, so the node's input is simply its
                    // input, and this seam has nothing left to decide.
                    let userInputForNode = workflowContext.input

                    // EFFECTIVE window — see the main-path note; workflow nodes get the
                    // same num_ctx-aware sizing so per-node budgets match reality.
                    let contextWindow = EffectiveContextWindow.resolve(
                        for: llmConfig, flavour: isBotFlow ? .chat : .agent)
                    let modelTier = llmConfig.modelMetadata?.tier ?? .medium
                    // #22: native turn-payload budget (~75% of context window as chars) —
                    // bounds liveConversationTurns growth on workflow agent nodes too.
                    let nativeContextBudgetChars = PromptFitCheck.nativePayloadCharBudget(forContextWindow: contextWindow)

                    // Resilience config
                    // ⚠️ register B44 — THE live defect, and it sat 85 lines above A7's own
                    // `.code` fix in this same function. `.code` fell into the `else`, so a Code
                    // session got `ErrorRecovery()` (`onToolFailure: .abort`) in place of the
                    // `.fallbackPrompt` `CodeSessionManager` configures, and `resilienceOverrides`
                    // was nil so its Loop Safety caps were discarded too — with nothing logged.
                    let retryPolicy = profile.details.retryPolicy
                    let errorRecovery = profile.details.errorRecovery
                    let resilienceOverrides = profile.details.resilienceOverrides

                    // Image payload (Phase 3): upstream image artifacts become native
                    // image blocks so vision-capable bot nodes "see" them. Reference-
                    // backed — the provider resolves+encodes at send time (a failed
                    // resolve throws there and fails the node, never a silent drop).
                    let workflowImagePayload: Payload? = {
                        let imageArtifacts = workflowContext.upstreamArtifacts.filter { $0.kind == .image }
                        guard !imageArtifacts.isEmpty else { return nil }
                        return imageArtifacts.map { .image(ImagePayload(reference: $0.reference, mimeType: $0.mimeType, alt: $0.label)) }
                    }()

                    // Per-NODE MCP guidance. `rawTools` is this node's profile's configured tool
                    // list, so the gate follows the node rather than the workflow profile (which
                    // holds no tools of its own). A node with no MCP tools gets no `<tool_guidance>`
                    // section at all — which is the whole point: the failing report had an agent
                    // with three built-in tools receiving ~2,000 chars about 41 MCP tools.
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
                    let input = AgentInput(
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
                        recentHistory: nil,
                        generatorStrategy: generator,
                        workingMemory: {
                            var memory = WindowedLinearMemory(config: MemoryBudgetConfig.derive(
                                contextWindow: contextWindow, tier: modelTier,
                                // Same rule as the main path: the room the node's fixed prompt leaves.
                                reservedChars: (instructions?.count ?? 0)
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

                    // ⚠️ Tool NAMES, not just a count. This said only "tools=3" — which cannot
                    // answer "which three?" from a field log, and that question came up twice
                    // while diagnosing a node. The sampling config is deliberately NOT repeated
                    // here: the ReAct banner below already prints the provider's full
                    // `generationConfig`, and a second copy would be noise, not coverage.
                    let toolNames = activeTools.map(\.name).sorted().joined(separator: ", ")
                    logger.info("[Workflow] AgentInput node='\(workflowContext.nodeName)': tools=\(activeTools.count) [\(toolNames)], generator=\(type(of: generator)), model=\(llmConfig.modelName)")

                    // 8. Execute
                    let executor = ExecutorFactory.create(for: profile)
                    logger.info("[Workflow] Executor: \(executor.executorLabel) for '\(workflowContext.nodeName)'")

                    // EvaluationLogger bridge — the same three lines the chat path has had all
                    // along (streamAgentResponse). Without it, a workflow node's thought /
                    // toolCall / stateChange records never became span events, so the SAME
                    // profile recorded its reasoning in chat and NOTHING inside a workflow.
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
                // ⚠️ This used to THROW a 405 and refuse the run outright (register G94). It was the
                // second of two enforcements of the same heuristic, and it made a promise the app
                // had already made to the user unkeepable: MLXModelPickerView tells them the check
                // "is a name-based heuristic and is often wrong for new or re-quantized models — if
                // you know it supports tools, keep it selected", and that same file states
                // "Tool-capability is LABELLED, not enforced". Keeping the model selected then
                // produced a profile that could not be saved (G92) and could not be run (here).
                //
                // A capability classification may LABEL, never GATE. The verdict can be wrong in the
                // permissive direction too — MLX Tier 0 forces `.none` on the model NAME alone
                // (deepseek-r1, qwq, gpt-oss, magistral) ahead of any tokenizer evidence, so a model
                // with tool tokens and a tool-aware chat template is refused on its name.
                //
                // So: proceed, and let the attempt report the truth. A model that genuinely cannot
                // call tools fails visibly — the local dialects degrade to text, and a server that
                // rejects a tools param answers 400, which
                // `ProviderErrorClassifier.classify(statusCode:rawBody:)` already turns into a named
                // error. That is the same policy the cloud arms above follow deliberately, and the
                // same one the Ollama picker documents ("the runtime gate reports the failure
                // honestly rather than trapping the picker"). User decision, 2026-08-06.
                //
                // ⚠️ The refusal CANNOT be made selective today even where it would be justified:
                // `CognitiveProfile.toolSupportCaveat` distinguishes an authoritative
                // `.serverRejectsTools` (the Ollama daemon declared no tools — a tools request WILL
                // 400) from a heuristic `.reasoningFocused`, but `ProviderConfig.cognitiveProfile`
                // never passes it, so it is always nil on a persisted profile. Persisting it is the
                // prerequisite for ever reinstating a gate here — do not reinstate one without it.
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
            
            // Extract options for Ollama.
            //
            // ⚠️⚠️ Delegated to `OllamaRequestOptions` rather than resolved here. The preset
            // fallback and the num_ctx auto-default used to live inline in this function, which
            // meant `EffectiveContextWindow` — the resolver behind the gauge, the compaction
            // budget, the native-turn budget and the pre-send fit check — could not see them. It
            // read `advancedConfiguration` (nil for any profile whose Advanced panel was never
            // opened) and answered 16384 while this block sent 8192. Everything downstream priced
            // a window twice the real one. Whatever this block decides, the budgets now decide
            // identically, because they call the same function.
            //
            // `isBotFlow` picks the ladder: `OllamaAdvancedConfig.default()` is the AGENT preset,
            // and handing it to a Bot pins a conversational profile to temperature 0.1 with a
            // fixed seed, so every repeated prompt returns a byte-identical reply.
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
                // OpenRouter attribution. Both headers are static project identifiers —
                // nothing about the user, the machine or the prompt is conveyed — and sending
                // the pair is what lists the app on OpenRouter's public app rankings.
                // `HTTP-Referer` was omitted while there was no public homepage; there is one now.
                extraHeaders: [
                    "X-Title": "Devgentic",
                    "HTTP-Referer": GlobalConstants.homepageURL,
                ]
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

            // Use the native Gemini API SHAPE exclusively to prevent 429 schema compatibility
            // errors — that decision is about the request format, not about the host.
            //
            // ⚠️ register B21 (twin of the imageGen finding). The host was hardcoded here too, so a
            // Google profile pointed at a corporate gateway listed its models through the gateway
            // (`GeminiService.verifyAndFetchModels` honours `baseURL`) and then sent every actual
            // completion — and its gateway-scoped key — to `generativelanguage.googleapis.com`.
            // One profile, two hosts, and the credential went to the one the user configured away
            // from. The path suffix is unchanged; only the root is now the configured one.
            let googleBaseURL = ProviderDefaults
                .resolvedBaseURL(configured: llmConfig.baseURL, fallback: ProviderDefaults.geminiBaseURL)
                .appendingPathComponent("models/\(llmConfig.modelName)")
            var options: [String: JSONValue]? = nil
            if let advConfig = llmConfig.advancedConfiguration {
                options = advConfig
            } else {
                // [advanced-config default] See the Ollama arm. The Gemini panel shows Max Output
                // Tokens 2048 and a full set of safety thresholds on an unconfigured profile; none
                // of it was sent, so the model used the account defaults while the UI claimed
                // otherwise — and for the safety controls specifically, "claimed otherwise" means a
                // user believed they had loosened or tightened filtering when they had not.
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
            // `ensureLoaded()` rather than a fire-and-forget refresh: the scan is now
            // off-actor, so reading the list straight after asking for a refresh can observe
            // an empty one — indistinguishable from "the model isn't installed", which would
            // fail the turn with a 404 for a model that is present.
            await MLXModelService.shared.ensureLoaded()
            let modelPath: URL? = await MainActor.run {
                MLXModelService.shared.installedModel(named: modelName)?.localPath
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
    
    /// `internal` rather than `private` ONLY so the no-cross-source-fallback invariant below can
    /// be tested directly. It has no other callers outside this type; the tool-shadowing rule it
    /// enforces is a security boundary, and a source scan is too weak a guard for one.
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

        var unresolved: [String] = []
        for toolConfig in profileTools where toolConfig.isEnabled {
            // Resolve by SOURCE, not by name — and ONLY within that source.
            //
            // This used to try `resolveNativeTool(toolName:)` unconditionally and only fall
            // through to MCP when the name missed. Because MCP servers choose their own
            // tool names, any server exposing a name that collides with a built-in — a
            // filesystem server offering `read_file`, say — had its calls silently
            // dispatched to Devgentic's LOCAL implementation instead, ignoring
            // `toolConfig.sourceId` entirely. The user enabled one tool and a different
            // one ran, with matching arguments making the swap invisible.
            //
            // `sourceId` is the whole answer, in both directions: it says which
            // implementation the user chose, and a same-named tool from anywhere else is a
            // different program with different limits. See the resolver below for why the
            // remaining `??` fallbacks were removed too.
            let isBuiltIn = toolConfig.sourceId == ToolSource.builtInSourceID

            // Skip tools from a disabled server BEFORE any resolution attempt.
            //
            // This once carried the load of a correctness guard: while the resolver below fell
            // back across sources, returning nil from `resolveMCPTool` was not enough, because
            // the caller then ran the same-named built-in — the shadowing bug in reverse,
            // reachable by simply switching a server off. That fallback is gone, so
            // `resolveMCPTool`'s own `source.isEnabled` guard would now produce the same
            // OUTCOME. This stays for the DIAGNOSTIC: a server the user deliberately switched
            // off is not a dropped capability, and it must not be reported as one. Falling
            // through would add the tool to `unresolved` and emit the ⚠️ NOT RESOLVED error,
            // burying real drops in noise every turn.
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

            // Resolve STRICTLY within the declared source — no cross-source fallback.
            //
            // ⚠️ Both arms used to end in `?? <the other resolver>`, which left the shadowing bug
            // half-open in each direction. Branching on `isBuiltIn` fixed the common case (a name
            // that exists on BOTH sides resolves to the declared one), but the fallbacks still
            // fired whenever the declared side MISSED:
            //   • non-built-in ?? native — a server that is enabled yet no longer exposes the name
            //     (tool renamed or removed upstream), or a server row that is GONE entirely, had
            //     its calls quietly executed by Devgentic's same-named local implementation. The
            //     `!source.isEnabled` skip above does not cover this: it only fires when the source
            //     row still exists, so a REMOVED server was the sharpest form of the substitution.
            //   • built-in ?? MCP — a built-in deleted or renamed between releases resolved to
            //     whatever MCP server happened to expose the old name.
            // In both cases the user enabled one tool and a different implementation ran, with
            // matching arguments making the swap invisible. "The source you chose is unavailable,
            // so run something else with the same name" is never the safe default for a tool call.
            // Dropping the capability is, and the drop is reported loudly below.
            // ⚠️ BUILT-INS RESOLVE THROUGH THE RENAME MAP, which is NOT the cross-source fallback
            // removed above. That one guessed at an implementation by NAME and let an MCP server
            // shadow a built-in. This is a DECLARED mapping between two versions of our own
            // catalogue — `batch_command` → `run_command` + `start_background_task` — where the
            // replacement is known because we performed the split. Without it, withdrawing a name
            // silently removes the capability from every profile that had it.
            let resolved: AgentTool? = isBuiltIn
                ? self.resolveNativeTool(toolName: toolConfig.name, conversationID: conversationID, requiresConfirmation: toolConfig.requiresConfirmation, timeout: toolConfig.timeout, timeoutMessage: toolConfig.timeoutMessage)
                : self.resolveMCPTool(toolConfig: toolConfig, availableSources: allToolSources, conversationID: conversationID)

            if let agentTool = resolved {
                activeTools.append(agentTool)
                logger.debug("[TOOLRESOLVE] \(isBuiltIn ? "native" : "MCP") '\(toolConfig.name)' enabled from source \(toolConfig.sourceId) (confirm: \(toolConfig.requiresConfirmation)) [conv \(conversationID)]")
            } else {
                // A SILENT CAPABILITY DROP — the loudest thing in this function.
                //
                // The profile asked for this tool and the agent will run without it. Nothing
                // surfaces in the UI, and the stale entry stays in the profile forever (the Tool
                // Library renders from `UnifiedToolStore`, so a name with no matching source has
                // no row to un-tick). Before 2026-07-31 this was one `warning` with the bare name:
                // no profile, no conversation, no statement of the consequence — unusable for
                // working out why an agent "forgot" how to do something.
                unresolved.append(toolConfig.name)

                // Name the OTHER side explicitly when it would have matched. That case is exactly
                // what the removed fallback used to swallow, and it is the one the user can act
                // on: a same-named implementation exists, it is simply not the one this profile
                // declared. Saying so is the difference between "re-add it from the Tool Library"
                // and a fruitless hunt for a tool that looks present everywhere.
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

        // Enforce name uniqueness before anything reaches a provider.
        //
        // Tool names are the model's only handle on a tool, and MCP servers pick their own.
        // Two enabled tools sharing a name — two servers exposing `search`, or a server
        // shadowing a built-in — were emitted as duplicate entries in the request payload.
        // Anthropic rejects that outright (400, "duplicate tool name"), so ONE colliding
        // MCP server broke every request in the conversation rather than just its own tool.
        // Keep the first occurrence (built-ins resolve first) and drop the rest loudly.
        var seenToolNames = Set<String>()
        var duplicates: [String] = []
        activeTools = activeTools.filter { tool in
            if seenToolNames.insert(tool.name).inserted { return true }
            duplicates.append(tool.name)
            return false
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

        // -----------------------------------------------------------------
        // 4. Agent Delegation Tool (when capability is ON)
        // -----------------------------------------------------------------
        // ⚠️ register B15 — agent delegation is WITHDRAWN, and the runtime now enforces that
        // rather than obeying whatever the stored blob says. The toggle was removed from the UI
        // long ago (A66), but the gate here is the mere PRESENCE of `capabilities.agentDelegation`
        // — there is no `isEnabled` flag — so every legacy "Supervisor" profile that
        // `ProfileMigrator.migrateToV2` created went on injecting `call_agent` on every run, with
        // nothing on screen to say so.
        //
        // Enforced at CONSUMPTION with one named constant, exactly like
        // `PlanningCapability.parallelSubtasksSupported` (register A67): one line to flip when
        // sub-agents are worth reviving. The stored config is logged and IGNORED, never rewritten
        // — a migration would destroy a preference the user expressed for a feature the team
        // intends to restore, and that is a one-way door.
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
    
    /// Wraps a concrete DevgenticTool into an AgentTool with type-erased execution closure.
    /// Thin alias for `AgentToolFactory.wrap`, kept because the injected control-plane tools
    /// (`ask_user`, `final_answer`, `get_conversation_history`, `load_skill`,
    /// `update_project_context`) are built here with run-scoped data and read better unqualified.
    private func wrapTool<T: DevgenticTool>(_ tool: T, requiresConfirmation: Bool, timeout: TimeInterval? = nil, timeoutMessage: String? = nil) -> AgentTool {
        AgentToolFactory.wrap(tool, requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
    }

    /// Wraps an already-erased `AgentTool` (the MCP path) with this profile's settings.
    private func wrapTool(_ tool: AgentTool, requiresConfirmation: Bool, timeout: TimeInterval? = nil, timeoutMessage: String? = nil) -> AgentTool {
        AgentToolFactory.rewrap(tool, requiresConfirmation: requiresConfirmation, timeout: timeout, timeoutMessage: timeoutMessage)
    }

    // MARK: - Native Tool Resolution
    
    /// Resolves a native tool by name.
    ///
    /// A lookup, not a switch. This was a ~100-line `switch` that was the second of two
    /// hand-maintained tool lists — see `NativeToolCatalog` for what that cost. The catalogue is
    /// now the only place a native tool is declared; this decides nothing except which
    /// per-profile settings to hand it.
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

        // A disabled server contributes nothing. Its rows stay in the Tool Library so the
        // user can switch it back on, so this is the seam that makes the toggle mean
        // something — without it, disabling a server would stop it CONNECTING while its
        // tools still registered and then failed at call time.
        guard source.isEnabled else {
            logger.info("""
                [TOOLRESOLVE] '\(toolConfig.name)' skipped — its server '\(source.serverName)' \
                (\(source.id)) is disabled by the user. The agent runs without this tool by \
                design; re-enable the server in the Tool Library to restore it. [conv \(conversationID)]
                """)
            return nil
        }

        // Tie this source to the conversation now, while we still know both. A server's
        // sampling / elicitation request arrives later, out-of-band, carrying neither — this
        // is what lets it be raised in the conversation that actually caused it.
        // Hop to the main actor — this resolver is nonisolated and both brokers own
        // main-actor state. Fire-and-forget is correct here: the association only has to be
        // in place before the server issues a request, which cannot happen until after the
        // tool is registered and a turn starts.
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
        Tools Enabled (pre-flight — see the [TOOLS] line for the final loadout): [\(toolNames)]
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

//
//  AgentConnect.swift
//  Devgentic
//
//  Created by Raj Singh on 23/01/26.
//  Updated: Enforced strict Agent vs Bot capability routing.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentConnect")
private let logToolExecution = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ToolExecution")

/// A unified agent connection service that serves as the central controller for
/// all LLM interactions (Bots, Agents, Workflows).
/// It acts as the Hub, initializing models, resolving tools, and routing to the correct Executor.
class AgentConnect: ObservableObject {
    
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
        traceContext: TraceContext,
        onTraceUpdate: ((AgentTraceLog) -> Void)? = nil
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
                    
                    switch profile.details {
                    case .bot(let config):
                        llmConfig = config.llmConfig
                        instructions = config.instructions
                        rawTools = []
                        isBotFlow = true

                    case .agent(let config):
                        llmConfig = config.llmConfig
                        instructions = config.instructions
                        rawTools = config.tools
                        isBotFlow = false

                    case .workflow(let config):
                        // Workflow: each node resolves its own model, tools, and generator.
                        // Bypass the single-model pipeline entirely.
                        let workflowExecutor = WorkflowExecutor(workflowProfileID: profile.id)
                        let wfStream = workflowExecutor.executeWorkflow(
                            agentProfileIDs: config.agentProfileIDs,
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
                    }

                    // 2. Select Cognitive Strategy & Rate Limit Boundary
                    let rateLimitCategory: RateLimitCategory
                    switch llmConfig.apiProvider {
                    case .anthropic: rateLimitCategory = .anthropic
                    case .google: rateLimitCategory = .geminiFlash
                    case .openAI: rateLimitCategory = .openAI
                    case .ollama, .mlx: rateLimitCategory = .local
                    }
                    
                    // Resolve Cognitive Strategy via our 2D routing matrix
                    let generatorStrategy = try self.resolveCognitiveGenerator(
                        llmConfig: llmConfig,
                        isBotFlow: isBotFlow
                    )
                    
                    // --- UI Progress: Preparing tools ---
                    continuation.yield(.thought("Preparing agent tools…"))

                    // 3. Resolve Tools
                    let modelTier = llmConfig.modelMetadata?.tier ?? .medium
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

                    let activeTools = await self.resolveExecutableTools(
                        profileTools: rawTools,
                        conversationID: conversationID,
                        longTermMemory: longTermMemory
                    )
                    
                    // 4. Initialize Evaluation Session (Metrics)
                    let evalSessionID = UUID()
                    if !activeTools.isEmpty {
                        EvaluationLogger.shared.startSession(id: evalSessionID, availableTools: activeTools)
                    }
                    
                    defer {
                        if !activeTools.isEmpty {
                            _ = EvaluationLogger.shared.endSession(id: evalSessionID)
                        }
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

                    // 5. Initialize the Language Model (Passing isBotFlow to determine endpoint routing)
                    let model = try await self.initializeModel(config: llmConfig, isBotFlow: isBotFlow)
                    
                    // --- UI Progress: Model ready ---
                    if llmConfig.apiProvider == .mlx || llmConfig.apiProvider == .ollama {
                        continuation.yield(.thought("Model loaded. Starting execution…"))
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
                    
                    logger.info("Starting execution using executor strategy: \(executor.architecture.rawValue)")
                    
                    // 7. Prepare Input (State Injection)
                    var activeState: SessionGraph? = nil
                    var recentHistory: String? = nil
                    
                    // NEW: Determine Model Tier and Provision Memory Strategy
                    let workingMemory: any WorkingMemoryStrategy = (modelTier == .tiny || modelTier == .small)
                        ? SummarizedLinearMemory()
                        : HighContextLinearMemory()
                    
                    if !activeTools.isEmpty {
                        // Build the ephemeral SessionGraph from the UI history
                        activeState = EpisodicHistoryFormatter.buildGraph(
                            from: chatHistory,
                            sessionID: conversationID.uuidString
                        )
                        
                        // Generate the "Recent History" text block directly from the chat history
                        recentHistory = EpisodicHistoryFormatter.buildRecentHistoryString(from: chatHistory)
                    }
                    
                    let input = AgentInput(
                        userInput: userInput,
                        chatHistory: chatHistory,
                        conversationID: conversationID,
                        tools: activeTools,
                        longTermMemory: longTermMemory,
                        activeState: activeState,
                        recentHistory: recentHistory,
                        generatorStrategy: generatorStrategy,
                        workingMemory: workingMemory,
                        rateLimitCategory: rateLimitCategory,
                        instructions: instructions,
                        traceContext: traceContext
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
                    
                    let stream = executor.execute(model: model, input: input, onTraceUpdate: traceHandler)
                    
                    var finalOutputAccumulator = ""
                    for try await event in stream {
                        if case .content(let chunk) = event {
                            finalOutputAccumulator += chunk
                        }
                        continuation.yield(event)
                    }
                    
                    logger.info("--- 🏁 TEXTGEN RESPONSE COMPLETE 🏁 ---")
                    logger.info("Model: \(llmConfig.modelName)")
                    logger.info("Final Output: \(finalOutputAccumulator)")
                    logger.info("---------------------------------------")
                    
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
    
    // MARK: - Cognitive Strategy Resolution
    
    /// Evaluates the model configuration and isolates the routing logic for the generator.
    private func resolveCognitiveGenerator(
        llmConfig: ProviderConfig,
        isBotFlow: Bool
    ) throws -> any CognitiveGenerator {
        
        switch llmConfig.apiProvider {
        case .anthropic:
            return NativeStructuredGenerator(toolAdapter: ClaudeToolSchemaAdapter())
            
        case .google:
            return NativeStructuredGenerator(toolAdapter: GeminiToolSchemaAdapter())
            
        case .openAI:
            return NativeStructuredGenerator(toolAdapter: NativeJSONSchemaAdapter())
            
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
                // Secondary Dimension: Dialect matching for single-action text constraints
                switch cognitiveProfile.dialect {
                case .mistralXML:
                    return XMLStructuredGenerator()
                case .reactMarkdown:
                    return MarkdownStructuredGenerator()
                default:
                    return JsonStructuredGenerator()
                }
                
            case .parallelActions:
                // Models capable of parallel tool calling are well-trained to output structured JSON natively.
                // Dialect routing is unnecessary here — it's only needed for singleAction models
                // which may be legacy or older architectures requiring format-specific prompting.
                let strategyName = (llmConfig.apiProvider == .mlx) ? "MLXNativeStructuredGenerator" : "NativeStructuredGenerator"
                logger.info("🧩 Resolved Generator Strategy: \(strategyName) for model: \(llmConfig.modelName)")

                if llmConfig.apiProvider == .mlx {
                    return MLXNativeStructuredGenerator()
                } else {
                    return NativeStructuredGenerator()
                }
            }
        }
    }
    
    // MARK: - Model Initialization
    
    private func initializeModel(config llmConfig: ProviderConfig, isBotFlow: Bool) async throws -> any LLMProvider {
        switch llmConfig.apiProvider {
        case .anthropic:
            guard let apiKey = llmConfig.apiKey, !apiKey.isEmpty else {
                throw NSError(domain: "AgentConnect", code: 401, userInfo: [NSLocalizedDescriptionKey: "Anthropic API Key is required."])
            }
            let baseURL = (llmConfig.baseURL != nil) ? URL(string: llmConfig.baseURL!)! : ProviderDefaults.anthropicBaseURL
            var options: [String: JSONValue]? = nil
            if let advConfig = llmConfig.advancedConfiguration {
                options = advConfig
            }
            let config = LLMProviderConfig(apiKey: apiKey, baseURL: baseURL, modelName: llmConfig.modelName, timeout: 300.0, options: options)
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
            
            let config = LLMProviderConfig(baseURL: baseURL, modelName: llmConfig.modelName, timeout: 300.0, options: options)
            return OllamaLLMProvider(config: config)
            
        case .openAI:
            guard let apiKey = llmConfig.apiKey, !apiKey.isEmpty else {
                throw NSError(domain: "AgentConnect", code: 401, userInfo: [NSLocalizedDescriptionKey: "OpenAI API Key is required."])
            }
            let baseURL = (llmConfig.baseURL != nil) ? URL(string: llmConfig.baseURL!)! : ProviderDefaults.openAIBaseURL
            var options: [String: JSONValue]? = nil
            if let advConfig = llmConfig.advancedConfiguration {
                options = advConfig
            }
            let config = LLMProviderConfig(apiKey: apiKey, baseURL: baseURL, modelName: llmConfig.modelName, timeout: 300.0, options: options)
            return OpenAILLMProvider(config: config)
            
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
            let config = LLMProviderConfig(apiKey: apiKey, baseURL: googleBaseURL, modelName: llmConfig.modelName, timeout: 300.0, options: options)
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
        longTermMemory: any LongTermMemoryStrategy
    ) async -> [AgentTool] {
        
        var activeTools: [AgentTool] = []
        
        // -----------------------------------------------------------------
        // 1. Core System Tools (Inherently Safe & Required for ALL models)
        // -----------------------------------------------------------------
        activeTools.append(wrapTool(VectorSearchTool(conversationID: conversationID), requiresConfirmation: false))
        activeTools.append(wrapTool(AskUserTool(), requiresConfirmation: false))
        
        // -----------------------------------------------------------------
        // 2. Deep Episodic Memory (Delegated to Strategy)
        // -----------------------------------------------------------------
        // If it's an edge model, this array is empty.
        // If it's a frontier model, this contains ReadActionLogTool, etc.
        activeTools.append(contentsOf: longTermMemory.memoryCapabilities)
        
        // -----------------------------------------------------------------
        // 3. User-Configured / External Tools (Standard resolution)
        // -----------------------------------------------------------------
        let allToolSources = await UnifiedToolStore.shared.sources
        
        for toolConfig in profileTools where toolConfig.isEnabled {
            if let agentTool = self.resolveNativeTool(toolName: toolConfig.name, conversationID: conversationID, requiresConfirmation: toolConfig.requiresConfirmation) {
                activeTools.append(agentTool)
                logger.debug("Enabled Native Tool: \(toolConfig.name)")
            } else if let agentTool = self.resolveMCPTool(toolConfig: toolConfig, availableSources: allToolSources) {
                activeTools.append(agentTool)
                logger.debug("Enabled MCP Tool: \(toolConfig.name)")
            } else {
                logger.warning("Failed to resolve tool: \(toolConfig.name)")
            }
        }
        
        return activeTools
    }
    
    // MARK: - Tool Wrapping
    
    /// Wraps a concrete DevgenticTool into an AgentTool with type-erased execution closure.
    private func wrapTool<T: DevgenticTool>(_ tool: T, requiresConfirmation: Bool) -> AgentTool {
        let toolName = tool.name
        let requiredKeys = tool.parameterSchema.required

        return AgentTool(
            name: tool.name,
            description: tool.description,
            parameters: tool.parameterSchema,
            requiresConfirmation: requiresConfirmation
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
    private func wrapTool(_ tool: AgentTool, requiresConfirmation: Bool) -> AgentTool {
        return AgentTool(
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters,
            requiresConfirmation: requiresConfirmation,
            run: tool.run
        )
    }
    
    // MARK: - Native Tool Resolution
    
    private func resolveNativeTool(toolName: String, conversationID: UUID, requiresConfirmation: Bool) -> AgentTool? {
        switch toolName {
        case "list_directory": return wrapTool(ListDirectoryTool(), requiresConfirmation: requiresConfirmation)
        case "read_file": return wrapTool(ReadFileTool(), requiresConfirmation: requiresConfirmation)
        case "write_file": return wrapTool(WriteFileTool(), requiresConfirmation: requiresConfirmation)
        case "delete_file": return wrapTool(DeleteFileTool(), requiresConfirmation: requiresConfirmation)
        case "move_file": return wrapTool(MoveFileTool(), requiresConfirmation: requiresConfirmation)
        case "copy_file": return wrapTool(CopyFileTool(), requiresConfirmation: requiresConfirmation)
        case "create_folder": return wrapTool(CreateFolderTool(), requiresConfirmation: requiresConfirmation)
        case "execute_shell": return wrapTool(TerminalTool(conversationID: conversationID), requiresConfirmation: requiresConfirmation)
        case "open_application": return wrapTool(OpenApplicationTool(), requiresConfirmation: requiresConfirmation)
        case "run_applescript": return wrapTool(RunAppleScriptTool(), requiresConfirmation: requiresConfirmation)
        case "get_system_stats": return wrapTool(GetSystemStatsTool(), requiresConfirmation: requiresConfirmation)
        case "fs_watch_folder": return wrapTool(WatchFolderTool(), requiresConfirmation: requiresConfirmation)
        case "fs_smart_search": return wrapTool(SmartSearchTool(), requiresConfirmation: requiresConfirmation)
        case "fs_read_metadata": return wrapTool(ReadMetadataTool(), requiresConfirmation: requiresConfirmation)
        case "fs_organize_batch": return wrapTool(OrganizeBatchTool(), requiresConfirmation: requiresConfirmation)
        case "read_session_history": return wrapTool(ReadSessionHistoryTool(conversationID: conversationID), requiresConfirmation: requiresConfirmation)
            
        // MACOS SYSTEM COMMANDING TOOLS
        case "read_screen_state": return wrapTool(ReadScreenStateTool(), requiresConfirmation: requiresConfirmation)
        case "click_ui_element": return wrapTool(ClickUIElementTool(), requiresConfirmation: requiresConfirmation)
        case "manage_windows": return wrapTool(ManageWindowsTool(), requiresConfirmation: requiresConfirmation)
        case "manage_calendar": return wrapTool(ManageCalendarTool(), requiresConfirmation: requiresConfirmation)
        case "manage_reminders": return wrapTool(ManageRemindersTool(), requiresConfirmation: requiresConfirmation)
        case "read_contacts": return wrapTool(ManageContactsTool(), requiresConfirmation: requiresConfirmation)
        case "manage_contacts": return wrapTool(ManageContactsTool(), requiresConfirmation: requiresConfirmation)
        case "run_mac_shortcut": return wrapTool(RunMacShortcutTool(), requiresConfirmation: requiresConfirmation)
        case "manage_clipboard": return wrapTool(ManageClipboardTool(), requiresConfirmation: requiresConfirmation)
        case "push_local_notification": return wrapTool(PushLocalNotificationTool(), requiresConfirmation: requiresConfirmation)
        case "get_focus_context": return wrapTool(GetFocusContextTool(), requiresConfirmation: requiresConfirmation)
        case "get_power_state": return wrapTool(GetPowerStateTool(), requiresConfirmation: requiresConfirmation)
        case "manage_processes": return wrapTool(ManageProcessesTool(), requiresConfirmation: requiresConfirmation)
        case "manage_safari_tabs": return wrapTool(ManageSafariTabsTool(), requiresConfirmation: requiresConfirmation)
        case "read_safari_bookmarks": return wrapTool(ReadSafariBookmarksTool(), requiresConfirmation: requiresConfirmation)
        case "extract_safari_reader_view": return wrapTool(ExtractSafariReaderViewTool(), requiresConfirmation: requiresConfirmation)

        // VISION INPUT TOOLS
        case "type_text": return wrapTool(TypeTextTool(), requiresConfirmation: requiresConfirmation)
        case "press_key_combo": return wrapTool(PressKeyComboTool(), requiresConfirmation: requiresConfirmation)
        case "scroll_ui": return wrapTool(ScrollUITool(), requiresConfirmation: requiresConfirmation)
        case "read_ui_element_tree": return wrapTool(ReadUIElementTreeTool(), requiresConfirmation: requiresConfirmation)

        // NETWORK TOOLS
        case "check_network_status": return wrapTool(CheckNetworkStatusTool(), requiresConfirmation: requiresConfirmation)
        case "http_request": return wrapTool(HTTPRequestTool(), requiresConfirmation: requiresConfirmation)
        case "dns_lookup": return wrapTool(DNSLookupTool(), requiresConfirmation: requiresConfirmation)

        // AUDIO & MEDIA TOOLS
        case "manage_audio": return wrapTool(ManageAudioTool(), requiresConfirmation: requiresConfirmation)
        case "media_control": return wrapTool(MediaControlTool(), requiresConfirmation: requiresConfirmation)
        case "text_to_speech": return wrapTool(TextToSpeechTool(), requiresConfirmation: requiresConfirmation)

        // SYSTEM TOGGLE TOOLS
        case "toggle_dark_mode": return wrapTool(ToggleDarkModeTool(), requiresConfirmation: requiresConfirmation)
        case "toggle_do_not_disturb": return wrapTool(ToggleDoNotDisturbTool(), requiresConfirmation: requiresConfirmation)
        case "get_wifi_info": return wrapTool(GetWiFiInfoTool(), requiresConfirmation: requiresConfirmation)
        case "manage_bluetooth": return wrapTool(ManageBluetoothTool(), requiresConfirmation: requiresConfirmation)

        // FILE UTILITY TOOLS
        case "grep_files": return wrapTool(GrepFilesTool(), requiresConfirmation: requiresConfirmation)
        case "diff_files": return wrapTool(DiffFilesTool(), requiresConfirmation: requiresConfirmation)
        case "preview_file": return wrapTool(PreviewFileTool(), requiresConfirmation: requiresConfirmation)
        case "get_file_hash": return wrapTool(GetFileHashTool(), requiresConfirmation: requiresConfirmation)

        // GIT INTEGRATION
        case "git_tool": return wrapTool(GitTool(), requiresConfirmation: requiresConfirmation)

        // CODING ASSISTANT TOOLS
        case "edit_code": return wrapTool(EditCodeTool(), requiresConfirmation: requiresConfirmation)
        case "code_search": return wrapTool(CodeSearchTool(), requiresConfirmation: requiresConfirmation)
        case "glob_files": return wrapTool(GlobFilesTool(), requiresConfirmation: requiresConfirmation)
        case "find_definition": return wrapTool(FindDefinitionTool(), requiresConfirmation: requiresConfirmation)
        case "batch_command": return wrapTool(BatchCommandTool(), requiresConfirmation: requiresConfirmation)
        case "create_file": return wrapTool(CreateFileTool(), requiresConfirmation: requiresConfirmation)
        case "file_overview": return wrapTool(FileOverviewTool(), requiresConfirmation: requiresConfirmation)
        case "codebase_map": return wrapTool(CodebaseMapTool(), requiresConfirmation: requiresConfirmation)

        // MACOS UTILITY TOOLS
        case "screen_capture": return wrapTool(ScreenCaptureTool(), requiresConfirmation: requiresConfirmation)
        case "finder_tags": return wrapTool(FinderTagsTool(), requiresConfirmation: requiresConfirmation)
        case "disk_usage": return wrapTool(DiskUsageTool(), requiresConfirmation: requiresConfirmation)
        case "display_management": return wrapTool(DisplayManagementTool(), requiresConfirmation: requiresConfirmation)
        case "open_system_settings": return wrapTool(OpenSystemSettingsTool(), requiresConfirmation: requiresConfirmation)
        case "login_items": return wrapTool(LoginItemsTool(), requiresConfirmation: requiresConfirmation)
        case "external_devices": return wrapTool(ExternalDevicesTool(), requiresConfirmation: requiresConfirmation)
        case "apple_notes": return wrapTool(AppleNotesTool(), requiresConfirmation: requiresConfirmation)

        default: return nil
        }
    }
    
    // MARK: - MCP Tool Resolution
    
    private func resolveMCPTool(toolConfig: Tool, availableSources: [ToolSource]) -> AgentTool? {
        guard let source = availableSources.first(where: { $0.id == toolConfig.sourceId }),
              let definition = source.tools.first(where: { $0.name == toolConfig.name }) else {
            return nil
        }
        return wrapTool(DynamicMCPTool(source: source, toolDefinition: definition), requiresConfirmation: toolConfig.requiresConfirmation)
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
        Base URL: \(config.baseURL ?? "Default")
        Capabilities: \(config.cognitiveCapability.rawValue) (Dialect: \(config.modelDialect.rawValue))
        Metadata: \(metadata)
        Advanced Options: \(advConfig)
        Tools Enabled: [\(toolNames)]
        System Instructions: \(instructions?.prefix(100) ?? "None")\( (instructions?.count ?? 0) > 100 ? "..." : "") (\(instructions?.count ?? 0) chars)
        -----------------------------------------
        """
        logger.notice("\(logMsg)")
    }
}

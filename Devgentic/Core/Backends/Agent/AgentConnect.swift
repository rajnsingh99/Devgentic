//
//  AgentConnect.swift
//  Devgentic
//
//  Created by Raj Singh on 23/01/26.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentConnect")

/// A unified agent connection service that serves as the central controller for
/// all LLM interactions (Bots, Agents, Workflows).\
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
        
        logger.info("Routing request through AgentConnect Unified Pipeline for profile: \(profile.displayName)")
        
        return AsyncThrowingStream { continuation in
            // [CRITICAL FIX] Capture the task handle
            let task = Task {
                do {
                    // 1. Extract Configuration & Tools based on Profile Type
                    let llmConfig: ProviderConfig
                    var instructions: String?
                    let rawTools: [Tool]
                    
                    switch profile.details {
                    case .bot(let config):
                        llmConfig = config
                        instructions = nil
                        rawTools = []
                        
                    case .agent(let config, _, let tools, _, let instr, _):
                        llmConfig = config
                        instructions = instr
                        rawTools = tools
                        
                    case .workflow:
                        throw NSError(domain: "AgentConnect", code: 501, userInfo: [NSLocalizedDescriptionKey: "Workflows are not yet supported in the unified pipeline."])
                    }
                    
                    // [Step 4 Update: COGNITIVE STRATEGY & RATE LIMIT SELECTION]
                    let generatorStrategy: any CognitiveGenerator
                    let rateLimitCategory: RateLimitCategory
                    
                    switch llmConfig.apiProvider {
                    case .google:
                        // Gemini: Shadow Schema + Strict 15 RPM Limits
                        generatorStrategy = ShadowSchemaGenerator()
                        rateLimitCategory = .geminiFlash
                        
                    case .openAI:
                        // OpenAI: Native Schema + Higher Limits
                        generatorStrategy = NativeStructuredGenerator()
                        rateLimitCategory = .openAI
                        
                    case .ollama:
                        // Ollama: Native Schema + Hardware Limits
                        generatorStrategy = NativeStructuredGenerator()
                        rateLimitCategory = .local
                        
                    case .mlx:
                        // MLX: JSON Mode + Hardware Limits
                        generatorStrategy = JsonModeGenerator()
                        rateLimitCategory = .local
                        
                    default:
                        generatorStrategy = NativeStructuredGenerator()
                        rateLimitCategory = .geminiFlash // Fallback to safe strict mode
                    }
                    
                    // 2. Resolve Tools
                    let activeTools = await self.resolveExecutableTools(
                        profileTools: rawTools,
                        conversationID: conversationID
                    )
                    
                    // 3. Initialize Evaluation Session (Metrics)
                    let evalSessionID = UUID()
                    if !activeTools.isEmpty {
                        EvaluationLogger.shared.startSession(id: evalSessionID, availableTools: activeTools)
                    }
                    
                    defer {
                        if !activeTools.isEmpty {
                            _ = EvaluationLogger.shared.endSession(id: evalSessionID)
                        }
                    }
                    
                    // 4. Initialize the Language Model
                    let model = try await self.initializeModel(config: llmConfig)
                    
                    // 5. Instantiate the Executor (The Factory Pattern)
                    let executor = AgentExecutorFactory.create(for: profile)
                    
                    logger.info("Starting execution using executor strategy: \(executor.architecture.rawValue)")
                    
                    // 6. Prepare Input (State Injection)
                    var activeState: MutableActiveState? = nil
                    var recentHistory: String? = nil
                    
                    if !activeTools.isEmpty {
                        // Fetch components for the Split-State memory model
                        activeState = ContextMemoryManager.shared.getActiveState(for: conversationID)
                        recentHistory = ContextMemoryManager.shared.getRecentHistory(for: conversationID, lines: 20)
                    }
                    
                    let input = AgentInput(
                        userInput: userInput,
                        chatHistory: chatHistory,
                        conversationID: conversationID,
                        tools: activeTools,
                        ragContext: ragContext,
                        activeState: activeState,
                        recentHistory: recentHistory,
                        isNewRequest: true,
                        generatorStrategy: generatorStrategy,
                        rateLimitCategory: rateLimitCategory, // [INJECTION]
                        instructions: instructions,
                        traceContext: traceContext
                    )
                    
                    // 7. Execute & Stream
                    let traceHandler: (AgentTraceLog) -> Void = { log in
                        logger.debug("[\(log.state.rawValue)] \(log.content) (span: \(log.spanID))")
                        if !activeTools.isEmpty {
                            EvaluationLogger.shared.logStep(id: evalSessionID, log: log)
                        }
                        onTraceUpdate?(log)
                    }
                    
                    // Check cancellation before starting executor
                    try Task.checkCancellation()
                    
                    let stream = executor.execute(model: model, input: input, onTraceUpdate: traceHandler)
                    
                    for try await event in stream {
                        continuation.yield(event)
                    }
                    
                    continuation.finish()
                    
                } catch is CancellationError {
                    logger.info("AgentConnect Stream Cancelled.")
                    continuation.finish()
                } catch {
                    logger.error("Unified Stream Error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            
            // [CRITICAL FIX] Propagate cancellation to the inner task
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
    
    // MARK: - Model Initialization
    
    private func initializeModel(config llmConfig: ProviderConfig) async throws -> any LLMProvider {
        switch llmConfig.apiProvider {
        case .ollama:
            let baseURLString = llmConfig.baseURL ?? "http://127.0.0.1:11434"
            guard let baseURL = URL(string: baseURLString) else {
                throw NSError(domain: "AgentConnect", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Base URL: \(baseURLString)"])
            }
            let config = LLMProviderConfig(baseURL: baseURL, modelName: llmConfig.modelName, timeout: 300.0)
            return OllamaLLMProvider(config: config)
            
        case .openAI:
            guard let apiKey = llmConfig.apiKey, !apiKey.isEmpty else {
                throw NSError(domain: "AgentConnect", code: 401, userInfo: [NSLocalizedDescriptionKey: "OpenAI API Key is required."])
            }
            let baseURL = (llmConfig.baseURL != nil) ? URL(string: llmConfig.baseURL!)! : URL(string: "https://api.openai.com/v1/")!
            let config = LLMProviderConfig(apiKey: apiKey, baseURL: baseURL, modelName: llmConfig.modelName, timeout: 300.0)
            return OpenAILLMProvider(config: config)
            
        case .google:
            guard let apiKey = llmConfig.apiKey, !apiKey.isEmpty else {
                throw NSError(domain: "AgentConnect", code: 401, userInfo: [NSLocalizedDescriptionKey: "Gemini API Key is required."])
            }
            let googleBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!
            let config = LLMProviderConfig(apiKey: apiKey, baseURL: googleBaseURL, modelName: llmConfig.modelName, timeout: 300.0)
            return OpenAILLMProvider(config: config)
            
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
            return MLXLLMProvider(modelName: modelName)
            
        default:
            throw NSError(domain: "AgentConnect", code: 501, userInfo: [NSLocalizedDescriptionKey: "Provider \(llmConfig.apiProvider) is not supported in the unified pipeline yet."])
        }
    }
    
    // MARK: - Tool Resolution
    
    private func resolveExecutableTools(
        profileTools: [Tool],
        conversationID: UUID
    ) async -> [AgentTool] {
        
        var activeTools: [AgentTool] = []
        
        // System Tools (Always Available - Inherently Safe)
        activeTools.append(wrapTool(VectorSearchTool(conversationID: conversationID), requiresConfirmation: false))
        activeTools.append(wrapTool(ReadActionLogTool(), requiresConfirmation: false))
        activeTools.append(wrapTool(SearchActionLogsTool(), requiresConfirmation: false))
        activeTools.append(wrapTool(ReadSessionHistoryTool(conversationID: conversationID), requiresConfirmation: false))
        activeTools.append(wrapTool(AskUserTool(), requiresConfirmation: false))
        
        // User-Configured Tools
        let allToolSources = await UnifiedToolStore.shared.sources
        
        for toolConfig in profileTools where toolConfig.isEnabled {
            if let agentTool = self.resolveNativeTool(toolName: toolConfig.name, conversationID: conversationID, requiresConfirmation: toolConfig.requiresConfirmation) {
                activeTools.append(agentTool)
                logger.debug("Enabled Tool: \(toolConfig.name)")
            } else if let agentTool = self.resolveMCPTool(toolConfig: toolConfig, availableSources: allToolSources) {
                activeTools.append(agentTool)
                logger.debug("Enabled Tool: \(toolConfig.name)")
            } else {
                logger.warning("Failed to resolve tool: \(toolConfig.name)")
            }
        }
        
        return activeTools
    }
    
    // MARK: - Tool Wrapping (Generic)
    
    /// Wraps a concrete DevgenticTool into an AgentTool with type-erased execution closure.
    /// This replaces the old OFM-based `convertToAgentTool` and `invokeNativeTool` pipeline.
    private func wrapTool<T: DevgenticTool>(_ tool: T, requiresConfirmation: Bool) -> AgentTool {
        return AgentTool(
            name: tool.name,
            description: tool.description,
            parameters: tool.parameterSchema,
            requiresConfirmation: requiresConfirmation
        ) { dataArgs in
            let args = try JSONDecoder().decode(T.Arguments.self, from: dataArgs)
            return try await tool.call(arguments: args)
        }
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
}

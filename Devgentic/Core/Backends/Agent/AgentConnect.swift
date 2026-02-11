//
//  AgentConnect.swift
//  Devgentic
//
//  Created by Raj Singh on 23/01/26.
//

import Foundation
import os
import SwiftAgent
import OpenFoundationModels
import OpenFoundationModelsCore
import OpenFoundationModelsOllama
import OpenFoundationModelsOpenAI

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentConnect")

/// A unified agent connection service that serves as the central controller for
/// all LLM interactions (Bots, Agents, Workflows).
/// It uses the AgentExecutorFactory to determine the runtime behavior.
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
        approvedPlan: ExecutionPlan? = nil,
        traceContext: TraceContext,
        onTraceUpdate: ((AgentTraceLog) -> Void)? = nil
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> { // <--- UPDATED RETURN TYPE
        
        logger.info("Routing request through AgentConnect Unified Pipeline for profile: \(profile.displayName)")
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // 1. Extract Configuration & Tools based on Profile Type
                    let llmConfig: ProviderConfig
                    let instructions: String?
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
                    
                    // 6. Prepare Input
                    var memoryContext: String? = nil
                    if !activeTools.isEmpty {
                        memoryContext = ContextMemoryManager.shared.getContext(for: conversationID)
                    }
                    
                    let historyForExecution: [ChatMessage] = (approvedPlan != nil) ? [] : chatHistory
                    
                    let input = AgentInput(
                        userInput: userInput,
                        chatHistory: historyForExecution,
                        conversationID: conversationID,
                        tools: activeTools,
                        ragContext: ragContext,
                        persistentMemory: memoryContext,
                        instructions: instructions,
                        traceContext: traceContext,
                        approvedPlan: approvedPlan
                    )
                    
                    // 7. Execute & Stream
                    let traceHandler: (AgentTraceLog) -> Void = { log in
                        logger.debug("[\(log.state.rawValue)] \(log.content) (span: \(log.spanID))")
                        if !activeTools.isEmpty {
                            EvaluationLogger.shared.logStep(id: evalSessionID, log: log)
                        }
                        onTraceUpdate?(log)
                    }
                    
                    // Now returns AgentStreamEvent
                    let stream = executor.execute(model: model, input: input, onTraceUpdate: traceHandler)
                    
                    for try await event in stream {
                        continuation.yield(event)
                    }
                    
                    continuation.finish()
                    
                } catch {
                    logger.error("Unified Stream Error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Model Initialization
    
    private func initializeModel(config llmConfig: ProviderConfig) async throws -> any OpenFoundationModels.LanguageModel {
        switch llmConfig.apiProvider {
        case .ollama:
            let baseURLString = llmConfig.baseURL ?? "http://127.0.0.1:11434"
            guard let baseURL = URL(string: baseURLString) else {
                throw NSError(domain: "AgentConnect", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Base URL: \(baseURLString)"])
            }
            let config = OllamaConfiguration(baseURL: baseURL, timeout: 300.0)
            return OllamaLanguageModel(configuration: config, modelName: llmConfig.modelName)
            
        case .openAI:
            guard let apiKey = llmConfig.apiKey, !apiKey.isEmpty else {
                throw NSError(domain: "AgentConnect", code: 401, userInfo: [NSLocalizedDescriptionKey: "OpenAI API Key is required."])
            }
            let baseURL = (llmConfig.baseURL != nil) ? URL(string: llmConfig.baseURL!)! : URL(string: "https://api.openai.com/v1")!
            
            let config = OpenAIConfiguration(apiKey: apiKey, baseURL: baseURL, timeout: 120.0)
            return OpenAILanguageModel(configuration: config, model: llmConfig.modelName)
            
        case .google:
            guard let apiKey = llmConfig.apiKey, !apiKey.isEmpty else {
                throw NSError(domain: "AgentConnect", code: 401, userInfo: [NSLocalizedDescriptionKey: "Gemini API Key is required."])
            }
            let googleBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!
            let config = OpenAIConfiguration(apiKey: apiKey, baseURL: googleBaseURL, timeout: 120.0)
            return OpenAILanguageModel(configuration: config, model: llmConfig.modelName)
            
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
            return MLXLanguageModel(modelName: modelName)
            
        default:
            throw NSError(domain: "AgentConnect", code: 501, userInfo: [NSLocalizedDescriptionKey: "Provider \(llmConfig.apiProvider) is not supported in the unified pipeline yet."])
        }
    }
    
    // MARK: - Tool Resolution & Conversion
    
    private func resolveExecutableTools(
        profileTools: [Tool],
        conversationID: UUID
    ) async -> [AgentTool] {
        
        var activeTools: [AgentTool] = []
        
        if let vectorTool = self.convertToAgentTool(tool: VectorSearchTool(conversationID: conversationID)) {
            activeTools.append(vectorTool)
        }
        
        if let readLogTool = self.convertToAgentTool(tool: ReadActionLogTool()) {
            activeTools.append(readLogTool)
        }
        if let searchLogTool = self.convertToAgentTool(tool: SearchActionLogsTool()) {
            activeTools.append(searchLogTool)
        }
        
        let allToolSources = await UnifiedToolStore.shared.sources
        
        for toolConfig in profileTools where toolConfig.isEnabled {
            var toolInstance: (any OpenFoundationModels.Tool)? = nil
            
            if let native = self.mapNativeToolToExecutable(toolName: toolConfig.name, conversationID: conversationID) {
                toolInstance = native
            } else if let mcp = self.mapMCPToolToExecutable(toolConfig: toolConfig, availableSources: allToolSources) {
                toolInstance = mcp
            }
            
            if let instance = toolInstance, let agentTool = self.convertToAgentTool(tool: instance) {
                activeTools.append(agentTool)
                logger.debug("Enabled Tool: \(toolConfig.name)")
            } else {
                logger.warning("Failed to resolve or convert tool: \(toolConfig.name)")
            }
        }
        
        return activeTools
    }
    
    private func convertToAgentTool(tool: any OpenFoundationModels.Tool) -> AgentTool? {
        return AgentTool(
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters
        ) { [weak self] dataArgs in
            guard let self = self else { return "Error: AgentConnect deallocated" }
            return try await self.invokeNativeTool(tool, with: dataArgs)
        }
    }
    
    private func invokeNativeTool<T: OpenFoundationModels.Tool>(_ tool: T, with jsonData: Data) async throws -> String {
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw NSError(domain: "AgentConnect", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF8 data"])
        }
        
        do {
            let generatedContent = try OpenFoundationModelsCore.GeneratedContent(json: jsonString)
            let arguments = try T.Arguments(generatedContent)
            let output = try await tool.call(arguments: arguments)
            
            let prompt = output.promptRepresentation
            let mirror = Mirror(reflecting: prompt)
            if let content = mirror.children.first(where: { $0.label == "content" })?.value as? String {
                return content
            }
            return String(describing: prompt)
            
        } catch {
             let errorMessage = "Tool Argument Error ('\(tool.name)'): \(error.localizedDescription)\n\nSystem Hint: Failed to parse input JSON. Check that your parameter keys match the schema.\nRaw Input Received: \(jsonString)"
             throw NSError(domain: "AgentConnect", code: 422, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
    }
    
    private func mapNativeToolToExecutable(toolName: String, conversationID: UUID) -> (any OpenFoundationModels.Tool)? {
        switch toolName {
        case "list_directory": return ListDirectoryTool()
        case "read_file": return ReadFileTool()
        case "write_file": return WriteFileTool()
        case "delete_file": return DeleteFileTool()
        case "move_file": return MoveFileTool()
        case "copy_file": return CopyFileTool()
        case "create_folder": return CreateFolderTool()
        case "execute_shell": return TerminalTool(conversationID: conversationID)
        case "open_application": return OpenApplicationTool()
        case "run_applescript": return RunAppleScriptTool()
        case "get_system_stats": return GetSystemStatsTool()
        case "fs_watch_folder": return WatchFolderTool()
        case "fs_smart_search": return SmartSearchTool()
        case "fs_read_metadata": return ReadMetadataTool()
        case "fs_organize_batch": return OrganizeBatchTool()
        default: return nil
        }
    }
    
    private func mapMCPToolToExecutable(toolConfig: Tool, availableSources: [ToolSource]) -> (any OpenFoundationModels.Tool)? {
        guard let source = availableSources.first(where: { $0.id == toolConfig.sourceId }),
              let definition = source.tools.first(where: { $0.name == toolConfig.name }) else {
            return nil
        }
        return DynamicMCPTool(source: source, toolDefinition: definition)
    }
}

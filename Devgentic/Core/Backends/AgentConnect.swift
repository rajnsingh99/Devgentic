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

/// A unified agent connection service that prioritizes native SwiftAgent execution
/// for Ollama, OpenAI, and Gemini.
class AgentConnect: ObservableObject {
    
    // MARK: - Initialization
    
    init() {
        logger.info("AgentConnect initialized. Ready for Native (Ollama, OpenAI, Gemini).")
    }
    
    // MARK: - Stream Handling
    
    func streamAgentResponse(
        for profile: BackendProfileModel,
        userInput: String,
        chatHistory: [ChatMessage],
        conversationID: UUID,
        ragContext: String? = nil,
        onTraceUpdate: ((AgentTraceLog) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        
        if isNativeSupported(profile: profile) {
            logger.info("Routing to Native SwiftAgent for profile: \(profile.displayName)")
            return streamNative(
                for: profile,
                userInput: userInput,
                chatHistory: chatHistory,
                conversationID: conversationID,
                ragContext: ragContext,
                onTraceUpdate: onTraceUpdate
            )
        } else {
            logger.warning("Profile provider not supported natively: \(profile.displayName)")
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: NSError(
                    domain: "AgentConnect",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "The provider for profile '\(profile.displayName)' is not supported natively."]
                ))
            }
        }
    }
    
    // MARK: - Native Unified Implementation
    
    private func streamNative(
        for profile: BackendProfileModel,
        userInput: String,
        chatHistory: [ChatMessage],
        conversationID: UUID,
        ragContext: String?,
        onTraceUpdate: ((AgentTraceLog) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    guard case .agent(let llmConfig, let architecture, let profileTools, _, let instructions, _) = profile.details else {
                        throw NSError(domain: "AgentConnect", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid profile type for agent execution."])
                    }
                    
                    // 1. Resolve Tools into AgentTool wrappers
                    let activeTools = await self.resolveExecutableTools(
                        profileTools: profileTools,
                        conversationID: conversationID
                    )
                    
                    // Generate a unique ID for this specific execution run
                    let evalSessionID = UUID()
                    EvaluationLogger.shared.startSession(id: evalSessionID, availableTools: activeTools)
                    
                    // Ensure the session is ended and metrics reported when this scope exits (success or failure)
                    defer {
                        _ = EvaluationLogger.shared.endSession(id: evalSessionID)
                    }
                    // --------------------------------
                    
                    // 2. Initialize Model
                    let model: any OpenFoundationModels.LanguageModel
                    
                    switch llmConfig.apiProvider {
                    case .ollama:
                        let baseURLString = llmConfig.baseURL ?? "http://127.0.0.1:11434"
                        guard let baseURL = URL(string: baseURLString) else {
                            throw NSError(domain: "AgentConnect", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Base URL: \(baseURLString)"])
                        }
                        // INCREASED TIMEOUT: From 120.0 to 300.0 seconds to handle complex reasoning tasks on local hardware.
                        let config = OllamaConfiguration(baseURL: baseURL, timeout: 300.0)
                        model = OllamaLanguageModel(configuration: config, modelName: llmConfig.modelName)
                        
                    case .openAI:
                        guard let apiKey = llmConfig.apiKey, !apiKey.isEmpty else {
                            throw NSError(domain: "AgentConnect", code: 401, userInfo: [NSLocalizedDescriptionKey: "OpenAI API Key is required."])
                        }
                        let baseURL = (llmConfig.baseURL != nil) ? URL(string: llmConfig.baseURL!)! : URL(string: "https://api.openai.com/v1")!
                        
                        let config = OpenAIConfiguration(apiKey: apiKey, baseURL: baseURL, timeout: 120.0)
                        model = OpenAILanguageModel(configuration: config, model: llmConfig.modelName)
                        
                    case .google:
                        guard let apiKey = llmConfig.apiKey, !apiKey.isEmpty else {
                            throw NSError(domain: "AgentConnect", code: 401, userInfo: [NSLocalizedDescriptionKey: "Gemini API Key is required."])
                        }
                        let googleBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!
                        let config = OpenAIConfiguration(apiKey: apiKey, baseURL: googleBaseURL, timeout: 120.0)
                        model = OpenAILanguageModel(configuration: config, model: llmConfig.modelName)
                        
                    default:
                        throw NSError(domain: "AgentConnect", code: 501, userInfo: [NSLocalizedDescriptionKey: "Provider \(llmConfig.apiProvider) is not supported natively."])
                    }
                    
                    // 3. Initialize Executor
                    let executor = AgentExecutorFactory.create(for: architecture)
                    
                    logger.info("Starting execution using architecture: \(architecture.rawValue)")
                    
                    // 4. Prepare Input
                    let input = AgentInput(
                        userInput: userInput,
                        chatHistory: chatHistory,
                        conversationID: conversationID,
                        tools: activeTools,
                        ragContext: ragContext,
                        instructions: instructions
                    )
                    
                    // 5. Execute
                    let traceHandler: (AgentTraceLog) -> Void = { log in
                        logger.debug("[\(log.state.rawValue)] \(log.content)")
                        
                        // Log metrics for evaluation
                        EvaluationLogger.shared.logStep(id: evalSessionID, log: log)
                        
                        onTraceUpdate?(log)
                    }
                    
                    let stream = executor.execute(model: model, input: input, onTraceUpdate: traceHandler)
                    
                    for try await token in stream {
                        continuation.yield(token)
                    }
                    
                    continuation.finish()
                    
                } catch {
                    logger.error("Native Stream Error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Tool Resolution & Conversion
    
    private func resolveExecutableTools(
        profileTools: [Tool],
        conversationID: UUID
    ) async -> [AgentTool] {
        
        var activeTools: [AgentTool] = []
        
        // 1. Vector Search
        if let vectorTool = self.convertToAgentTool(tool: VectorSearchTool(conversationID: conversationID)) {
            activeTools.append(vectorTool)
        }
        
        // 2. Profile Tools
        let allToolSources = await UnifiedToolStore.shared.sources
        
        for toolConfig in profileTools where toolConfig.isEnabled {
            var toolInstance: (any OpenFoundationModels.Tool)? = nil
            
            if let native = self.mapNativeToolToExecutable(toolName: toolConfig.name) {
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
    
    /// Converts any OpenFoundationModels.Tool into our type-erased AgentTool wrapper
    private func convertToAgentTool(tool: any OpenFoundationModels.Tool) -> AgentTool? {
        return AgentTool(
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters
        ) { [weak self] dataArgs in
            // Use the helper method to handle the existential type 'any Tool'
            guard let self = self else { return "Error: AgentConnect deallocated" }
            return try await self.invokeNativeTool(tool, with: dataArgs)
        }
    }
    
    /// Helper method to open the existential 'any Tool' and invoke it with typed arguments.
    /// This fixes the "Value of type 'any Tool' has no member 'run'" error and resolves
    /// ambiguity with GeneratedContent init.
    private func invokeNativeTool<T: OpenFoundationModels.Tool>(_ tool: T, with jsonData: Data) async throws -> String {
        // 1. Convert Data to JSON String
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw NSError(domain: "AgentConnect", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF8 data for tool arguments"])
        }
        
        // 2. Create GeneratedContent from the JSON string
        // Fully qualified to avoid ambiguity between OpenFoundationModels and OpenFoundationModelsCore
        let generatedContent = try OpenFoundationModelsCore.GeneratedContent(json: jsonString)
        
        // 3. Initialize the tool's specific Arguments type
        let arguments = try T.Arguments(generatedContent)
        
        // 4. Call the tool
        let output = try await tool.call(arguments: arguments)
        
        // 5. Convert the tool's Output to a String
        // The 'content' property on Prompt is package-private. We use reflection to extract it.
        let prompt = output.promptRepresentation
        let mirror = Mirror(reflecting: prompt)
        
        if let content = mirror.children.first(where: { $0.label == "content" })?.value as? String {
            return content
        }
        
        // Fallback: Use String description
        return String(describing: prompt)
    }
    
    private func isNativeSupported(profile: BackendProfileModel) -> Bool {
        guard case .agent(let llmConfig, _, _, _, _, _) = profile.details else { return false }
        switch llmConfig.apiProvider {
        case .ollama, .openAI, .google: return true
        default: return false
        }
    }
    
    private func mapNativeToolToExecutable(toolName: String) -> (any OpenFoundationModels.Tool)? {
        switch toolName {
        case "list_directory": return ListDirectoryTool()
        case "read_file": return ReadFileTool()
        case "write_file": return WriteFileTool()
        case "delete_file": return DeleteFileTool()
        case "execute_shell": return TerminalTool()
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

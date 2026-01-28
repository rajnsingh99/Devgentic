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
    
    /// Initializes the new agent connector.
    init() {
        logger.info("AgentConnect initialized. Ready for Native (Ollama, OpenAI, Gemini).")
    }
    
    // MARK: - Stream Handling
    
    /// Streams the agent response using Native SwiftAgent.
    func streamAgentResponse(
        for profile: BackendProfileModel,
        userInput: String,
        chatHistory: [ChatMessage],
        conversationID: UUID,
        ragContext: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        
        // 1. Analyze Profile to determine routing
        if isNativeSupported(profile: profile) {
            logger.info("Routing to Native SwiftAgent for profile: \(profile.displayName)")
            return streamNative(
                for: profile,
                userInput: userInput,
                chatHistory: chatHistory,
                conversationID: conversationID,
                ragContext: ragContext
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
        ragContext: String?
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // 1. Extract Configuration & Tools
                    // FIXED: Added wildcard '_' at 2nd position for 'architecture'
                    guard case .agent(let llmConfig, _, let profileTools, _, let instructions, _) = profile.details else {
                        throw NSError(domain: "AgentConnect", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid profile type for agent execution."])
                    }
                    
                    // 2. Prepare Common Context (Tools, Transcript, History)
                    // This logic is shared across ALL native providers to ensure consistency.
                    let (transcript, activeTools) = await self.prepareSessionContext(
                        profileTools: profileTools,
                        instructions: instructions,
                        ragContext: ragContext,
                        chatHistory: chatHistory,
                        conversationID: conversationID,
                        userInput: userInput
                    )
                    
                    // 3. Initialize the Specific Language Model
                    let model: any OpenFoundationModels.LanguageModel
                    
                    switch llmConfig.apiProvider {
                    case .ollama:
                        let baseURLString = llmConfig.baseURL ?? "http://127.0.0.1:11434"
                        guard let baseURL = URL(string: baseURLString) else {
                            throw NSError(domain: "AgentConnect", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Base URL: \(baseURLString)"])
                        }
                        let config = OllamaConfiguration(baseURL: baseURL, timeout: 120.0)
                        model = OllamaLanguageModel(configuration: config, modelName: llmConfig.modelName)
                        
                    case .openAI:
                        guard let apiKey = llmConfig.apiKey, !apiKey.isEmpty else {
                            throw NSError(domain: "AgentConnect", code: 401, userInfo: [NSLocalizedDescriptionKey: "OpenAI API Key is required."])
                        }
                        // Use default OpenAI URL or custom one if provided (e.g., for enterprise endpoints)
                        let baseURL = (llmConfig.baseURL != nil) ? URL(string: llmConfig.baseURL!)! : URL(string: "https://api.openai.com/v1")!
                        
                        let config = OpenAIConfiguration(
                            apiKey: apiKey,
                            baseURL: baseURL,
                            timeout: 120.0
                        )
                        // Use the convenience init that takes a String for the model name
                        model = OpenAILanguageModel(configuration: config, model: llmConfig.modelName)
                        
                    case .google:
                        guard let apiKey = llmConfig.apiKey, !apiKey.isEmpty else {
                            throw NSError(domain: "AgentConnect", code: 401, userInfo: [NSLocalizedDescriptionKey: "Gemini API Key is required."])
                        }
                        
                        // CRITICAL: Point to Google's OpenAI-compatible endpoint
                        // Note: Google's endpoint is v1beta/openai/
                        let googleBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!
                        
                        let config = OpenAIConfiguration(
                            apiKey: apiKey,
                            baseURL: googleBaseURL,
                            timeout: 120.0
                        )
                        
                        // Google expects the actual Gemini model name (e.g., "gemini-1.5-flash")
                        model = OpenAILanguageModel(configuration: config, model: llmConfig.modelName)
                        
                    default:
                        // This should be caught by `isNativeSupported`, but as a safety:
                        throw NSError(domain: "AgentConnect", code: 501, userInfo: [NSLocalizedDescriptionKey: "Provider \(llmConfig.apiProvider) is not supported natively."])
                    }
                    
                    // 4. Initialize Session
                    // We explicitly pass the tools so the session can execute them.
                    let session = LanguageModelSession(model: model, tools: activeTools, transcript: transcript)
                    
                    logger.debug("Starting native stream for \(llmConfig.apiProvider.rawValue) with model: \(llmConfig.modelName)")
                    
                    // 5. Stream Response
                    let prompt = OpenFoundationModels.Prompt(userInput)
                    let stream = try await session.streamResponse(to: prompt)
                    
                    var lastSnapshot = ""
                    
                    for try await snapshot in stream {
                        let currentContent = snapshot.content
                        if currentContent.count > lastSnapshot.count {
                            let delta = String(currentContent.dropFirst(lastSnapshot.count))
                            continuation.yield(delta)
                            lastSnapshot = currentContent
                        }
                    }
                    
                    continuation.finish()
                    
                } catch {
                    logger.error("Native Stream Error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Shared Context Preparation
    
    /// Prepares the Transcript and Tools for *any* native provider.
    /// This ensures uniform RAG context injection and Tool handling across Ollama, OpenAI, and Gemini.
    private func prepareSessionContext(
        profileTools: [Tool],
        instructions: String?,
        ragContext: String?,
        chatHistory: [ChatMessage],
        conversationID: UUID,
        userInput: String
    ) async -> (OpenFoundationModels.Transcript, [any OpenFoundationModels.Tool]) {
        
        // 1. Resolve Active Tools
        var activeTools: [any OpenFoundationModels.Tool] = []
        
        // A. Always add Vector Search (System Default)
        activeTools.append(VectorSearchTool(conversationID: conversationID))
        
        // B. Map Profile Tools
        let allToolSources = await UnifiedToolStore.shared.sources
        
        for toolConfig in profileTools where toolConfig.isEnabled {
            if let nativeTool = self.mapNativeToolToExecutable(toolName: toolConfig.name) {
                activeTools.append(nativeTool)
                logger.debug("Enabled Native Tool: \(toolConfig.name)")
            }
            else if let mcpTool = self.mapMCPToolToExecutable(toolConfig: toolConfig, availableSources: allToolSources) {
                activeTools.append(mcpTool)
                logger.debug("Enabled MCP Tool: \(toolConfig.name)")
            }
            else {
                logger.warning("Tool '\(toolConfig.name)' enabled but implementation not found.")
            }
        }
        
        // 2. Construct System Message (Instructions + RAG + Tool Descriptions)
        let baseInstructions = (instructions != nil && !instructions!.isEmpty) ? instructions! : "You are a helpful AI assistant."
        var finalSystemMessage = baseInstructions
        
        if let context = ragContext, !context.isEmpty {
            finalSystemMessage += "\n\n### Relevant Context ###\nThe following information was retrieved from the user's knowledge base. Use it to answer the question if relevant:\n\(context)\n\n### End Context ###"
        }
        
        // Inject Tool Instructions manually.
        // While LanguageModelSession does this internally if you use the convenience init,
        // we are manually building the transcript to include history, so we must add this ourselves.
        finalSystemMessage += self.generateToolInstructions(for: activeTools)
        
        // 3. Build Transcript Entries
        var transcriptEntries: [OpenFoundationModels.Transcript.Entry] = []
        
        // A. Instructions Entry
        let instructionsEntry = OpenFoundationModels.Transcript.Entry.instructions(
            OpenFoundationModels.Transcript.Instructions(
                segments: [.text(OpenFoundationModels.Transcript.TextSegment(content: finalSystemMessage))],
                toolDefinitions: activeTools.map { OpenFoundationModels.Transcript.ToolDefinition(tool: $0) }
            )
        )
        transcriptEntries.append(instructionsEntry)
        
        // B. Chat History
        transcriptEntries.append(contentsOf: convertToTranscriptEntries(chatHistory))
        
        // Return the constructed Transcript and the executable tools array
        return (OpenFoundationModels.Transcript(entries: transcriptEntries), activeTools)
    }
    
    // MARK: - Helpers
    
    private func isNativeSupported(profile: BackendProfileModel) -> Bool {
        guard case .agent(let llmConfig, _, _, _, _, _) = profile.details else { return false }
        
        switch llmConfig.apiProvider {
        case .ollama, .openAI, .google:
            return true
        default:
            return false
        }
    }
    
    private func convertToTranscriptEntries(_ history: [ChatMessage]) -> [OpenFoundationModels.Transcript.Entry] {
        return history.compactMap { message -> OpenFoundationModels.Transcript.Entry? in
            guard let text = message.content.textContent else { return nil }
            switch message.sender {
            case .user:
                return .prompt(OpenFoundationModels.Transcript.Prompt(
                    segments: [.text(OpenFoundationModels.Transcript.TextSegment(content: text))]
                ))
            case .agent:
                return .response(OpenFoundationModels.Transcript.Response(
                    assetIDs: [],
                    segments: [.text(OpenFoundationModels.Transcript.TextSegment(content: text))]
                ))
            }
        }
    }
    
    private func mapNativeToolToExecutable(toolName: String) -> (any OpenFoundationModels.Tool)? {
        switch toolName {
        // NativeFileSystemTools
        case "list_directory": return ListDirectoryTool()
        case "read_file": return ReadFileTool()
        case "write_file": return WriteFileTool()
        case "delete_file": return DeleteFileTool()
            
        // NativeSystemTools
        case "execute_shell": return TerminalTool()
        case "open_application": return OpenApplicationTool()
        case "run_applescript": return RunAppleScriptTool()
        case "get_system_stats": return GetSystemStatsTool()
            
        // AdvancedFileSystemTools
        case "fs_watch_folder": return WatchFolderTool()
        case "fs_smart_search": return SmartSearchTool()
        case "fs_read_metadata": return ReadMetadataTool()
        case "fs_organize_batch": return OrganizeBatchTool()
            
        default:
            return nil
        }
    }
    
    private func mapMCPToolToExecutable(toolConfig: Tool, availableSources: [ToolSource]) -> (any OpenFoundationModels.Tool)? {
        guard let source = availableSources.first(where: { $0.id == toolConfig.sourceId }),
              let definition = source.tools.first(where: { $0.name == toolConfig.name }) else {
            return nil
        }
        return DynamicMCPTool(source: source, toolDefinition: definition)
    }
    
    private func generateToolInstructions(for tools: [any OpenFoundationModels.Tool]) -> String {
        guard !tools.isEmpty else { return "" }
        
        var instructions = "\n\n## Available Tools\n"
        
        for tool in tools {
            instructions += "\n### Tool: \(tool.name)\n"
            instructions += "Description: \(tool.description)\n"
            
            if tool.includesSchemaInInstructions {
                instructions += "Parameters:\n```json\n"
                instructions += formatJSONSchema(tool.parameters)
                instructions += "\n```\n"
            }
        }
        
        return instructions
    }
    
    private func formatJSONSchema(_ schema: OpenFoundationModelsCore.GenerationSchema) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        if let data = try? encoder.encode(schema),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        
        return String(describing: schema)
    }
}

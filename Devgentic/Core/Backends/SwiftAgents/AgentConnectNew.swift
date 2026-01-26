//
//  AgentConnectNew.swift
//  Devgentic
//
//  Created by Devgentic AI on 23/01/26.
//

import Foundation
import os
import SwiftAgent
import OpenFoundationModels
import OpenFoundationModelsCore
import OpenFoundationModelsOllama

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentConnectNew")

/// A unified agent connection service that prioritizes native SwiftAgent/Ollama execution
/// and falls back to the legacy Python bridge for other providers.
class AgentConnectNew: ObservableObject {
    
    // MARK: - Dependencies
    
    /// The legacy service used for non-Ollama agents (Python Bridge).
    private let legacyConnect: AgentConnect
    
    // MARK: - Initialization
    
    /// Initializes the new agent connector.
    /// - Parameter legacyBaseURL: The URL for the legacy Python backend (e.g., http://127.0.0.1:8000).
    init(legacyBaseURL: URL) {
        self.legacyConnect = AgentConnect(baseURL: legacyBaseURL)
        logger.info("AgentConnectNew initialized. Ready for Native Ollama & Legacy Fallback.")
    }
    
    // MARK: - Stream Handling
    
    /// Streams the agent response, routing to Native Ollama or Legacy Python based on the profile.
    /// - Parameters:
    ///   - profile: The backend profile configuration.
    ///   - userInput: The direct user query.
    ///   - chatHistory: The conversation history.
    ///   - conversationID: The ID of the current conversation (required for tool context).
    ///   - ragContext: Optional RAG context retrieved from the vector store.
    func streamAgentResponse(
        for profile: BackendProfileModel,
        userInput: String,
        chatHistory: [ChatMessage],
        conversationID: UUID,
        ragContext: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        
        // 1. Analyze Profile to determine routing
        if isNativeOllama(profile: profile) {
            logger.info("Routing to Native SwiftAgent (Ollama).")
            return streamNativeOllama(
                for: profile,
                userInput: userInput,
                chatHistory: chatHistory,
                conversationID: conversationID,
                ragContext: ragContext
            )
        } else {
            logger.info("Routing to Legacy AgentConnect (Python Bridge).")
            // For legacy, we fall back to appending context to the input if it exists
            // because the legacy API might not support a separate context field.
            var effectiveInput = userInput
            if let context = ragContext, !context.isEmpty {
                effectiveInput = "\(context)\n\nQuestion: \(userInput)"
            }
            return legacyConnect.streamAgentResponse(for: profile, userInput: effectiveInput, chatHistory: chatHistory)
        }
    }
    
    // MARK: - Native Ollama Implementation
    
    private func streamNativeOllama(
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
                    // We capture 'profileTools' here to map them to executable implementations
                    guard case .agent(let llmConfig, let profileTools, _, let instructions, _) = profile.details else {
                        throw NSError(domain: "AgentConnectNew", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid profile type for agent execution."])
                    }
                    
                    // 2. Configure Ollama Provider
                    // Use 127.0.0.1 by default to avoid IPv6/localhost resolution issues (Socket error 61)
                    let baseURLString = llmConfig.baseURL ?? "http://127.0.0.1:11434"
                    guard let baseURL = URL(string: baseURLString) else {
                        throw NSError(domain: "AgentConnectNew", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Base URL: \(baseURLString)"])
                    }
                    
                    let configuration = OllamaConfiguration(baseURL: baseURL, timeout: 120.0)
                    let model = OllamaLanguageModel(configuration: configuration, modelName: llmConfig.modelName)
                    
                    // 3. Initialize Tools
                    var activeTools: [any OpenFoundationModels.Tool] = []
                    
                    // A. Mandatory: Always add Vector Search (System Default)
                    // This allows RAG to work regardless of user profile settings if they have documents
                    let vectorTool = VectorSearchTool(conversationID: conversationID)
                    activeTools.append(vectorTool)
                    
                    // B. User Selection: Map Profile Tools to Executable Structs
                    // We need to fetch the unified tool sources to look up MCP details
                    let allToolSources = await UnifiedToolStore.shared.sources
                    
                    for toolConfig in profileTools where toolConfig.isEnabled {
                        // 1. Try Native Tools first
                        if let nativeTool = self.mapNativeToolToExecutable(toolName: toolConfig.name) {
                            activeTools.append(nativeTool)
                            logger.debug("Enabled Native Tool: \(toolConfig.name)")
                        }
                        // 2. Try MCP Tools
                        else if let mcpTool = self.mapMCPToolToExecutable(toolConfig: toolConfig, availableSources: allToolSources) {
                            activeTools.append(mcpTool)
                            logger.debug("Enabled MCP Tool: \(toolConfig.name)")
                        }
                        else {
                            logger.warning("Tool '\(toolConfig.name)' is enabled in profile but no executable implementation was found.")
                        }
                    }
                    
                    // 4. Prepare Transcript with Instructions, Tools, and History
                    var transcriptEntries: [OpenFoundationModels.Transcript.Entry] = []
                    
                    // A. Add Instructions + RAG Context + Tool Descriptions (System Level)
                    let baseInstructions = (instructions != nil && !instructions!.isEmpty) ? instructions! : "You are a helpful AI assistant running locally."
                    var finalSystemMessage = baseInstructions
                    
                    if let context = ragContext, !context.isEmpty {
                        // Inject RAG context into the System prompt.
                        finalSystemMessage += "\n\n### Relevant Context ###\nThe following information was retrieved from the user's knowledge base. Use it to answer the question if relevant:\n\(context)\n\n### End Context ###"
                    }
                    
                    // B. Inject Tool Instructions (Textual Description for the LLM)
                    // We must manually append this because we are building the transcript manually.
                    finalSystemMessage += self.generateToolInstructions(for: activeTools)
                    
                    // C. Create the Instructions Entry with explicit ToolDefinitions
                    let instructionsEntry = OpenFoundationModels.Transcript.Entry.instructions(
                        OpenFoundationModels.Transcript.Instructions(
                            segments: [.text(OpenFoundationModels.Transcript.TextSegment(content: finalSystemMessage))],
                            toolDefinitions: activeTools.map { OpenFoundationModels.Transcript.ToolDefinition(tool: $0) }
                        )
                    )
                    transcriptEntries.append(instructionsEntry)
                    
                    // D. Add Chat History
                    // The model will now see: [System(Context+Tools), User, Agent, User, Agent...]
                    let historyEntries = convertToTranscriptEntries(chatHistory)
                    transcriptEntries.append(contentsOf: historyEntries)
                    
                    // E. Create Transcript
                    let transcript = OpenFoundationModels.Transcript(entries: transcriptEntries)
                    
                    // 5. Initialize Session with Tools
                    // Crucial: We must pass the tools array here so the session can execute them
                    let session = LanguageModelSession(model: model, tools: activeTools, transcript: transcript)
                    
                    // 6. Stream Response
                    // Explicitly use OpenFoundationModels.Prompt
                    let prompt = OpenFoundationModels.Prompt(userInput)
                    
                    logger.debug("Starting native stream for model: \(llmConfig.modelName) with tools: \(activeTools.map { $0.name })")
                    
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
                    logger.error("Native Ollama Error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private func isNativeOllama(profile: BackendProfileModel) -> Bool {
        if case .agent(let llmConfig, _, _, _, _) = profile.details {
            return llmConfig.apiProvider == .ollama
        }
        return false
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
    
    /// Maps tool names (strings) from the BackendProfile to actual executable Native Tool instances.
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
            
        default:
            return nil
        }
    }
    
    /// Maps a tool configuration from the profile to a DynamicMCPTool if it exists in the MCP sources.
    private func mapMCPToolToExecutable(toolConfig: Tool, availableSources: [ToolSource]) -> (any OpenFoundationModels.Tool)? {
        // 1. Find the source (Server) that contains this tool
        guard let source = availableSources.first(where: { $0.id == toolConfig.sourceId }) else {
            return nil
        }
        
        // 2. Find the specific ToolDefinition within that source
        // We match by name.
        guard let definition = source.tools.first(where: { $0.name == toolConfig.name }) else {
            return nil
        }
        
        // 3. Wrap it in a DynamicMCPTool
        return DynamicMCPTool(source: source, toolDefinition: definition)
    }
    
    /// Generates the textual description of tools to append to the system prompt.
    /// This mimics `LanguageModelSession.generateToolInstructions` which is private.
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

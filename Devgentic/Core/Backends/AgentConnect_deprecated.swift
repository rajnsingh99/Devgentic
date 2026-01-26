//
//  AgentConnect.swift
//  Devgentic
//
//  Created by Raj Singh on 11/09/25.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentConnect")

// MARK: - AgentConnect Service

class AgentConnect: NSObject, URLSessionDataDelegate {

    private let baseURL: URL
    private var session: URLSession!
    
    private var activeContinuations: [URLSessionTask: AsyncThrowingStream<String, Error>.Continuation] = [:]
    
    private var buffer: Data = Data()
    
    private let jsonDecoder = JSONDecoder()

    init(baseURL: URL) {
        self.baseURL = baseURL
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
    }
    
    private struct ChunkPayload: Codable {
        let chunk: String
    }

    /// Connects to the python server's `invoke_agent_stream` endpoint.
    func streamAgentResponse(
        for profile: BackendProfileModel,
        userInput: String,
        chatHistory: [ChatMessage]
    ) -> AsyncThrowingStream<String, Error> {
        let endpointURL = baseURL.appendingPathComponent("/api/invoke_agent_stream")
        
        return AsyncThrowingStream { continuation in
            Task {
                guard case .agent(let llmConfig, let profileTools, let description, let instructions, _) = profile.details else {
                    let error = NSError(domain: "AgentConnectError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid profile type provided. Expected .agent."])
                    continuation.finish(throwing: error)
                    return
                }

                let systemPrompt = buildSystemPrompt(description: description, instructions: instructions)
                
                // --- TOOL NAMESPACING LOGIC ---
                // MODIFIED: The logic is now much simpler. The 'enabledTool' struct
                // from the profile already contains all necessary information, including parameters.
                let allSources = await UnifiedToolStore.shared.sources
                let enabledTools = profileTools.filter { $0.isEnabled }
                
                let toolConfigs: [AgentToolConfig] = enabledTools.compactMap { enabledTool -> AgentToolConfig? in
                    // 1. Find the source name for creating the prefixed name.
                    guard let source = allSources.first(where: { $0.id == enabledTool.sourceId }) else {
                        logger.warning("Could not find source with ID '\(String(describing: enabledTool.sourceId))' for tool '\(enabledTool.name)'. It will be excluded.")
                        return nil
                    }
                    
                    // REMOVED: The complex logic to differentiate between local and MCP tools
                    // to find parameters is no longer needed. The correct parameters are already
                    // part of the 'enabledTool' object.
                    
                    // 2. Create the unique, prefixed name (e.g., "BuiltinTools_execute_shell")
                    let namespacedName = ToolNamer.prefixedName(for: enabledTool.name, from: source.serverName)

                    // 3. Create the final config for the Python agent using the data directly from the tool.
                    return AgentToolConfig(
                        name: namespacedName,
                        description: enabledTool.description,
                        parameters: enabledTool.parameters
                    )
                }
                // --- END TOOL NAMESPACING LOGIC ---


                let historyForPayload = chatHistory.dropLast()

                let requestPayload = SingleAgentRequest(
                    input: userInput,
                    agentConfig: AgentConfig(
                        llm: LLMConfig(
                            provider: llmConfig.apiProvider.providerString,
                            model: llmConfig.modelName,
                            apiKey: llmConfig.apiKey
                        ),
                        tools: toolConfigs,
                        systemPrompt: systemPrompt
                    ),
                    sessionState: SessionState(
                        chatHistory: historyForPayload.compactMap { AgentChatMessage(from: $0) }
                    )
                )
                
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .prettyPrinted
                    let payloadData = try encoder.encode(requestPayload)
                    if let payloadString = String(data: payloadData, encoding: .utf8) {
                        logger.debug("Sending agent request to Python server:\n---\n\(payloadString)\n---")
                    }
                } catch {
                    logger.error("Failed to encode agent request payload for logging: \(error.localizedDescription)")
                }
                
                do {
                    var request = URLRequest(url: endpointURL)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONEncoder().encode(requestPayload)
                    
                    let task = session.dataTask(with: request)
                    activeContinuations[task] = continuation
                    
                    continuation.onTermination = { @Sendable [weak self] _ in
                        logger.info("Stream terminated. Cancelling task.")
                        task.cancel()
                        self?.activeContinuations.removeValue(forKey: task)
                    }
                    
                    task.resume()
                    
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - URLSessionDataDelegate Methods

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        processBuffer(for: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation = activeContinuations[task] else { return }
        
        if !buffer.isEmpty {
            processBuffer(for: task as! URLSessionDataTask)
        }
        
        if let error = error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        activeContinuations.removeValue(forKey: task)
    }
    
    private func processBuffer(for dataTask: URLSessionDataTask) {
        guard let continuation = activeContinuations[dataTask] else { return }
        
        let separator = "\n\n".data(using: .utf8)!
        
        while let range = buffer.range(of: separator) {
            let eventData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)

            if let eventString = String(data: eventData, encoding: .utf8) {
                let lines = eventString.split(whereSeparator: \.isNewline)
                for line in lines {
                    if line.hasPrefix("data: ") {
                        let jsonDataString = String(line.dropFirst(6))
                        if let jsonData = jsonDataString.data(using: .utf8) {
                            do {
                                let payload = try jsonDecoder.decode(ChunkPayload.self, from: jsonData)
                                continuation.yield(payload.chunk)
                            } catch {
                                logger.error("AGENT_CONNECT_DECODE_ERROR: Failed to decode chunk: \(error.localizedDescription) for payload: \(jsonDataString)")
                            }
                        }
                    }
                }
            }
        }
    }

    private func buildSystemPrompt(description: String?, instructions: String?) -> String {
        var parts: [String] = []
        if let desc = description, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Your role: \(desc)")
        }
        if let inst = instructions, !inst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Follow these instructions carefully:\n\(inst)")
        }
        return parts.isEmpty ? "You are a helpful AI assistant." : parts.joined(separator: "\n\n")
    }
}

// MARK: - Codable Request Structures

struct SingleAgentRequest: Codable {
    let input: String
    let agentConfig: AgentConfig
    let sessionState: SessionState
    
    enum CodingKeys: String, CodingKey {
        case input
        case agentConfig = "agent_config"
        case sessionState = "session_state"
    }
}

struct AgentConfig: Codable {
    let llm: LLMConfig
    let tools: [AgentToolConfig]
    let systemPrompt: String?
    
    enum CodingKeys: String, CodingKey {
        case llm, tools
        case systemPrompt = "system_prompt"
    }
}

struct LLMConfig: Codable {
    let provider: String
    let model: String
    let apiKey: String?
    
    enum CodingKeys: String, CodingKey {
        case provider, model
        case apiKey = "api_key"
    }
}

struct AgentToolConfig: Codable {
    let name: String
    let description: String
    let parameters: ToolParameters
}

struct SessionState: Codable {
    let chatHistory: [AgentChatMessage]
    let scratchpad: [String: String]? = [:] // Empty for now
    
    enum CodingKeys: String, CodingKey {
        case chatHistory = "chat_history"
        case scratchpad
    }
}

struct AgentChatMessage: Codable {
    let role: String
    let content: String
    
    init?(from message: ChatMessage) {
        switch message.sender {
        case .user:
            self.role = "human"
        case .agent:
            self.role = "ai"
        }
        
        guard let textContent = message.content.textContent else { return nil }
        self.content = textContent
    }
}

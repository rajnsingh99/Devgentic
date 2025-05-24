//
//  DefaultLLMCommunicator.swift
//  Devgentic
//
//  Created by Raj Singh on 15/05/25.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "DefaultLLMCommunicator")

class DefaultLLMCommunicator: LLMCommunicatorProtocol {

    private let aiConnect: AIConnect // For Ollama direct calls
    private let agentConnect: AgentConnect // For Python Agent calls
    
    // This responseHandler will now be primarily for Ollama or other non-agent backends
    private let ollamaResponseHandler: AgentResponseHandler // Assuming AgentResponseHandler can also handle Ollama, or rename if it's Ollama-specific
    private let agentResponseParser: AgentResponseParser // Specific parser for the Python Agent

    private let fileProcessorService: FileProcessorService

    init(aiConnect: AIConnect = AIConnect(),
         agentConnect: AgentConnect = AgentConnect(),
         ollamaResponseHandler: AgentResponseHandler = AgentResponseHandler(), // For Ollama
         agentResponseParser: AgentResponseParser = AgentResponseParser(),   // For Agent
         fileProcessorService: FileProcessorService = FileProcessorService()) {
        self.aiConnect = aiConnect
        self.agentConnect = agentConnect
        self.ollamaResponseHandler = ollamaResponseHandler
        self.agentResponseParser = agentResponseParser
        self.fileProcessorService = fileProcessorService
    }

    func sendMessage(
        parts: [MessagePart],
        to backendType: BackendType,
        config: BackendConfiguration
    ) async throws -> LLMResponse {

        var finalPayloadString: String
        var mutablePayload = config.payload

        let targetURL = config.url
        let targetEndpoint = config.endpoint
        
        let responseData: Data
        let responseText: String
        let parsedContents: [MessageContent]

        switch backendType {
        case .ollama:
            finalPayloadString = constructOllamaPrompt(from: parts, fileProcessorService: self.fileProcessorService)
            mutablePayload["prompt"] = finalPayloadString
            logger.debug("Constructed Ollama prompt (first 200 chars): '\(finalPayloadString.prefix(200))'")
            logger.debug("Ollama payload for \(targetURL)\(targetEndpoint): \(mutablePayload)")
            
            let specificAIConnect = AIConnect(baseURL: targetURL)
            responseData = try await specificAIConnect.postToLocalServer(
                endpoint: targetEndpoint,
                payload: mutablePayload
            )
            
            // Use the ollamaResponseHandler for Ollama
            responseText = try self.ollamaResponseHandler.parseInitialResponse(data: responseData, for: .ollama) // Explicitly pass .ollama
            parsedContents = self.ollamaResponseHandler.parseTextToMessageContent(responseText)

        case .agent:
            finalPayloadString = constructAgentPayload(from: parts, fileProcessorService: self.fileProcessorService)
            let agentChatPayload: [String: Any] = ["input": finalPayloadString]
            
            logger.debug("Constructed Agent input string (first 200 chars): '\(finalPayloadString.prefix(200))'")
            logger.debug("Agent payload for \(targetURL)\(targetEndpoint): \(agentChatPayload)")

            let specificAgentConnect = AgentConnect(baseURL: targetURL)
            responseData = try await specificAgentConnect.postToAgentServer(
                endpoint: targetEndpoint,
                payload: agentChatPayload
            )

            // Use the new AgentResponseParser for the agent
            do {
                responseText = try self.agentResponseParser.parse(data: responseData)
                parsedContents = self.agentResponseParser.parseTextToMessageContent(responseText)
            } catch let agentError as AgentError {
                // Log and rethrow agent-specific errors
                logger.error("AgentError while processing agent response: \(agentError.localizedDescription)")
                // Construct an LLMResponse that includes the error for display
                return LLMResponse(content: [MessageContent.error(title: "Agent Communication Error", details: agentError.localizedDescription)], rawResponseText: String(data: responseData, encoding: .utf8), error: agentError)
            } catch {
                // Catch any other unexpected error during agent response parsing
                logger.error("Unexpected error while processing agent response: \(error.localizedDescription)")
                return LLMResponse(content: [MessageContent.error(title: "Agent Response Error", details: error.localizedDescription)], rawResponseText: String(data: responseData, encoding: .utf8), error: error)
            }
        }
        
        // Common success path after parsing
        logger.info("Successfully received and parsed response from \(backendType.rawValue).")
        return LLMResponse(content: parsedContents, rawResponseText: responseText)
        
        // Note: The original top-level catch block for network errors from aiConnect/agentConnect
        // is implicitly handled by the `try await` calls. If those throw, the function will exit.
        // The try/catch around agent parsing is specific to errors *after* a successful network call.
    }

    // MARK: - Payload Construction Helpers (remain unchanged)

    private func constructOllamaPrompt(from parts: [MessagePart], fileProcessorService: FileProcessorService) -> String {
        var promptComponents: [String] = []
        for part in parts {
            switch part.type {
            case .text:
                if !part.content.isEmpty {
                    promptComponents.append(part.content)
                }
            case .file:
                guard let rep = part.fileRepresentation else { continue }
                switch rep {
                case .inlineContent(let fileName, let content, _):
                    promptComponents.append("\n\n--- Content of file: \(fileName) ---\n\(content)\n--- End of file: \(fileName) ---")
                case .localPath(let fileName, let path, let mimeType):
                    let fileURL = URL(fileURLWithPath: path)
                    var instruction = "\n\n--- File Reference: \(fileName) (Type: \(mimeType)) ---"
                    instruction += "\nThe content of the file '\(fileName)' is available at the local path: \(path)."
                    
                    if fileProcessorService.isImageFile(mimeType: mimeType, url: fileURL) {
                         instruction += " This is an image file. If you are a multimodal model capable of processing local image paths, please analyze it."
                    } else if fileProcessorService.isTextFile(mimeType: mimeType, url: fileURL) {
                        instruction += " This is a text-based file. Please read and consider its content."
                    } else {
                        instruction += " This is a binary file. You may not be able to process its content directly."
                    }
                    instruction += "\n--- End File Reference: \(fileName) ---"
                    promptComponents.append(instruction)
                case .remoteReference(let fileName, _, let serviceName, _):
                    logger.warning("Encountered remoteReference for Ollama prompt construction: \(rep.description). This is unusual.")
                    promptComponents.append("\n\n--- Note: A remote file '\(fileName)' from service '\(serviceName)' was referenced but may not be usable by this local LLM. ---")
                case .unprocessable(let fileName, let reason, _):
                    promptComponents.append("\n\n--- Note: File '\(fileName)' could not be processed. Reason: \(reason) ---")
                }
            }
        }
        return promptComponents.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func constructAgentPayload(from parts: [MessagePart], fileProcessorService: FileProcessorService) -> String {
        var payloadComponents: [String] = []
        for part in parts {
            switch part.type {
            case .text:
                if !part.content.isEmpty {
                    payloadComponents.append(part.content)
                }
            case .file:
                guard let rep = part.fileRepresentation else { continue }
                
                switch rep {
                case .inlineContent(let fileName, let content, let mimeType):
                    payloadComponents.append("\n\n--- Attached File: \(fileName) (Type: \(mimeType)) ---\n\(content)\n--- End of File: \(fileName) ---")
                case .localPath(let fileName, let path, let mimeType):
                    payloadComponents.append("\n\n--- Referenced File: \(fileName) (Type: \(mimeType)) ---")
                    payloadComponents.append("Local path: \(path)")
                    payloadComponents.append("Note: The agent may not be able to directly access this local file path. If the content is critical, ensure it's provided as inline text if possible.")
                    payloadComponents.append("--- End File Reference: \(fileName) ---")
                    logger.warning("Local path provided for agent payload for file '\(fileName)'. Agent might not have direct access to this path. The information is passed as text.")
                case .remoteReference(let fileName, let serviceFileId, let serviceName, let mimeType):
                    payloadComponents.append("\n\n--- Referenced Remote File: \(fileName) (Type: \(mimeType)) ---")
                    payloadComponents.append("Service: \(serviceName), ID: \(serviceFileId)")
                    payloadComponents.append("Note: The agent may not be able to access this remote file.")
                    payloadComponents.append("--- End File Reference: \(fileName) ---")
                case .unprocessable(let fileName, let reason, let mimeType):
                    payloadComponents.append("\n\n--- Note: File '\(fileName)' (Type: \(mimeType ?? "unknown")) could not be processed. Reason: \(reason) ---")
                }
            }
        }
        return payloadComponents.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

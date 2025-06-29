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

    private let aiConnect: OllamaConnect // For Ollama direct calls
    private let agentConnect: AgentConnect // For Python Agent calls
    
    // This responseHandler will now be primarily for Ollama or other non-agent backends
    private let ollamaResponseHandler: AgentResponseHandler // Assuming AgentResponseHandler can also handle Ollama, or rename if it's Ollama-specific
    private let agentResponseParser: AgentResponseParser // Specific parser for the Python Agent

    private let fileProcessorService: FileProcessorService

    init(aiConnect: OllamaConnect = OllamaConnect(),
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
    
    // MARK: - New method for sending structured Agent payloads
    func sendMessage(
        payload: AgentOrchestrationRequest,
        to backendType: BackendType,
        config: BackendConfiguration
    ) async throws -> LLMResponse {
        guard backendType == .agent else {
            throw NSError(domain: "CommunicatorError", code: 0, userInfo: [NSLocalizedDescriptionKey: "This sendMessage function is only for the .agent backend type."])
        }

        let targetURL = config.url
        let targetEndpoint = config.endpoint
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted // Good for debugging
            let payloadData = try encoder.encode(payload)
            
            if let jsonString = String(data: payloadData, encoding: .utf8) {
                logger.debug("Sending Agent Payload to \(targetURL)\(targetEndpoint):\n\(jsonString)")
            }

            let specificAgentConnect = AgentConnect(baseURL: targetURL)
            let responseData = try await specificAgentConnect.postToAgentServer(
                endpoint: targetEndpoint,
                payloadData: payloadData
            )

            // Use the new AgentResponseParser for the agent
            let responseText = try self.agentResponseParser.parse(data: responseData)
            let parsedContents = self.agentResponseParser.parseTextToMessageContent(responseText)
            
            logger.info("Successfully received and parsed response from \(backendType.rawValue).")
            return LLMResponse(content: parsedContents, rawResponseText: responseText)
            
        } catch let agentError as AgentError {
            logger.error("AgentError while processing agent response: \(agentError.localizedDescription)")
            return LLMResponse(content: [MessageContent.error(title: "Agent Communication Error", details: agentError.localizedDescription)], rawResponseText: nil, error: agentError)
        } catch {
            logger.error("Unexpected error while processing agent response: \(error.localizedDescription)")
            return LLMResponse(content: [MessageContent.error(title: "Agent Response Error", details: error.localizedDescription)], rawResponseText: nil, error: error)
        }
    }


    // MARK: - Existing method for string-based Ollama payloads
    func sendMessage(
        parts: [MessagePart],
        to backendType: BackendType,
        config: BackendConfiguration
    ) async throws -> LLMResponse {
        
        guard backendType == .ollama else {
             throw NSError(domain: "CommunicatorError", code: 0, userInfo: [NSLocalizedDescriptionKey: "This sendMessage function is only for the .ollama backend type."])
        }

        var mutablePayload = config.payload
        let targetURL = config.url
        let targetEndpoint = config.endpoint
        
        let finalPayloadString = constructOllamaPrompt(from: parts, fileProcessorService: self.fileProcessorService)
        mutablePayload["prompt"] = finalPayloadString
        logger.debug("Constructed Ollama prompt (first 200 chars): '\(finalPayloadString.prefix(200))'")
        logger.debug("Ollama payload for \(targetURL)\(targetEndpoint): \(mutablePayload)")
        
        let specificAIConnect = OllamaConnect(baseURL: targetURL)
        let responseData = try await specificAIConnect.postToLocalServer(
            endpoint: targetEndpoint,
            payload: mutablePayload
        )
        
        let responseText = try self.ollamaResponseHandler.parseInitialResponse(data: responseData, for: .ollama)
        let parsedContents = self.ollamaResponseHandler.parseTextToMessageContent(responseText)
        
        logger.info("Successfully received and parsed response from \(backendType.rawValue).")
        return LLMResponse(content: parsedContents, rawResponseText: responseText)
    }

    // MARK: - Payload Construction Helpers (Ollama only)

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
}

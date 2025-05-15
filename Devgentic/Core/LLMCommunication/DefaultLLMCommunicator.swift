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

    private let aiConnect: AIConnect
    private let responseHandler: AgentResponseHandler
    private let fileProcessorService: FileProcessorService

    init(aiConnect: AIConnect = AIConnect(),
         responseHandler: AgentResponseHandler = AgentResponseHandler(),
         fileProcessorService: FileProcessorService = FileProcessorService()) {
        self.aiConnect = aiConnect
        self.responseHandler = responseHandler
        self.fileProcessorService = fileProcessorService
    }

    func sendMessage(
        parts: [MessagePart],
        to backendType: BackendType,
        config: BackendConfiguration
    ) async throws -> LLMResponse {

        let finalPayloadString: String
        var mutablePayload = config.payload

        switch backendType {
        case .ollama:
            // Pass the fileURL to the constructOllamaPrompt if needed, or ensure it's reconstructed inside
            finalPayloadString = constructOllamaPrompt(from: parts, fileProcessorService: self.fileProcessorService)
            mutablePayload["prompt"] = finalPayloadString
            logger.debug("Constructed Ollama prompt (first 200 chars): '\(finalPayloadString.prefix(200))'")
        case .agent:
            finalPayloadString = constructAgentPayload(from: parts, fileProcessorService: self.fileProcessorService)
            mutablePayload["main_task"] = finalPayloadString
            logger.debug("Constructed Agent payload (first 200 chars): '\(finalPayloadString.prefix(200))'")
        }
        
        let finalConfig = BackendConfiguration(
            url: config.url,
            endpoint: config.endpoint,
            payload: mutablePayload
        )

        do {
            logger.debug("Communicator sending to \(finalConfig.url)\(finalConfig.endpoint).")
            
            let responseData = try await self.aiConnect.postToLocalServer(
                endpoint: finalConfig.endpoint,
                payload: finalConfig.payload
            )
            
            let responseText = try self.responseHandler.parseInitialResponse(data: responseData, for: backendType)
            let parsedContents = self.responseHandler.parseTextToMessageContent(responseText)
            
            logger.info("Successfully received and parsed response from \(backendType.rawValue).")
            return LLMResponse(content: parsedContents, rawResponseText: responseText)
            
        } catch {
            logger.error("Error in DefaultLLMCommunicator.sendMessage for \(backendType.rawValue): \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Payload Construction Helpers

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
                    let fileURL = URL(fileURLWithPath: path) // Reconstruct URL to pass to helper
                    var instruction = "\n\n--- File Reference: \(fileName) (Type: \(mimeType)) ---"
                    instruction += "\nThe content of the file '\(fileName)' is available at the local path: \(path)."
                    
                    // Use the fileURL when calling isImageFile and isTextFile
                    if fileProcessorService.isImageFile(mimeType: mimeType, url: fileURL) { // Pass URL
                         instruction += " This is an image file. If you are a multimodal model capable of processing local image paths, please analyze it."
                    } else if fileProcessorService.isTextFile(mimeType: mimeType, url: fileURL) { // Pass URL
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
                // Similar to constructOllamaPrompt, ensure fileURL is available if calling isTextFile/isImageFile
                var fileURLForAgentCheck: URL? = nil
                if case .localPath(_, let path, _) = rep {
                    fileURLForAgentCheck = URL(fileURLWithPath: path)
                }
                // Add more sophisticated agent payload construction here if needed, potentially using fileURLForAgentCheck

                switch rep {
                case .inlineContent(let fileName, let content, _):
                    payloadComponents.append("\n\nAttached File (\(fileName)) Content:\n\(content)")
                case .localPath(let fileName, let path, _):
                    payloadComponents.append("\n\nReferenced File: \(fileName) (local path: \(path) - may not be accessible to agent)")
                    logger.warning("Local path provided for agent payload for file '\(fileName)'. Agent might not have access.")
                case .remoteReference(let fileName, let serviceFileId, let serviceName, _):
                    payloadComponents.append("\n\nReferenced Remote File: \(fileName) (ID: \(serviceFileId) on \(serviceName))")
                case .unprocessable(let fileName, let reason, _):
                    payloadComponents.append("\n\nNote: File '\(fileName)' was not processed. Reason: \(reason)")
                }
            }
        }
        return payloadComponents.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

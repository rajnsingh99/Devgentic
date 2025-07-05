//
//  DefaultLLMCommunicator.swift
//  Devgentic
//
//  Created by Raj Singh on 15/05/25.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "DefaultLLMCommunicator")

class DefaultLLMCommunicator {
    
    private let agentConnect: AgentConnect
    private let agentResponseParser: AgentResponseParser
    
    init(agentConnect: AgentConnect = AgentConnect(),
         agentResponseParser: AgentResponseParser = AgentResponseParser()) {
        self.agentConnect = agentConnect
        self.agentResponseParser = agentResponseParser
    }
    
    func sendMessage(
        payload: AgentOrchestrationRequest,
        to backendType: BackendType
    ) async throws -> LLMResponse {
        guard backendType == .agent else {
            throw NSError(domain: "CommunicatorError", code: 0, userInfo: [NSLocalizedDescriptionKey: "This sendMessage function is only for the .agent backend type."])
        }
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let payloadData = try encoder.encode(payload)
            
            if let jsonString = String(data: payloadData, encoding: .utf8) {
                logger.debug("Sending Agent Payload to \(GlobalConstants.agentEndpoint):\n\(jsonString)")
            }
            
            let specificAgentConnect = AgentConnect()
            let responseData = try await specificAgentConnect.postToAgentServer(
                payloadData: payloadData
            )
            
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
}

//
//  AgentService.swift
//  Devgentic
//
//  Created by Raj Singh on 06/07/25.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentService")

/// This service is responsible for communicating directly with the Python-based agent server.
class AgentService {
    private let agentConnect = AgentConnect()
    // AgentResponseParser and AgentError are assumed to be defined elsewhere in the project.
    private let agentResponseParser = AgentResponseParser()

    /// Encodes the request and sends it to the agent server.
    /// - Parameter payload: The fully constructed `AgentOrchestrationRequest` to be sent.
    /// - Returns: A tuple containing the parsed message content and an optional error.
    func sendMessage(payload: AgentOrchestrationRequest) async throws -> (contents: [MessageContent], error: Error?) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let payloadData = try encoder.encode(payload)

            if let jsonString = String(data: payloadData, encoding: .utf8) {
                logger.debug("Sending Agent Payload to \(GlobalConstants.agentEndpoint):\n\(jsonString)")
            }

            let responseData = try await agentConnect.postToAgentServer(payloadData: payloadData)
            let responseText = try agentResponseParser.parse(data: responseData)
            let parsedContents = agentResponseParser.parseTextToMessageContent(responseText)
            
            // If parsing succeeds, assume no error from this stage.
            // The raw response might contain its own error messages, which are parsed into MessageContent.
            return (parsedContents, nil)
            
        } catch let agentError as AgentError {
            logger.error("AgentError while processing agent response: \(agentError.localizedDescription)")
            throw agentError
        } catch {
            logger.error("Unexpected error while sending message to agent: \(error.localizedDescription)")
            throw error
        }
    }
}

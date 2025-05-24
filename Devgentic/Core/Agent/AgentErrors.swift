//
//  AgentErrors.swift
//  Devgentic
//
//  Created by Raj Singh on 22/05/25.
//

import Foundation

/// Errors that can occur when interacting with the Python Agent.
enum AgentError: Error, LocalizedError {
    /// The agent server returned a JSON payload that was missing the expected "response" key for a successful message.
    case missingResponseKey(responseData: String?)
    
    /// The agent server returned a JSON payload indicating an error, with a message.
    case agentReportedError(message: String)
    
    /// The data received from the agent server was not valid JSON or could not be serialized as expected.
    case invalidJSONResponse(details: String, responseData: String?)
    
    /// An unexpected response structure was received from the agent.
    case unexpectedResponseStructure(responseData: String?)

    public var errorDescription: String? {
        switch self {
        case .missingResponseKey(let data):
            return "Agent Error: Successful response from agent was missing the 'response' key. Data: \(data ?? "nil")"
        case .agentReportedError(let message):
            return "Agent Error: The agent reported an error: \(message)"
        case .invalidJSONResponse(let details, let data):
            return "Agent Error: Could not parse JSON response from agent. Details: \(details). Data: \(data ?? "nil")"
        case .unexpectedResponseStructure(let data):
            return "Agent Error: Received an unexpected response structure from the agent. Data: \(data ?? "nil")"
        }
    }
}

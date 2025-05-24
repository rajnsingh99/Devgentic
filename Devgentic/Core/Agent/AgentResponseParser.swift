//
//  AgentResponseParser.swift
//  Devgentic
//
//  Created by Raj Singh on 22/05/25.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentResponseParser")

struct AgentResponseParser {

    /// Parses the raw data from the agent server.
    /// - Parameter data: The `Data` object received from the agent server.
    /// - Returns: The processed text string from the agent's "response" field.
    /// - Throws: An `AgentError` if parsing fails or the agent reports an error.
    func parse(data: Data) throws -> String {
        let rawResponseForErrorLogging = String(data: data, encoding: .utf8)
        
        do {
            guard let jsonObject = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                logger.error("Failed to cast JSON object to [String: Any]. Raw data: \(rawResponseForErrorLogging ?? "Non-UTF8 data")")
                throw AgentError.invalidJSONResponse(details: "Could not cast to [String: Any].", responseData: rawResponseForErrorLogging)
            }

            // Check if the agent reported an error in the JSON payload
            if let errorMessage = jsonObject["error"] as? String {
                logger.error("Agent server reported an error in its response: \(errorMessage)")
                throw AgentError.agentReportedError(message: errorMessage)
            }

            // Check for the expected "response" key for successful messages
            if let responseText = jsonObject["response"] as? String {
                logger.debug("Successfully parsed agent response text.")
                return responseText
            }
            
            // If neither "error" nor "response" key is found with a string value
            logger.error("Agent response JSON did not contain a valid 'response' or 'error' string. Keys: \(jsonObject.keys.joined(separator: ", ")). Raw data: \(rawResponseForErrorLogging ?? "Non-UTF8 data")")
            throw AgentError.missingResponseKey(responseData: rawResponseForErrorLogging)

        } catch let error as AgentError {
            // Re-throw AgentErrors directly
            throw error
        } catch {
            // Catch other JSONSerialization errors or unexpected issues
            logger.error("Failed to parse agent JSON response. Error: \(error.localizedDescription). Raw data: \(rawResponseForErrorLogging ?? "Non-UTF8 data")")
            throw AgentError.invalidJSONResponse(details: error.localizedDescription, responseData: rawResponseForErrorLogging)
        }
    }

    /// Parses the successfully extracted text response into `MessageContent` array.
    /// For now, this treats the entire agent response as a single plain text block.
    /// This can be expanded later if the agent starts returning more structured content.
    /// - Parameter text: The text string extracted from the agent's response.
    /// - Returns: An array of `MessageContent`.
    func parseTextToMessageContent(_ text: String) -> [MessageContent] {
        if text.isEmpty {
            // If the agent legitimately returns an empty string, represent it as such or decide if it's an error.
            // For now, returning an empty array of content.
            logger.info("Agent response text was empty.")
            return []
        }
        // Currently, all agent responses are treated as plain text.
        // This could be enhanced to detect markdown, code blocks, etc., if the agent's output becomes more complex.
        return [MessageContent.plainText(text)]
    }
}

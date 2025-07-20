//
//  AgentResponseParser.swift
//  Devgentic
//
//  Created by Raj Singh on 22/05/25.
//

import Foundation
import os
// import Markdown // REMOVED: This was causing the conflict.

// ---
// MARK: - Reason for Disabling Markdown Parsing (2025-07-18)
//
// The 'apple/swift-markdown' library was removed from this file and the project
// because it was causing a critical build failure.
//
// **Problem:**
// The project uses another Markdown library, 'Down', which is required by other
// dependencies. Both 'Down' and 'apple/swift-markdown' include their own compiled
// version of the C library 'cmark'. This resulted in over 100 "duplicate symbol"
// linker errors during the build process, as the linker found two definitions for
// every cmark function.
//
// **Temporary Solution:**
// To resolve the build failure, all code related to 'apple/swift-markdown' has been
// removed from this parser. The `parseTextToMessageContent` function has been modified
// to bypass all Markdown processing and treat the agent's entire response as a
// single block of plain text.
//
// **Removed Code:**
// - `import Markdown`
// - The entire implementation of `parseTextToMessageContent` which used `Document(parsing:)`.
// - All private helper functions: `processMarkdownBlock`, `processImageNode`, and `appendAsMarkdown`.
//
// **Next Steps:**
// The long-term solution is to re-implement the parsing logic in `parseTextToMessageContent`
// using the 'Down' library to restore rich Markdown rendering.
// ---

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentResponseParser")

struct AgentResponseParser {

    /// Parses the raw data from the agent server, checking for explicit errors first.
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
            
            logger.error("Agent response JSON did not contain a valid 'response' or 'error' string. Keys: \(jsonObject.keys.joined(separator: ", ")). Raw data: \(rawResponseForErrorLogging ?? "Non-UTF8 data")")
            throw AgentError.missingResponseKey(responseData: rawResponseForErrorLogging)

        } catch let error as AgentError {
            throw error
        } catch {
            logger.error("Failed to parse agent JSON response. Error: \(error.localizedDescription). Raw data: \(rawResponseForErrorLogging ?? "Non-UTF8 data")")
            throw AgentError.invalidJSONResponse(details: error.localizedDescription, responseData: rawResponseForErrorLogging)
        }
    }

    /// Parses an agent's response string into an array of `MessageContent` blocks.
    /// - Parameter responseText: The text response from the agent.
    /// - Returns: An array of `MessageContent` objects.
    func parseTextToMessageContent(_ responseText: String) -> [MessageContent] {
        logger.debug("Temporarily disabling Markdown parsing. Returning content as plain text.")
        
        // --- MODIFIED: Bypassing all Markdown logic ---
        // If the text is not empty, return it as a single plainText block.
        if !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.plainText(responseText)]
        }
        
        // Otherwise, return an empty array.
        return []
    }
    
    // --- REMOVED ---
    // All private helper functions that used the Markdown library have been removed
    // to eliminate the dependency (`processMarkdownBlock`, `processImageNode`, etc.)
}

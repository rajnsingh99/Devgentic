//
//  AgentResponseParser.swift
//  Devgentic
//
//  Created by Raj Singh on 22/05/25.
//

import Foundation
import os
import Markdown

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

    // --- MODIFIED: This logic is now copied from the more advanced AgentResponseHandler ---
    /// Parses an agent's response string (potentially Markdown) into an array of `MessageContent` blocks.
    /// - Parameter responseText: The text response from the agent.
    /// - Returns: An array of `MessageContent` objects.
    func parseTextToMessageContent(_ responseText: String) -> [MessageContent] {
        logger.debug("Parsing agent response string (length: \(responseText.count)) into MessageContent blocks...")
        var contentBlocks: [MessageContent] = []
        let document = Document(parsing: responseText)

        for block in document.children {
            processMarkdownBlock(block, into: &contentBlocks)
        }

        // If Markdown parsing results in no blocks, but the text isn't empty,
        // treat the whole response as a single plain text block.
        if contentBlocks.isEmpty && !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
             logger.warning("Markdown parsing resulted in no content blocks for non-empty response. Returning original text as plain.")
             return [.plainText(responseText)]
         }

        logger.info("Parsed response into \(contentBlocks.count) MessageContent blocks.")
        return contentBlocks
    }

    private func processMarkdownBlock(_ block: Markup, into contentBlocks: inout [MessageContent]) {
        switch block {
        case let codeBlock as CodeBlock:
             let codeContent = codeBlock.code.trimmingCharacters(in: .whitespacesAndNewlines)
             if !codeContent.isEmpty {
                 logger.trace("Found Code Block, language: \(codeBlock.language ?? "nil")")
                 contentBlocks.append(.codeBlock(language: codeBlock.language, code: codeContent))
             } else { logger.trace("Skipping empty Code Block.") }

        case let paragraph as Paragraph:
            // Check if the paragraph solely contains an image
            let childrenArray = Array(paragraph.children)
            if childrenArray.count == 1, let imageNode = childrenArray.first as? Markdown.Image {
                logger.trace("Found Paragraph containing only an Image.")
                processImageNode(imageNode, into: &contentBlocks)
            } else {
                // Otherwise, treat as general markdown content
                appendAsMarkdown(paragraph, into: &contentBlocks)
            }

        case let imageNode as Markdown.Image: // Direct image node (less common at top level)
             logger.trace("Found direct Image Node.")
             processImageNode(imageNode, into: &contentBlocks)

        case let blockquote as BlockQuote:
             let quoteContent = blockquote.format().trimmingCharacters(in: .whitespacesAndNewlines)
             if !quoteContent.isEmpty {
                 logger.trace("Found Block Quote.")
                 contentBlocks.append(.markdownText(quoteContent))
             } else { logger.trace("Skipping empty Block Quote.") }
        
        // For other types like ThematicBreak, Heading, List, etc., format them as markdown.
        default:
            appendAsMarkdown(block, into: &contentBlocks)
        }
    }

    private func processImageNode(_ imageNode: Markdown.Image, into contentBlocks: inout [MessageContent]) {
        let urlString = imageNode.source
        let altText = imageNode.plainText // plainText usually extracts alt text

        if let sUrl = urlString, !sUrl.isEmpty {
            let url = URL(string: sUrl) // URL(string:) can return nil if sUrl is invalid
            logger.trace("Found Image Node, url: \(sUrl), alt: \(altText)")
            contentBlocks.append(.image(url: url, alt: altText))
        } else {
            logger.warning("Skipping Image Node with missing or empty source URL.")
        }
    }

    private func appendAsMarkdown(_ block: Markup, into contentBlocks: inout [MessageContent]) {
         // Format the entire block as a Markdown string
         let markdownContent = block.format().trimmingCharacters(in: .whitespacesAndNewlines)
         if !markdownContent.isEmpty {
             logger.trace("Found block of type '\(type(of: block))', treating as Markdown content.")
             // Check if the last block was also markdown, if so, append. Otherwise, new block.
             if let lastContent = contentBlocks.last, case .markdownText(let existingText) = lastContent {
                 contentBlocks[contentBlocks.count - 1] = .markdownText(existingText + "\n\n" + markdownContent)
             } else {
                 contentBlocks.append(.markdownText(markdownContent))
             }
         } else {
             logger.trace("Skipping empty formatted block of type '\(type(of: block))'.")
         }
     }
}

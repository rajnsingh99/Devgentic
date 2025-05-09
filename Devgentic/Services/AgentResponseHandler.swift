// Services/AgentResponseHandler.swift
import Foundation
import Markdown
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentResponseHandler")

struct AgentResponseHandler {

    /// Parses the raw Data from the backend into a primary response string.
    /// This handles backend-specific JSON structures to extract the main text content.
    /// - Parameters:
    ///   - data: The raw data from the HTTP response.
    ///   - backendType: The type of backend the response is from.
    /// - Returns: The primary response string.
    /// - Throws: An error if parsing fails.
    func parseInitialResponse(data: Data, for backendType: BackendType) throws -> String {
        do {
            switch backendType {
            case .agent:
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let resultsArray = json["results"] as? [[String: Any]] else {
                    logger.warning("Agent response was not the expected JSON structure.")
                    let rawResponse = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Error: Could not decode non-JSON Agent response."
                    throw NSError(domain: "AgentResponseHandler", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Agent response format error: \(rawResponse)"])
                }

                if let completed = resultsArray.first(where: { ($0["status"] as? String) == "completed" }),
                   let result = completed["result"] as? String {
                    logger.debug("Parsed completed agent result.")
                    return result.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if !resultsArray.isEmpty && resultsArray.allSatisfy({ ($0["status"] as? String) != "completed" }) {
                    let firstError = resultsArray.first?["result"] as? String ?? "Unknown agent error"
                    logger.warning("All agents failed. First error: \(firstError)")
                    throw NSError(domain: "AgentResponseHandler", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Agent Error: \(firstError)"])
                } else if resultsArray.isEmpty {
                     logger.warning("Agent returned empty results array.")
                     throw NSError(domain: "AgentResponseHandler", code: 1003, userInfo: [NSLocalizedDescriptionKey: "Error: Received empty results array from agent."])
                } else {
                     logger.warning("No agent completed successfully in results: \(resultsArray)")
                     throw NSError(domain: "AgentResponseHandler", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Error: No agent completed the task successfully."])
                }

            case .ollama:
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let reply = json["response"] as? String else {
                    logger.warning("Ollama response was not JSON or missing 'response' key.")
                    if let rawResponse = String(data: data, encoding: .utf8) { logger.debug("Ollama raw response: \(rawResponse)") }
                    let rawResponseForError = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Error: Could not decode non-JSON Ollama response."
                    throw NSError(domain: "AgentResponseHandler", code: 1005, userInfo: [NSLocalizedDescriptionKey: "Ollama response format error: \(rawResponseForError)"])
                }
                logger.debug("Parsed Ollama response.")
                return reply.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch let NSERR as NSError { // Re-throw our custom errors
            throw NSERR
        } catch { // Catch other JSONSerialization errors
            logger.error("Failed to parse JSON response: \(error.localizedDescription)")
            if let rawResponse = String(data: data, encoding: .utf8) { logger.error("Raw data that failed to parse: \(rawResponse)") }
            throw NSError(domain: "AgentResponseHandler", code: 1000, userInfo: [NSLocalizedDescriptionKey: "Error: Could not decode server response (\(error.localizedDescription))."])
        }
    }

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
             if var lastContent = contentBlocks.last, case .markdownText(let existingText) = lastContent {
                 contentBlocks[contentBlocks.count - 1] = .markdownText(existingText + "\n\n" + markdownContent)
             } else {
                 contentBlocks.append(.markdownText(markdownContent))
             }
         } else {
             logger.trace("Skipping empty formatted block of type '\(type(of: block))'.")
         }
     }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ReActMarkdownParser.swift
//  Devgentic
//
//  Step 3.3: Parser for the .reactMarkdown dialect.
//  Target: Classic ReAct format (Thought / Action / Action Input).
//
//  Expected format:
//    Thought: I need to list the directory
//    Action: list_directory
//    Action Input: {"path": "/"}
//
//  Created by Raj Singh on 06/03/26.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "ReActMarkdownParser")

struct ReActMarkdownParser: CognitiveParserProtocol {

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let text = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Extract Thought / reasoning (text after "Thought:" up to "Action:")
        let reasoning = extractThought(from: text)

        // 2. Extract Action (tool name)
        let terminators = ["none", "finish", "null", "done"]
        
        guard let rawToolName = extractField(named: "Action", from: text)?.trimmingCharacters(in: .init(charactersIn: "`\"'")),
              !rawToolName.isEmpty,
              !terminators.contains(rawToolName.lowercased().trimmingCharacters(in: .punctuationCharacters)) else {
            // "Final Answer:", no action found, or termination word used — treat as termination
            logger.info("ReActMarkdownParser: No valid Action found. Treating as termination.")
            let finalAnswer = extractFinalAnswer(from: text)
            return ModernCognitiveStep(
                reasoning: finalAnswer ?? reasoning ?? text,
                toolCalls: []
            )
        }

        // 3. Extract Action Input (JSON arguments)
        let arguments = extractActionInput(from: text)

        logger.info("ReActMarkdownParser: Parsed action='\(rawToolName)' with \(arguments.count) argument(s).")
        let call = PendingToolCall(id: UUID().uuidString, name: rawToolName, arguments: arguments)
        // Filter template-stub narration ("Calling X…") out of the with-tools reasoning so it
        // doesn't pollute the working-memory scratchpad (#15 / G7). A nil/stub Thought becomes
        // "" — empty reasoning is correct (the UI renders "Executing <tool>…" from the tool
        // event). The termination path above is deliberately NOT filtered (it's the final answer).
        return ModernCognitiveStep(reasoning: ReasoningQualityFilter.filter(reasoning), toolCalls: [call])
    }

    // MARK: - Field Extractors

    private func extractThought(from text: String) -> String? {
        let pattern = #"(?:Thought|Reasoning):\s*(.*?)(?=\nAction:|\nFinal Answer:|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractField(named fieldName: String, from text: String) -> String? {
        // Matches "Action: tool_name" — stops at newline
        let pattern = "\(fieldName):\\s*([^\\n]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractActionInput(from text: String) -> [String: JSONValue] {
        // Find the index of "Action Input:"
        guard let afterInputRange = text.range(of: "Action Input:", options: .caseInsensitive) else {
            logger.warning("ReActMarkdownParser: Could not locate 'Action Input:'. Using empty args.")
            return [:]
        }
        
        var remainder = String(text[afterInputRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. Markdown Sanitization
        if remainder.contains("```json") {
            remainder = remainder.components(separatedBy: "```json").last ?? remainder
        }
        if remainder.contains("```") {
            remainder = remainder.components(separatedBy: "```").first ?? remainder
        }
        remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 2. Extract outermost JSON object to ignore trailing conversational text
        guard let jsonString = extractOutermostJSON(from: remainder),
              let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            logger.warning("ReActMarkdownParser: Could not decode Action Input JSON. Using empty args.")
            return [:]
        }
        
        return decoded
    }

    private func extractFinalAnswer(from text: String) -> String? {
        let pattern = #"Final Answer:\s*([\s\S]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - JSON Extraction Helper

    /// Extracts the outermost balanced JSON object, honoring JSON string/escape rules (#15).
    private func extractOutermostJSON(from text: String) -> String? {
        BalancedJSONScanner.firstObject(in: text).map(String.init)
    }
}

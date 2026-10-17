// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
        
        guard let rawToolName = Self.extractField(named: "Action", from: text)?.trimmingCharacters(in: .init(charactersIn: "`\"'")),
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
        // ⚠️⚠️ CR-19: an Action Input that is PRESENT but undecodable used to become `[:]` and the
        // call still went out — `final_answer` then failed as "missing answer" (`argSchemaMismatch`),
        // which neither told the model what was wrong nor let the answer-vs-call verdict rescue it.
        // It is now a typed malformed-JSON failure, after the shared repairs (raw newlines, invalid
        // escapes, trailing commas) had their chance.
        guard let arguments = extractActionInput(from: text) else {
            logger.warning("ReActMarkdownParser: Action Input for '\(rawToolName)' is not valid JSON even after repair. CONSEQUENCE: a malformed-JSON failure — the model is told its arguments were invalid and retries; no call with empty arguments is sent.")
            return ModernCognitiveStep(
                reasoning: reasoning ?? text,
                toolCalls: [],
                parseOutcome: .failed(.malformedJSON(
                    syntaxDetail: "the Action Input for '\(rawToolName)' is not valid JSON",
                    rawSnippet: String(text.prefix(300))))
            )
        }

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

    /// The value of a `Field:` line, e.g. `Action: tool_name`, up to the end of that line.
    ///
    /// ⚠️ READINESS CR-54 (2026-10-12). This matched `Action:` ANYWHERE, case-insensitively, so
    /// prose like "the last transaction: history shows…" produced a call to a tool named
    /// `history`. The field must now START a line, after at most the markdown a model wraps it in
    /// (indentation, a bullet, a quote, `**`/`__`), and the emphasis closing it (`**Action:**`) is
    /// skipped.
    static func extractField(named fieldName: String, from text: String) -> String? {
        let pattern = "(?m)^[ \\t]*(?:[-*>#]+[ \\t]*)?(?:\\*\\*|__)?\(NSRegularExpression.escapedPattern(for: fieldName)):(?:\\*\\*|__)?[ \\t]*([^\\n]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The arguments; `[:]` when there are none (no `Action Input:` at all — zero-argument tools);
    /// nil when an Action Input is present but is not a JSON object even after repair.
    private func extractActionInput(from text: String) -> [String: JSONValue]? {
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
        guard let jsonString = extractOutermostJSON(from: remainder) else {
            // Nothing object-shaped follows: `Action Input: {}` / blank — a zero-argument call.
            return remainder.isEmpty || remainder == "{}" ? [:] : nil
        }
        return JSONStructuralSanitizer.decodeObject(jsonString)
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

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OutputSanitizer.swift
//  Devgentic
//
//  Stage 0 of the Dialect-Anchored Cascade.
//  Strips common LLM output artifacts that confuse downstream parsers.
//  Runs unconditionally on every response before any dialect-specific parser.
//
//  Created by Raj Singh on 10/03/26.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "OutputSanitizer")

/// Structured result from the OutputSanitizer.
struct SanitizedOutput: Sendable {
    let cleaned: String
    let thought: String?
}

/// Stateless pre-processor that removes known artifact patterns from raw LLM output.
/// Never throws — always returns a cleaned string (possibly empty).
struct OutputSanitizer: Sendable {

    /// Sanitizes raw LLM output by removing known artifact patterns.
    /// - Parameter raw: The unmodified text returned by the model.
    /// - Returns: A structure containing cleaned text and extracted thoughts.
    static func sanitize(_ raw: String) -> SanitizedOutput {
        var text = raw

        // 1. Extract and Strip <think>...</think> blocks (Chain-of-Thought traps).
        //    Models like DeepSeek-R1 wrap internal reasoning in <think> tags.
        let (strippedText, extractedThought) = extractAndStripThinkBlocks(text)
        text = strippedText

        // 2. Strip leading BOM / multi-byte artifacts.
        text = stripLeadingArtifacts(text)

        // 3. Strip markdown code fences (```json ... ```, ```xml ... ```, bare ```).
        text = stripCodeFences(text)

        // 4. Strip special token markers (<|eot_id|>, <|end_of_text|>, <|im_end|>, etc.).
        //    These are tokenizer control tokens that leak into generated text
        //    when stop sequences aren't configured or the model over-generates.
        text = stripSpecialTokenMarkers(text)

        // 5. Strip wrapper tags (<output>...</output>, <response>...</response>).
        //    Some models wrap their entire response in these tags.
        text = stripWrapperTags(text)

        // 6. Deduplicate repeated top-level JSON blocks.
        //    Small models sometimes emit the same JSON response twice in a single generation.
        //    Keeps only the first block to prevent downstream parse confusion.
        text = deduplicateRepeatedBlocks(text)

        // 7. Strip trailing orphan XML close tags that aren't part of a matched pair.
        text = stripTrailingOrphanTags(text)

        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.count != raw.trimmingCharacters(in: .whitespacesAndNewlines).count {
            logger.debug("OutputSanitizer: Cleaned \(raw.count - result.count) chars of artifacts.")
        }

        return SanitizedOutput(cleaned: result, thought: extractedThought)
    }

    // MARK: - Public Scoped Helpers

    /// Strips `<think>` blocks and special token markers from user-facing text.
    /// Safe for post-synthesis output — does NOT strip code fences or wrapper tags
    /// which could destroy legitimate markdown in the response.
    static func stripThinkBlocksAndTokens(_ text: String) -> String {
        let (stripped, _) = extractAndStripThinkBlocks(text)
        let cleaned = stripSpecialTokenMarkers(stripped)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sanitizes model reasoning/thought text for display in the UI thought process.
    ///
    /// Small models frequently regurgitate prompt scaffold XML tags (episodic memory,
    /// working memory, negative constraints, etc.) in their reasoning output. These
    /// internal infrastructure tags should never be shown to the user.
    ///
    /// Strips: `<episodic_memory>`, `<working_memory>`, `<negative_constraints>`,
    /// `<recent>`, `<turn>`, `<action>`, `<user_correction>`, `<params>`,
    /// plus their closing tags and self-closing variants. Also strips orphan
    /// markdown code fences (e.g. bare ` ```json `) — reasoning is short inline
    /// text that rarely contains legitimate code blocks, and qwen-coder-style
    /// models frequently leak an opener fence when emitting native tool calls.
    static func sanitizeForUI(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text

        // Strip prompt scaffold XML tags (opening, closing, and self-closing)
        let scaffoldTags = [
            // Core prompt scaffold
            "task", "clarification", "query", "response",
            "system_instructions", "environment", "semantic_context",
            "execution_contract", "available_tools", "available_skills",
            "user_profile", "negative_constraints", "hallucinated_tools",
            "working_memory", "input", "current_objective",
            // Episodic memory scaffold
            "episodic_memory", "recent", "turn", "action",
            "user_correction", "params",
            // Legacy tags (backward compat)
            "system_rules", "tools_available", "objective"
        ]
        let pattern = "</?(?:" + scaffoldTags.joined(separator: "|") + ")(?:\\s[^>]*)?\\/?>|<(?:" + scaffoldTags.joined(separator: "|") + ")\\s*/>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Also strip special token markers that may appear in thoughts
        result = stripSpecialTokenMarkers(result)

        // Strip orphan markdown code fences — native-tool-calling models like
        // qwen-coder often leak an opener (```json) when their trained format
        // wraps tool calls in fences but the structured tool_calls are extracted
        // out by the provider, leaving just the fence marker in reasoning text.
        result = stripCodeFences(result)

        // Collapse multiple blank lines into one
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private Helpers

    /// Extracts content from `<think>` tags and returns the stripped text plus the joined thoughts.
    private static func extractAndStripThinkBlocks(_ text: String) -> (String, String?) {
        guard let regex = try? NSRegularExpression(
            pattern: #"<think>([\s\S]*?)</think>"#,
            options: .caseInsensitive
        ) else { return (text, nil) }
        
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        
        var extractedThoughts: [String] = []
        for match in matches {
            if let thoughtRange = Range(match.range(at: 1), in: text) {
                extractedThoughts.append(String(text[thoughtRange]))
            }
        }
        
        let stripped = regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: ""
        )
        
        let finalThought = extractedThoughts.isEmpty ? nil : extractedThoughts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripped, finalThought)
    }

    /// Drops leading non-ASCII, non-whitespace characters from the very start of the string.
    private static func stripLeadingArtifacts(_ text: String) -> String {
        var index = text.startIndex
        while index < text.endIndex {
            let scalar = text.unicodeScalars[index]
            if (scalar.value >= 0x20 && scalar.value < 0x7F)
                || scalar == "\n" || scalar == "\r" || scalar == "\t" {
                break
            }
            index = text.index(after: index)
        }
        return index == text.startIndex ? text : String(text[index...])
    }

    /// Removes markdown code fences.
    private static func stripCodeFences(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(
            pattern: #"```(?:json|xml|yaml|swift|python)?\s*\n?"#,
            options: .caseInsensitive
        ) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        result = result.replacingOccurrences(of: "```", with: "")
        return result
    }

    /// Strips special token markers like `<|eot_id|>`, `<|end_of_text|>`, `<|im_end|>`, etc.
    /// These are tokenizer control tokens that sometimes leak into generated text.
    private static func stripSpecialTokenMarkers(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<\|[a-z_]+\|>"#,
            options: .caseInsensitive
        ) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }

    /// Strips opening and closing wrapper tags that some models use to enclose their response.
    /// Removes `<output>...</output>` and `<response>...</response>` wrappers while preserving inner content.
    private static func stripWrapperTags(_ text: String) -> String {
        var result = text
        let tags = ["output", "response"]
        for tag in tags {
            guard let regex = try? NSRegularExpression(
                pattern: "</?\(tag)>",
                options: .caseInsensitive
            ) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return result
    }

    /// Detects and removes duplicate top-level JSON blocks from the response.
    /// Small models sometimes repeat the entire JSON object. This keeps only the first.
    /// Uses brace-depth tracking to find the end of the first complete `{...}` block,
    /// then checks if the remainder (after trimming whitespace) starts another `{`.
    private static func deduplicateRepeatedBlocks(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return text }

        var depth = 0
        var inString = false
        var prevChar: Character = "\0"
        var firstBlockEnd: String.Index?

        for (index, char) in zip(trimmed.indices, trimmed) {
            if char == "\"" && prevChar != "\\" {
                inString.toggle()
            }
            if !inString {
                if char == "{" { depth += 1 }
                else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        firstBlockEnd = index
                        break
                    }
                }
            }
            prevChar = char
        }

        guard let endIndex = firstBlockEnd else { return text }

        let afterFirst = trimmed[trimmed.index(after: endIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard afterFirst.hasPrefix("{") else { return text }

        // There's a second JSON block — keep only the first
        let firstBlock = String(trimmed[...endIndex])
        logger.debug("OutputSanitizer: Stripped duplicate JSON block (\(afterFirst.count) chars removed).")
        return firstBlock
    }

    /// Strips common orphan close tags at the very end of the string.
    private static func stripTrailingOrphanTags(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\s*</(?:s|tool_call|tools|tool|output|response|function_call)>\s*$"#,
            options: .caseInsensitive
        ) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }
}

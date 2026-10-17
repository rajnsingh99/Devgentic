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

    /// Special tokens that OPEN a tool call and that a parser or drift probe reads, kept by
    /// `sanitize(_:preservingCallMarkers:)` when the caller is about to parse for calls.
    ///
    /// ⚠️ Stripping `<|python_tag|>` before the cascade made `PythonicTagProbe` unable to ever
    /// fire and hid the call from every check that decides whether to look for one: a valid
    /// Llama 3.1 call after a paragraph of prose was shown to the user as the answer on 6
    /// dialects (2026-10-05 probe). Only tokens something downstream READS belong here — the
    /// other call tokens (`<|tool_call|>`, `<|START_ACTION|>`) are still stripped, so their
    /// parsers must recover the payload WITHOUT them, and `AttemptedToolCallGrammar` reads them
    /// from the unsanitized text. ⚠️ That was not true for `<|START_ACTION|>` until CR-50: the
    /// Command-R7B parser required its marker and silently lost every call's arguments.
    static let parsedCallMarkerTokens: Set<String> = ["<|python_tag|>"]

    /// Sanitizes raw LLM output by removing known artifact patterns.
    /// - Parameters:
    ///   - raw: The unmodified text returned by the model.
    ///   - preservingCallMarkers: keep `parsedCallMarkerTokens` (the parse cascade sets this).
    ///   - keepingCodeFences: skip step 3. For the text SHOWN as a final answer only — parsers
    ///     must keep reading fence-free text (see `CognitiveParsePipeline.restoringCodeFences`).
    /// - Returns: A structure containing cleaned text and extracted thoughts.
    static func sanitize(_ raw: String, preservingCallMarkers: Bool = false, keepingCodeFences: Bool = false) -> SanitizedOutput {
        var text = raw

        // 1. Extract and Strip <think>...</think> blocks (Chain-of-Thought traps).
        //    Models like DeepSeek-R1 wrap internal reasoning in <think> tags.
        let (strippedText, extractedThought) = extractAndStripThinkBlocks(text)
        text = strippedText

        // 2. Strip leading BOM / multi-byte artifacts.
        text = stripLeadingArtifacts(text)

        // 3. Strip markdown code fences (```json ... ```, ```xml ... ```, bare ```).
        if !keepingCodeFences {
            text = stripCodeFences(text)
        }

        // 4. Strip special token markers (<|eot_id|>, <|end_of_text|>, <|im_end|>, etc.).
        //    These are tokenizer control tokens that leak into generated text
        //    when stop sequences aren't configured or the model over-generates.
        text = stripSpecialTokenMarkers(text, keeping: preservingCallMarkers ? parsedCallMarkerTokens : [])

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

    /// `text` without its `<think>…</think>` blocks and nothing else removed — fences, special
    /// tokens and tags survive. What `AttemptedToolCallGrammar` reads: a call the model only
    /// CONSIDERED while thinking is not an attempt, but the tokens `sanitize` strips are evidence.
    static func stripThinkBlocks(_ text: String) -> String {
        extractAndStripThinkBlocks(text).0
    }

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

    /// Drops INVISIBLE and GARBAGE scalars from the very start of the string — and nothing else.
    ///
    /// ⚠️⚠️ NOT "everything outside printable ASCII" (readiness CR-5, 2026-10-10). That was the rule,
    /// and it deleted the opening of every reply that did not start in English: "Привет мир" became
    /// " мир", "Übersicht" became "bersicht", "✅ Done" lost its emoji — and an all-CJK reply became "",
    /// which the cascade reports as `.emptyOutput` and answers with a corrective retry, every time.
    /// What a leading artifact actually IS: a BOM or other format character (`Cf`: U+FEFF, zero-width
    /// space/joiners, word joiner), a control character other than tab/newline (`Cc`, e.g. NUL), or the
    /// U+FFFD replacement character a broken decode leaves behind. Letters, digits, punctuation and
    /// emoji in ANY script are text.
    private static func stripLeadingArtifacts(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex, isLeadingArtifact(scalars[index]) {
            index = scalars.index(after: index)
        }
        return index == scalars.startIndex ? text : String(scalars[index...])
    }

    private static func isLeadingArtifact(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\r" || scalar == "\t" { return false }
        if scalar == "\u{FFFD}" { return true }
        switch scalar.properties.generalCategory {
        case .format, .control: return true
        default: return false
        }
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
    private static func stripSpecialTokenMarkers(_ text: String, keeping kept: Set<String> = []) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<\|[a-z_]+\|>"#,
            options: .caseInsensitive
        ) else { return text }
        guard !kept.isEmpty else {
            return regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }
        let nsText = text as NSString
        var result = text
        // Back to front, so earlier ranges stay valid as later tokens are removed.
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed()
        where !kept.contains(nsText.substring(with: match.range)) {
            if let range = Range(match.range, in: result) { result.removeSubrange(range) }
        }
        return result
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

    /// Removes a top-level JSON block that REPEATS the one before it, byte for byte.
    ///
    /// Small models sometimes emit the same object twice in one generation; this keeps one copy.
    ///
    /// ⚠️ READINESS CR-53 (2026-10-12). It used to keep only the FIRST block whenever a second
    /// `{` followed it, identical or not, and logged at debug only. Two DIFFERENT consecutive calls
    /// (`{"name":"read_file",…}` then `{"name":"list_dir",…}`, the shape several JSON dialects
    /// emit for a parallel batch) lost every call after the first, silently. Only an exact repeat
    /// is dropped now, and that is logged. The scan is string-aware (`BalancedJSONScanner`); the old
    /// previous-character test misread a string ending in an escaped backslash (`"C:\\"`).
    static func deduplicateRepeatedBlocks(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return text }

        // The run of top-level blocks at the start, separated only by whitespace.
        var blocks: [Substring] = []
        var cursor = trimmed.startIndex
        while cursor < trimmed.endIndex {
            guard let next = trimmed[cursor...].firstIndex(where: { !$0.isWhitespace }) else { cursor = trimmed.endIndex; break }
            guard trimmed[next] == "{",
                  let range = BalancedJSONScanner.balancedRange(in: trimmed, from: next, opener: "{"),
                  range.lowerBound == next else { cursor = next; break }
            blocks.append(trimmed[range])
            cursor = range.upperBound
        }
        guard blocks.count > 1 else { return text }

        var kept: [Substring] = []
        var dropped = 0
        for block in blocks {
            if let last = kept.last, last == block { dropped += 1 } else { kept.append(block) }
        }
        guard dropped > 0 else { return text }

        logger.notice("[SANITIZE] Dropped \(dropped) JSON block(s) that exactly repeated the block before them (\(kept.count) distinct kept). CONSEQUENCE: a repeated call runs once; distinct consecutive blocks are all kept.")
        let remainder = trimmed[cursor...]
        return kept.joined(separator: "\n") + remainder
    }

    /// Strips a common close tag at the very end of the string — only when it is an ORPHAN.
    ///
    /// ⚠️ It used to strip any trailing match, so the `</tool_call>` CLOSING a well-formed
    /// `<tool_call>…</tool_call>` at the end of a reply was removed too. Everything downstream then
    /// saw an unclosed call: `StandardXMLProbe` (needs both tags) found no drift, and Mistral XML's
    /// own parser could not match its own wrapper — a valid call after a paragraph of prose was
    /// shown to the user as the answer on 6 dialects (2026-10-05 probe). `</s>` is an end-of-
    /// sequence token, never half of a pair, so it is always stripped.
    private static func stripTrailingOrphanTags(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\s*</(s|tool_call|tools|tool|output|response|function_call)>\s*$"#,
            options: .caseInsensitive
        ) else { return text }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else {
            return text
        }
        let tag = nsText.substring(with: match.range(at: 1)).lowercased()
        if tag != "s" {
            let lowered = text.lowercased()
            let openers = lowered.components(separatedBy: "<\(tag)>").count - 1
                + lowered.components(separatedBy: "<\(tag) ").count - 1
            let closers = lowered.components(separatedBy: "</\(tag)>").count - 1
            if openers >= closers { return text }  // the trailing tag closes a real pair
        }
        return nsText.replacingCharacters(in: match.range, with: "")
    }
}

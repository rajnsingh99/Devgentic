// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AttemptedToolCallGrammar.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The single definition of "this text is an attempted tool call", shared wherever an unparsed reply is judged a broken
/// call (retry) or an answer. It reads declared keys and tokens of tool-call formats, never the shape of the text.
enum AttemptedToolCallGrammar {

    /// A label for the attempted call in `text` (the tool name, else the opening format token), or nil when it is not a call.
    /// A call names a callable tool as a name key, tag or Pythonic list; pairs a name key with an arguments object; or opens
    /// with a known format token (`callMarkers`) or a ReAct Action/Action Input pair. Inline code spans are ignored.
    static func attemptedCallName(in text: String, callableNames: Set<String>) -> String? {
        let text = inlineCodePattern.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " ")
        guard !text.isEmpty else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        // Rule 1 — a registered name, in a name key, as a tag, or opening a Pythonic list.
        if !callableNames.isEmpty {
            let byLowercased = Dictionary(
                callableNames.map { ($0.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for pattern in [registeredNamePattern, tagPattern, pythonicListPattern] {
                for match in pattern.matches(in: text, range: range) {
                    let value = nsText.substring(with: match.range(at: 1)).lowercased()
                    if let name = byLowercased[value] { return name }
                }
            }
        }

        // Rule 2 — call shape: name key + object-valued arguments key.
        if argumentsObjectPattern.firstMatch(in: text, range: range) != nil,
           let match = callNamePattern.firstMatch(in: text, range: range) {
            return nsText.substring(with: match.range(at: 1))
        }

        // Rule 3 — a format's call-opening token.
        if let marker = callMarkers.first(where: { text.contains($0.token) }) {
            return marker.token
        }
        if reactActionPattern.firstMatch(in: text, range: range) != nil,
           reactActionInputPattern.firstMatch(in: text, range: range) != nil {
            return "Action:"
        }
        return nil
    }

    /// Tokens that OPEN a tool call in a known format. Each is declared by that format's
    /// chat template and read by the parser named beside it (or by `FormatDriftDetector`).
    /// A reply that produced no call yet contains one of these attempted a call that did
    /// not decode. Literal tokens only — never a shape.
    static let callMarkers: [(token: String, format: String)] = [
        ("<|python_tag|>", "Llama 3.1 — PythonicTagParser, Llama3JsonParser"),
        ("<|python_start|>", "Llama 4 pythonic — PythonicListParser"),
        ("<tool_call>", "Hermes / Qwen / Granite 4 / Mistral XML / Qwen3-Coder"),
        ("<tool_call ", "Mistral XML attribute form — MistralXMLParser"),
        ("<|tool_call|>", "Granite 3 — GraniteLegacyParser"),
        ("<tool_calls>", "YAML-in-XML (Jamba, MiniMax) — YAMLInXMLParser"),
        ("<tools>", "generic wrapper — GenericToolsXMLParser"),
        ("<tool>", "generic wrapper — GenericToolsXMLParser"),
        ("[TOOL_CALLS]", "Mistral v3 / v11 — MistralV3Parser, MistralV11Parser"),
        ("<function=", "Qwen3-Coder / deep XML — Qwen3CoderDeepXMLParser, DeepXMLParser"),
        ("<Functions#", "Devstral — BracketHashParser"),
        ("<functioncall>", "functioncall fine-tunes — FormatDriftDetector"),
        ("<<function>>", "Gorilla — FormatDriftDetector"),
        ("functools[", "Phi — PhiFunctoolsParser"),
        ("<\u{FF5C}tool\u{2581}calls\u{2581}begin\u{FF5C}>", "DeepSeek V3 — DeepSeekV3Parser"),
        ("<\u{FF5C}tool\u{2581}call\u{2581}begin\u{FF5C}>", "DeepSeek V3 / V3.1 — DeepSeekV3Parser, DeepSeekV31Parser"),
        ("<\u{FF5C}DSML\u{FF5C}function_calls>", "DeepSeek V3.2 — DeepSeekV32Parser"),
        ("<|START_ACTION|>", "Command-R7B — CommandR7BActionParser"),
        ("```tool_code", "Gemma tool_code fence"),
    ]

    /// `` `code` `` on one line. Never matches a ``` fence: a backtick right after a backtick fails
    /// `[^`\n]`, so fence markers and fenced blocks are left alone.
    private static let inlineCodePattern = regex(#"`[^`\n]+`"#)

    private static let registeredNamePattern = regex(
        #""(?:name|tool_name|tool|function|function_name|func|action|command)"\s*:\s*"([^"\\]{1,128})""#)

    /// `<read_file>` — the dynamic-tool-tag format, where the tag IS the tool name.
    /// Matched against `callableNames` only, so `<span>` or `<div>` never count.
    private static let tagPattern = regex(#"<([A-Za-z_][A-Za-z0-9_.\-]{0,127})>"#)

    /// `[read_file(` — the Pythonic list format (`PythonicListParser`) opens with a call.
    /// Matched against `callableNames` only, so `prices[maxProfit(` style code never counts
    /// unless it names a tool of this run right after the bracket.
    private static let pythonicListPattern = regex(#"\[\s*([A-Za-z_][A-Za-z0-9_.\-]{0,127})\s*\("#)

    private static let callNamePattern = regex(
        #""(?:name|tool_name|tool|function|function_name|func|action)"\s*:\s*"([A-Za-z_][A-Za-z0-9_.\-]{0,127})""#)

    private static let argumentsObjectPattern = regex(
        #""(?:arguments|parameters|args|input|action_input)"\s*:\s*\{"#)

    /// ReAct markdown declares a call as BOTH lines; `Action:` alone is ordinary prose.
    private static let reactActionPattern = regex(#"(?m)^\s*Action:\s*\S"#)
    private static let reactActionInputPattern = regex(#"(?m)^\s*Action Input:"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}

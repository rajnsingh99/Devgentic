// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AttemptedToolCallGrammar.swift
//  Devgentic
//
//  ONE definition of "this text is an attempted tool call", shared by every place
//  that must decide whether an unparsed reply is a broken call (retry it) or an
//  answer (end the run with it):
//
//    - NativeParsePipeline   — zero native tool calls, content cascade said `.failed`
//    - CognitiveParsePipeline — Stage 4 recovered nothing on a prompt-based dialect
//    - ReActAgentExecutor    — the consecutive-format-failure bound's salvage check
//
//  ⚠️ Declared grammar, not shape. Braces, brackets, `int[]`, `prices[i]`, Markdown
//  links and ```json analysis blocks decide NOTHING — judging by shape is what sent
//  correct answers into retry loops on 12 of 18 dialects (2026-10-05 probe matrix).
//  What DOES decide: keys and tokens a tool-call format declares.
//
//  ⚠️ JSON keys alone are not enough. The first version knew only rules 1 and 2, and
//  calls written in a tag/token format — `<<function>>read_file(`, `<functioncall>…`,
//  a cut-off `<function=read_file>…`, `[TOOL_CALLS]read_file[ARGS]{…` — were shown to
//  the user as the answer on up to 19 of 19 paths (2026-10-05 audit). Rule 3 exists
//  for those.
//

import Foundation

enum AttemptedToolCallGrammar {

    /// A label for the attempted call in `text` — the tool name when the text declares
    /// one, else the format token that opened it — or nil when `text` is not a call.
    ///
    /// A call is declared by ANY of:
    ///   1. one of `callableNames` (case-insensitive) as the value of a name key
    ///      (`name`, `tool_name`, `tool`, `function`, `function_name`, `func`, `action`,
    ///      `command`), as a tag (`<read_file>`), or opening a Pythonic call list
    ///      (`[read_file(`) — catches truncated calls to real tools, e.g.
    ///      `{"name":"read_file","arguments":{"path":`;
    ///   2. a name key (`name`, `tool_name`, `tool`, `function`, `function_name`, `func`,
    ///      `action`) with an identifier value AND an arguments key (`arguments`,
    ///      `parameters`, `args`, `input`, `action_input`) whose value opens an object —
    ///      the shape of a call whatever the tool name, e.g.
    ///      `{"function_name": "final_summary", "arguments": {…}}`;
    ///   3. a token that opens a call in a known tool-call format (`callMarkers`), or a
    ///      ReAct `Action:` line followed by an `Action Input:` line.
    ///
    /// `{"name": "Raj"}`, `{"input": 5}`, `{"analysis": {"input": [7,1,5]}}`,
    /// `<span>{count}</span>` and a lone `Action: none needed.` line are not calls.
    ///
    /// Text inside an INLINE code span is ignored: that is how prose quotes a token ("Hermes wraps
    /// calls in `<tool_call>` tags"), and a model's real call is never wrapped in single backticks.
    /// Fenced blocks are still read — models do put real calls in ```json fences.
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

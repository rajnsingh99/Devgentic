// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  PythonicListParser.swift
//  Devgentic
//
//  Phase 4 — Native-tool dialect expansion (2026-04-22).
//  Primary parser for the `.pythonicBracketList` dialect.
//
//  Covers:
//    - meta-llama/Llama-3.2-1B-Instruct (and 3B)  — pythonic-mode trained
//    - meta-llama/Llama-4-Scout-17B / Maverick-17B — pythonic mode
//    - Salesforce/Llama-xLAM-2-8b-fc-r (and 70B)
//    - Team-ACE/ToolACE-8B / ToolACE-2-Llama-3.1-8B
//
//  Canonical output (Python-expression syntax, NOT JSON):
//
//    [list_directory(path="/tmp"), write_file(path="/tmp/a.txt", content="hi", append=False)]
//
//  This parser parses Python-literal call syntax WITHOUT exec/eval — it's a small
//  hand-rolled tokenizer + recursive-descent parser covering the 90% case:
//    - Top-level bracket list with comma-separated calls
//    - Each call: `name(kwarg=value, kwarg=value, ...)`
//    - Values: strings ("..." / '...'), numbers, bools (True/False), None,
//      nested lists [...], nested dicts {k:v}, nested calls (rare — not supported)
//    - Escape sequences inside strings (\", \\, \n, \t, \uXXXX)
//
//  Fallbacks:
//    - Missing outer `[...]` — accept a single bare `name(args)` call
//    - Python literals normalized to JSON before argument extraction
//

import Foundation
import OSLog

private let logger = DGLogger(category: "PythonicListParser")

struct PythonicListParser: CognitiveParserProtocol {

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let trimmed = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        let (reasoning, body) = splitReasoningAndCallBody(from: trimmed)

        let calls = extractCalls(from: body)

        if !calls.isEmpty {
            logger.info("PythonicListParser: Extracted \(calls.count) tool call(s): \(calls.map { $0.name }.joined(separator: ", "))")
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: calls)
        }

        logger.warning("PythonicListParser: No pythonic function calls found. Treating as conversational exit.")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }

    // MARK: - Reasoning / Body Split

    /// Separates any prose preceding the first `[` or `name(` pattern from the
    /// call body itself. Handles both wrapped `[...]` and bare `name(args)` cases.
    private func splitReasoningAndCallBody(from text: String) -> (reasoning: String, body: String) {
        // Strip common pythonic wrappers if present.
        var body = text
        if body.contains("<|python_start|>"), let r = body.range(of: "<|python_start|>") {
            body = String(body[r.upperBound...])
        }
        if let r = body.range(of: "<|python_end|>") {
            body = String(body[..<r.lowerBound])
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)

        // Body should start with `[` or `identifier(` — find that position.
        if let openBracket = body.firstIndex(of: "["), isValidPythonicStart(body, from: openBracket) {
            let reasoning = String(body[..<openBracket]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (ReasoningQualityFilter.filter(reasoning), String(body[openBracket...]))
        }
        if let callStart = firstIdentifierCallStart(in: body) {
            let reasoning = String(body[..<callStart]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (ReasoningQualityFilter.filter(reasoning), String(body[callStart...]))
        }
        return (text, body)
    }

    /// Quick sanity check: the `[` is followed soon by `identifier(` (not `1,2,3`).
    private func isValidPythonicStart(_ text: String, from openBracket: String.Index) -> Bool {
        let tail = text[text.index(after: openBracket)...]
            .drop(while: { $0.isWhitespace })
        guard let firstChar = tail.first else { return false }
        return firstChar.isLetter || firstChar == "_"
    }

    /// Finds the first position where a Python identifier is immediately followed by `(`.
    private func firstIdentifierCallStart(in text: String) -> String.Index? {
        let pattern = #"[A-Za-z_][A-Za-z0-9_]*\s*\("#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            return range.lowerBound
        }
        return nil
    }

    // MARK: - Call List Extraction

    /// Extracts all `name(args)` calls from a body that may be wrapped in `[...]`
    /// or be a bare single call.
    private func extractCalls(from body: String) -> [PendingToolCall] {
        var text = body
        // Strip outer brackets if present.
        if text.hasPrefix("[") {
            // Find balanced matching `]` and drop them.
            if let closeIdx = balancedBracketEnd(in: text, openBracket: text.startIndex) {
                text = String(text[text.index(after: text.startIndex)..<closeIdx])
            }
        }

        // Split top-level by `,` (respecting parens, brackets, braces, strings).
        let segments = splitTopLevel(text, separator: ",", bracketPairs: [("(", ")"), ("[", "]"), ("{", "}")])
        var results: [PendingToolCall] = []
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let call = parseSingleCall(trimmed) {
                results.append(call)
            }
        }
        return results
    }

    /// Parses a single `name(kwarg=value, ...)` expression into a tool call.
    private func parseSingleCall(_ text: String) -> PendingToolCall? {
        // Find `name` + opening `(`.
        guard let openParen = text.firstIndex(of: "(") else {
            logger.warning("PythonicListParser: Segment has no '(': \(text.prefix(100))")
            return nil
        }
        let name = String(text[..<openParen]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidIdentifier(name) else {
            logger.warning("PythonicListParser: Invalid identifier '\(name.prefix(50))'.")
            return nil
        }

        // Extract arg body between `(` and matching `)`.
        guard let closeParen = balancedParenEnd(in: text, openParen: openParen) else {
            logger.warning("PythonicListParser: Unbalanced parens for '\(name)'.")
            return nil
        }
        let argBody = String(text[text.index(after: openParen)..<closeParen])

        // Parse kwargs.
        let arguments = parseKwargs(argBody)
        return PendingToolCall(id: UUID().uuidString, name: name, arguments: arguments)
    }

    private func parseKwargs(_ body: String) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        let parts = splitTopLevel(body, separator: ",", bracketPairs: [("(", ")"), ("[", "]"), ("{", "}")])
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Split on first `=` not inside string/bracket.
            guard let eqIdx = firstTopLevelEquals(in: trimmed) else {
                logger.debug("PythonicListParser: Positional arg (no '=') skipped: \(trimmed.prefix(50))")
                continue
            }
            let key = String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let valueText = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = parseValue(valueText) {
                result[key] = value
            } else {
                // Fallback: store as string.
                result[key] = .string(valueText)
            }
        }
        return result
    }

    // MARK: - Value parsing

    /// Parses a Python-literal value into a JSONValue. Handles strings, numbers,
    /// booleans, None, lists, and dicts. Falls back to string if unparseable.
    private func parseValue(_ raw: String) -> JSONValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Normalize Python literals → JSON.
        if trimmed == "True" { return .bool(true) }
        if trimmed == "False" { return .bool(false) }
        if trimmed == "None" || trimmed == "null" { return .null }

        // String literal.
        if let s = parseStringLiteral(trimmed) {
            return .string(s)
        }

        // Number — JSONValue unifies ints + doubles into `.number(Double)`.
        if let d = Double(trimmed) {
            return .number(d)
        }

        // JSON-convertible nested structure (list or dict).
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            return parseNestedStructureAsJSON(trimmed)
        }

        // Unknown — return as string.
        return .string(trimmed)
    }

    /// Parses a Python string literal with `"..."` or `'...'` quoting.
    /// Handles basic escape sequences (\n, \t, \", \', \\, \uXXXX).
    private func parseStringLiteral(_ raw: String) -> String? {
        guard raw.count >= 2 else { return nil }
        let first = raw.first!
        let last = raw.last!
        guard (first == "\"" || first == "'") && first == last else { return nil }

        var result = ""
        var idx = raw.index(after: raw.startIndex)
        let endIdx = raw.index(before: raw.endIndex)
        while idx < endIdx {
            let c = raw[idx]
            if c == "\\" {
                let next = raw.index(after: idx)
                guard next < endIdx else { return nil }
                let escape = raw[next]
                switch escape {
                case "n":  result.append("\n")
                case "t":  result.append("\t")
                case "r":  result.append("\r")
                case "\"": result.append("\"")
                case "'":  result.append("'")
                case "\\": result.append("\\")
                case "0":  result.append("\0")
                case "u":
                    // \uXXXX
                    let hexStart = raw.index(after: next)
                    guard raw.distance(from: hexStart, to: endIdx) >= 4 else { return nil }
                    let hexEnd = raw.index(hexStart, offsetBy: 4)
                    let hex = raw[hexStart..<hexEnd]
                    if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                        result.append(Character(scalar))
                    }
                    idx = hexEnd
                    continue
                default:
                    result.append(escape)
                }
                idx = raw.index(after: next)
            } else {
                result.append(c)
                idx = raw.index(after: idx)
            }
        }
        return result
    }

    /// Converts a Python list/dict literal to JSON by normalizing literals + quotes,
    /// then decodes. Handles the common case; rare edge cases fall back to string.
    private func parseNestedStructureAsJSON(_ raw: String) -> JSONValue? {
        // ORDER IS LOAD-BEARING. Quote conversion must come FIRST: until it runs, this
        // literal's strings are SINGLE-quoted, so a double-quote-aware sanitizer would see
        // the whole payload as structure and rewrite `None` inside a string value — e.g. an
        // argument carrying Python source, `content='if x is None: pass'`. Converting first
        // means the literal pass can tell a token from a string. (Literals are bare tokens,
        // so quote conversion is unaffected by running before them.)
        var s = convertSingleQuotedStrings(raw)
        // Python literals → JSON, plus trailing commas: `[1, 2,]` is valid Python, not JSON.
        s = JSONStructuralSanitizer.repairingStructure(s)

        if let data = s.data(using: .utf8),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return value
        }
        logger.debug("PythonicListParser: Nested structure failed JSON decode: \(raw.prefix(100))")
        return nil
    }

    /// Best-effort conversion of Python single-quoted strings to double-quoted JSON strings.
    /// Preserves already-double-quoted strings; does not handle apostrophes inside strings.
    private func convertSingleQuotedStrings(_ input: String) -> String {
        // Replace `'...'` with `"..."` but only outside of existing `"..."` regions.
        var result = ""
        var insideDouble = false
        var escaped = false
        for c in input {
            if escaped {
                result.append(c); escaped = false; continue
            }
            if c == "\\" { result.append(c); escaped = true; continue }
            if c == "\"" { insideDouble.toggle(); result.append(c); continue }
            if c == "'" && !insideDouble {
                result.append("\"")
                continue
            }
            result.append(c)
        }
        return result
    }

    // MARK: - Low-level scanning helpers

    private func isValidIdentifier(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        guard first.isLetter || first == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
    }

    /// Splits `text` by `separator` at depth 0 relative to all `bracketPairs`, respecting
    /// string state (so separators inside strings/brackets are ignored).
    private func splitTopLevel(_ text: String, separator: Character, bracketPairs: [(Character, Character)]) -> [String] {
        var segments: [String] = []
        var current = ""
        var depth = 0
        var inString: Character? = nil
        var escaped = false
        let openers = Set(bracketPairs.map { $0.0 })
        let closers = Set(bracketPairs.map { $0.1 })

        for c in text {
            if escaped {
                current.append(c); escaped = false; continue
            }
            if c == "\\" && inString != nil {
                current.append(c); escaped = true; continue
            }
            if let q = inString {
                if c == q { inString = nil }
                current.append(c)
                continue
            }
            if c == "\"" || c == "'" {
                inString = c; current.append(c); continue
            }
            if openers.contains(c) { depth += 1; current.append(c); continue }
            if closers.contains(c) { depth -= 1; current.append(c); continue }
            if c == separator && depth == 0 {
                segments.append(current)
                current = ""
                continue
            }
            current.append(c)
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(current)
        }
        return segments
    }

    /// Finds the first top-level `=` (not `==`, not inside strings/brackets).
    private func firstTopLevelEquals(in text: String) -> String.Index? {
        var depth = 0
        var inString: Character? = nil
        var escaped = false
        var prev: Character? = nil
        for idx in text.indices {
            let c = text[idx]
            defer { prev = c }
            if escaped { escaped = false; continue }
            if c == "\\" && inString != nil { escaped = true; continue }
            if let q = inString {
                if c == q { inString = nil }
                continue
            }
            if c == "\"" || c == "'" { inString = c; continue }
            if c == "(" || c == "[" || c == "{" { depth += 1; continue }
            if c == ")" || c == "]" || c == "}" { depth -= 1; continue }
            if c == "=" && depth == 0 {
                // Avoid `==`.
                if prev == "=" { continue }
                let next = text.index(after: idx)
                if next < text.endIndex, text[next] == "=" { continue }
                return idx
            }
        }
        return nil
    }

    private func balancedParenEnd(in text: String, openParen: String.Index) -> String.Index? {
        return balancedDelimEnd(in: text, openAt: openParen, open: "(", close: ")")
    }

    private func balancedBracketEnd(in text: String, openBracket: String.Index) -> String.Index? {
        return balancedDelimEnd(in: text, openAt: openBracket, open: "[", close: "]")
    }

    private func balancedDelimEnd(in text: String, openAt: String.Index, open: Character, close: Character) -> String.Index? {
        guard text[openAt] == open else { return nil }
        var depth = 0
        var inString: Character? = nil
        var escaped = false
        for idx in text[openAt...].indices {
            let c = text[idx]
            if escaped { escaped = false; continue }
            if c == "\\" && inString != nil { escaped = true; continue }
            if let q = inString {
                if c == q { inString = nil }
                continue
            }
            if c == "\"" || c == "'" { inString = c; continue }
            if c == open { depth += 1 }
            else if c == close {
                depth -= 1
                if depth == 0 { return idx }
            }
        }
        return nil
    }
}

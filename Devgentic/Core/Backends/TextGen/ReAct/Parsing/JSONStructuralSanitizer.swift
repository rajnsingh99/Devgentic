// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  JSONStructuralSanitizer.swift
//  Devgentic
//
//  Repairs the structural defects local models put in their JSON — trailing commas, unquoted
//  keys, Python literals — WITHOUT touching the data inside string values.
//
//  That distinction is the whole point of this file. Every parser used to run these regexes
//  over the entire payload, which cannot tell a JSON token from a byte of a source file the
//  model is trying to write. The `arguments.content` of a `write_file` call is just a string
//  value in that payload, so:
//
//    • `\bNaN\b → null`  turned Java's `Double.NaN` into `Double.null`
//    • `\bNULL\b → null` turned C's `if (p == NULL)` into `if (p == null)`
//    • `,\s*([}\]])`     deleted the legitimate trailing comma from an array initializer
//    • the unquoted-key regex rewrote a bare `default:` line into `"default":`
//
//  All of it silent: the payload stayed valid JSON, nothing errored, and the corrupted bytes
//  went to disk and then back into the model's next prompt. Same class as the
//  `normalizePathArguments` bug (see `Docs/` and the path-normalization notes): a transform
//  applied to a payload it cannot distinguish structure from content in.
//
//  The fix is to walk the string once, tracking quote state, and apply the repairs ONLY to
//  the spans between string values.
//

import Foundation

private let logger = DGLogger(category: "JSONStructuralSanitizer")

enum JSONStructuralSanitizer {

    // MARK: - The walker

    /// Applies `transform` to each maximal run of `json` that lies OUTSIDE a double-quoted
    /// string, copying every string value through byte-for-byte.
    ///
    /// Equivalent to the old whole-payload regexes for well-formed JSON — the lookbehind
    /// characters the key regex needs (`{`, `[`, `,`, newline) are all structural, so they
    /// always land in the same span as the token that follows them.
    ///
    /// Escape-aware, so a `\"` inside a string does not end it. Raw (unescaped) newlines
    /// inside a string are fine here: only `"` opens or closes a span, which is why this can
    /// run BEFORE the pass that escapes them.
    ///
    /// FAIL-SAFE: if the payload has an unbalanced quote — a model emitting
    /// `"content": "he said "hi""` — the walker ends inside a string and the trailing span is
    /// left unrepaired. That degrades to "we didn't fix your JSON", never to "we rewrote your
    /// file". The old behaviour on the same input was to corrupt it.
    static func rewritingOutsideStrings(_ json: String, _ transform: (String) -> String) -> String {
        var out = ""
        out.reserveCapacity(json.count + 16)
        var span = ""
        var inString = false
        var justSawEscape = false

        for char in json {
            if inString {
                out.append(char)
                if justSawEscape {
                    justSawEscape = false
                } else if char == "\\" {
                    justSawEscape = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }
            if char == "\"" {
                out += transform(span)
                span.removeAll(keepingCapacity: true)
                out.append(char)
                inString = true
                continue
            }
            span.append(char)
        }
        out += transform(span)

        if inString {
            logger.warning("""
            ⚠️ [JSONSanitizer] Unbalanced quote — the payload ended inside a string value. \
            Structural repairs were SKIPPED for the trailing span; if this payload also had a \
            trailing comma or a Python literal, decoding will fail rather than be repaired. \
            Not corrupting the string contents is the deliberate trade.
            """)
        }
        return out
    }

    // MARK: - Repairs

    /// Trailing commas, Python literals, and (optionally) unquoted keys — applied to structure
    /// only, in one pass.
    ///
    /// `quotingUnquotedKeys` is opt-in because only `HeuristicCognitiveParser` ever did it;
    /// the dialect parsers have always been trailing-comma + literals, and widening them here
    /// would be a behaviour change smuggled in under a bug fix.
    static func repairingStructure(_ json: String, quotingUnquotedKeys: Bool = false) -> String {
        let repaired = rewritingOutsideStrings(keepingInvalidEscapesLiteral(escapingRawControlCharacters(json))) { span in
            guard !span.isEmpty else { return span }
            var s = span
            if quotingUnquotedKeys { s = replacingMatches(in: s, unquotedKey, with: " \"$1\":") }
            s = replacingMatches(in: s, trailingComma, with: "$1")
            for (regex, replacement) in pythonLiterals {
                s = replacingMatches(in: s, regex, with: replacement)
            }
            return s
        }

        if repaired != json {
            logger.debug("🔧 [JSONSanitizer] Repaired structural defects (\(json.count) → \(repaired.count) chars); string values untouched.")
        }
        return repaired
    }

    /// Escapes RAW control characters (a literal newline, tab, carriage return…) inside string values.
    ///
    /// ⚠️ CR-19 (2026-10-10): a model writing a multi-line `final_answer` in a ReAct `Action Input`
    /// puts real line breaks inside the string — invalid JSON, so the call decoded to `[:]` and failed
    /// as "missing answer". Like `keepingInvalidEscapesLiteral`, this never changes a byte the model
    /// meant: a valid document has no raw control characters inside strings, so it is returned
    /// unchanged; an invalid one did not decode at all before.
    static func escapingRawControlCharacters(_ json: String) -> String {
        var out = ""
        out.reserveCapacity(json.count + 8)
        var inString = false
        var escaped = false
        var repairs = 0
        for scalar in json.unicodeScalars {
            if inString {
                if escaped { escaped = false; out.unicodeScalars.append(scalar); continue }
                if scalar == "\\" { escaped = true; out.unicodeScalars.append(scalar); continue }
                if scalar == "\"" { inString = false; out.unicodeScalars.append(scalar); continue }
                if scalar.value < 0x20 {
                    repairs += 1
                    switch scalar {
                    case "\n": out += "\\n"
                    case "\r": out += "\\r"
                    case "\t": out += "\\t"
                    default: out += String(format: "\\u%04x", scalar.value)
                    }
                    continue
                }
                out.unicodeScalars.append(scalar)
            } else {
                if scalar == "\"" { inString = true }
                out.unicodeScalars.append(scalar)
            }
        }
        if repairs > 0 {
            logger.info("🔧 [JSONSanitizer] Escaped \(repairs) raw control character(s) inside string values (e.g. a literal newline in a multi-line answer). CONSEQUENCE: the payload can decode, with every character the model wrote.")
        }
        return out
    }

    /// A JSON OBJECT decoded strictly, else after the structural repairs above; nil only when even the
    /// repaired text is not an object. One definition, so every parser repairs the same way.
    static func decodeObject(_ json: String) -> [String: JSONValue]? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8), let strict = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            return strict
        }
        let repaired = repairingStructure(trimmed)
        guard let data = repaired.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    /// Doubles the backslash of every escape JSON does not define, so `\'` decodes as the two
    /// characters the model wrote instead of failing the whole call.
    ///
    /// The one repair here that reaches INTO string values, and it is safe for the same reason
    /// the walker is: it never changes a byte the model meant. A valid document has no invalid
    /// escapes, so it is returned unchanged; an invalid one did not decode at all before. Keeping
    /// the backslash, rather than dropping it, is deliberate: `\'` is an apostrophe in prose
    /// but a real backslash in `'\''` (shell) or `print('don\'t')` (Python source), and a call
    /// that writes a file must not lose one silently. Prose pays with a visible backslash.
    ///
    /// On the 2026-10-06 device run Qwen2.5-3B answered T3 correctly as
    /// `{"answer": "…Devgentic\'s local models.\n\nCodename: BLUEFIN-42"}`; the `\'` failed the
    /// decode, the two retries repeated it, and the run ended on a wrong answer.
    ///
    /// `\u` counts as valid only with four hex digits after it: `"C:\users"` is a Windows path,
    /// not a broken escape.
    static func keepingInvalidEscapesLiteral(_ json: String) -> String {
        let chars = Array(json)
        var out = ""
        out.reserveCapacity(chars.count + 8)
        var inString = false
        var repairs = 0
        var index = 0
        while index < chars.count {
            let char = chars[index]
            guard inString else {
                if char == "\"" { inString = true }
                out.append(char)
                index += 1
                continue
            }
            if char == "\"" {
                inString = false
                out.append(char)
                index += 1
                continue
            }
            guard char == "\\" else {
                out.append(char)
                index += 1
                continue
            }
            let next = index + 1 < chars.count ? chars[index + 1] : nil
            if let next, isValidEscape(next, hexAfter: chars[min(index + 2, chars.count)...]) {
                out.append(char)
                out.append(next)
                index += 2
            } else {
                out += "\\\\"
                repairs += 1
                index += 1
            }
        }
        if repairs > 0 {
            logger.info("🔧 [JSONSanitizer] Kept \(repairs) invalid escape(s) as literal backslashes (e.g. \\' from Python-style quoting). CONSEQUENCE: the payload can decode; each value keeps every character the model wrote, backslash included.")
        }
        return out
    }

    private static func isValidEscape(_ char: Character, hexAfter rest: ArraySlice<Character>) -> Bool {
        switch char {
        case "\"", "\\", "/", "b", "f", "n", "r", "t":
            return true
        case "u":
            return rest.prefix(4).count == 4 && rest.prefix(4).allSatisfy(\.isHexDigit)
        default:
            return false
        }
    }

    // MARK: - Patterns

    // Compiled once. These ran through `try?` on every single parse before, discarding the
    // compile cost silently each time.

    /// Trailing comma before a closer: `{"k": 1,}` → `{"k": 1}`.
    private static let trailingComma = regex(#",\s*([}\]])"#)

    /// JavaScript-style unquoted key: `{key: "v"}` → `{"key": "v"}`. Only in key position
    /// (a bare identifier followed by `:`), anchored to a structural character.
    private static let unquotedKey = regex(#"(?<=[\{\[,\n])\s*([a-zA-Z_]\w*)\s*:"#)

    /// Python/SQL literals in TOKEN position. Order matters: longest first.
    private static let pythonLiterals: [(NSRegularExpression?, String)] = [
        (regex(#"\bFalse\b"#), "false"),   // Python bool
        (regex(#"\bTrue\b"#),  "true"),    // Python bool
        (regex(#"\bNone\b"#),  "null"),    // Python null
        (regex(#"\bNULL\b"#),  "null"),    // Uppercase null (MySQL / C-style leak)
        (regex(#"\bNaN\b"#),   "null"),    // Python float NaN → safest as null
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            // Static patterns — this can only fire if one is edited into invalid syntax.
            logger.error("❌ [JSONSanitizer] Failed to compile '\(pattern)': \(error.localizedDescription). That repair is now DISABLED; payloads with this defect will fail to decode.")
            return nil
        }
    }

    private static func replacingMatches(in s: String, _ regex: NSRegularExpression?, with template: String) -> String {
        guard let regex else { return s }
        return regex.stringByReplacingMatches(
            in: s,
            range: NSRange(s.startIndex..., in: s),
            withTemplate: template
        )
    }
}

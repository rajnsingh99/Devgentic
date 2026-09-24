// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BalancedJSONScanner.swift
//  Devgentic
//
//  Single, correct implementation of "find the first balanced {…} / […] block in a
//  string" (audit #15, sub-issue 5). Previously this was hand-rolled in ~12 parsers and
//  OllamaLLMProvider, with two genuinely buggy variants:
//    - `prevChar != "\\"` escape checks (Ollama / ReActMarkdown) mishandle `\\"` — an
//      escaped backslash followed by a real closing quote — and stay "inside the string".
//    - inline scans with NO string-state (MistralXML) break on a `{`/`[` that lives inside
//      a JSON string value.
//  This scanner honors JSON string + escape rules so delimiters inside strings never count.
//

import Foundation

enum BalancedJSONScanner {

    /// Range of the first balanced group of `opener` (`{` or `[`) at/after `start`.
    /// Honors JSON strings and escapes, so braces/brackets inside `"…"` are ignored.
    /// Returns `nil` if no opener is found or the group never balances.
    static func balancedRange(
        in text: String,
        from start: String.Index? = nil,
        opener: Character
    ) -> Range<String.Index>? {
        let close: Character = (opener == "{") ? "}" : "]"
        let searchFrom = start ?? text.startIndex
        guard searchFrom <= text.endIndex,
              let openIdx = text[searchFrom...].firstIndex(of: opener) else { return nil }

        var depth = 0
        var inString = false
        var escaped = false

        for idx in text[openIdx...].indices {
            let c = text[idx]
            if escaped { escaped = false; continue }
            if c == "\\" && inString { escaped = true; continue }
            if c == "\"" { inString.toggle(); continue }
            if inString { continue }
            if c == opener {
                depth += 1
            } else if c == close {
                depth -= 1
                if depth == 0 { return openIdx..<text.index(after: idx) }
            }
        }
        return nil
    }

    /// First balanced object `{…}` as a substring (string/escape-aware).
    static func firstObject(in text: String, from start: String.Index? = nil) -> Substring? {
        balancedRange(in: text, from: start, opener: "{").map { text[$0] }
    }

    /// First balanced array `[…]` as a substring (string/escape-aware).
    static func firstArray(in text: String, from start: String.Index? = nil) -> Substring? {
        balancedRange(in: text, from: start, opener: "[").map { text[$0] }
    }

    /// Splits `text` into `(prose, block, tail)` where `block` is the first balanced `{…}` OR
    /// `[…]` that is ALSO shaped like a leaked tool call, `prose` is everything before it, and
    /// `tail` is everything after. `block` is `nil` when nothing qualifies, in which case the
    /// whole text is returned as `prose`. Substrings are untrimmed — the caller trims/strips.
    ///
    /// ⚠️⚠️ TWO DEFECTS FIXED HERE 2026-09-20, both of which destroyed model output.
    ///
    /// 1. `tail` did not exist. This returned `(before, block)` and the caller had nowhere to put
    ///    the rest, so EVERYTHING AFTER THE BLOCK WAS SILENTLY DISCARDED. The test that covered
    ///    this fed `prose here {"k":1} tail` and asserted nothing about `" tail"`.
    ///
    /// 2. Balance alone decided what a block was. Balanced brackets are not evidence of JSON:
    ///    `[truncated]`, `[the docs]`, `[a-z]`, `[INFO]` are all balanced, and all ordinary prose.
    ///
    /// Together they produced silent content loss on any Ollama response carrying a bracketed
    /// token and no native tool calls. Measured against the real splitter:
    ///
    ///     "…output was [truncated] so I could not…"        →  35B of 80B dropped
    ///     "See [the docs](https://example.com) for…"       →  55B of 68B dropped  (81%)
    ///     "…the approach in [1] which uses…"               →  33B of 64B dropped
    ///     "Use the pattern [a-z]+ to match…"               →  41B of 61B dropped
    ///     "The log line [INFO] startup complete…"          →  47B of 65B dropped
    ///
    /// Field-observed: a 474-byte answer reached the parser as the 11-byte string "[truncated]".
    ///
    /// ⚠️ This is the FIFTH member of the content-corruption class in this codebase — a transform
    /// rewriting a payload because it matched a SHAPE. The other four were fixed by keying off the
    /// argument NAME; there is no name here, so the shape test is made strict enough to mean
    /// something instead.
    static func splitProseAndBlock(in text: String) -> (prose: Substring, block: Substring?, tail: Substring) {
        let whole = text[...]
        let empty = text[text.endIndex...]

        var searchFrom = text.startIndex
        // Keep looking: a genuine leaked tool call can sit AFTER a bracketed word in the prose,
        // so rejecting the first candidate must not abandon the search.
        while let openIdx = text[searchFrom...].firstIndex(where: { $0 == "{" || $0 == "[" }) {
            guard let range = balancedRange(in: text, from: openIdx, opener: text[openIdx]) else {
                return (whole, nil, empty)
            }
            if isToolCallShaped(text[range]) {
                return (text[..<range.lowerBound], text[range], text[range.upperBound...])
            }
            // Not JSON — step past this opener and keep scanning.
            searchFrom = text.index(after: openIdx)
        }
        return (whole, nil, empty)
    }

    /// True when `candidate` is JSON that could carry a tool call: an object, or an array of
    /// objects.
    ///
    /// ⚠️ "Parses as JSON" alone is NOT sufficient, and that is the whole subtlety. `[1]` — a
    /// citation marker in ordinary prose — is perfectly valid JSON. So is `[1,2]`. A leaked tool
    /// call is always an object (`{"name":…}`) or an array of them, never an array of scalars, so
    /// the element type is what separates the two.
    ///
    /// ⚠️ `.fragmentsAllowed` is deliberately NOT passed: with it, a bare `"word"` or number would
    /// qualify and the check would be nearly as weak as balance alone.
    static func isToolCallShaped(_ candidate: Substring) -> Bool {
        guard let data = String(candidate).data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return false }
        if parsed is [String: Any] { return true }
        if let array = parsed as? [Any] { return !array.isEmpty && array.allSatisfy { $0 is [String: Any] } }
        return false
    }
}

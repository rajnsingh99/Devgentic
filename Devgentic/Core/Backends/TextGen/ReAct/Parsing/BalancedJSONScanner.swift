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

    /// Splits `text` into `(prose, block)` where `block` is the first balanced `{…}` OR `[…]`
    /// (whichever opener appears first) and `prose` is everything before it. `block` is `nil`
    /// when no balanced block exists. Mirrors `OllamaLLMProvider.splitProseAndJSON`'s contract
    /// minus its escape bug. Both substrings are returned untrimmed — the caller trims/strips.
    static func splitProseAndBlock(in text: String) -> (prose: Substring, block: Substring?) {
        guard let firstOpenIdx = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return (text[...], nil)
        }
        guard let range = balancedRange(in: text, from: firstOpenIdx, opener: text[firstOpenIdx]) else {
            return (text[...], nil)
        }
        return (text[..<range.lowerBound], text[range])
    }
}

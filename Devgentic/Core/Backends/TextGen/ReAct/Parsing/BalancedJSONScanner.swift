// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BalancedJSONScanner.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Finds the first balanced `{…}` / `[…]` block in a string, honoring JSON string and escape rules
/// so delimiters inside strings never count.
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

    // Why: balance alone is not evidence of JSON: `[truncated]`, `[INFO]` and `[1]` are balanced prose, and treating them as
    // a block silently drops the surrounding model output
    /// Splits `text` into `(prose, block, tail)`: `block` is the first balanced `{…}` or `[…]` that is also shaped like a
    /// leaked tool call, `prose` everything before it and `tail` everything after (both untrimmed). `block` is nil when
    /// nothing qualifies, and the whole text is returned as `prose`.
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

    // Why: parsing as JSON is not enough (`[1]` parses): a leaked call is an object or array of objects, and
    // `.fragmentsAllowed` stays off so a bare word or number does not qualify
    /// True when `candidate` is JSON that could carry a tool call: an object, or an array of objects.
    static func isToolCallShaped(_ candidate: Substring) -> Bool {
        guard let data = String(candidate).data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return false }
        if parsed is [String: Any] { return true }
        if let array = parsed as? [Any] { return !array.isEmpty && array.allSatisfy { $0 is [String: Any] } }
        return false
    }
}

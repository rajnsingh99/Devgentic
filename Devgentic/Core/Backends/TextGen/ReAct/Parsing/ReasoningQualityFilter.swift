// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ReasoningQualityFilter.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Filters parser-extracted reasoning text. Returns the trimmed input when it
/// carries signal, or `""` when it's empty, whitespace-only, or matches a
/// well-known template-stub pattern.
///
/// Conservative by design: only filters short single-line text matching narration
/// templates. Multi-sentence prose and any text exceeding the length gate passes
/// through untouched, so a real reasoning sentence that happens to start with
/// "Calling X to..." is preserved. As small models improve and start producing
/// genuine reasoning in their content slots, those will pass straight through —
/// no tier check, no allow-list to maintain.
enum ReasoningQualityFilter {

    /// Length above which the text is assumed to be real reasoning regardless of
    /// what it starts with. Picked so a typical narration stub ("Executing tool
    /// some_long_tool_name_here...") fits, while two-sentence reasoning does not.
    private static let stubLengthCap = 80

    /// Compiled stub regexes — case-insensitive, anchored, allow optional ellipsis.
    /// Pattern guidelines:
    ///   - Anchor with `^` and `$` so the regex matches the WHOLE line, not a
    ///     prefix. A reasoning sentence that begins with "Calling X" but
    ///     continues with "...because the user asked Y" must NOT match.
    ///   - Allow trailing 0-3 dots to cover the common ellipsis variants.
    ///   - Match a tool-name-shaped token (`\S+`) as the object of the verb.
    private static let stubPatterns: [NSRegularExpression] = {
        let raws = [
            #"^executing tool[s]?(\s+\S+)?\s*\.{0,3}$"#,
            #"^calling tool[s]?(\s+\S+)?\s*\.{0,3}$"#,
            #"^calling\s+\S+\s*\.{0,3}$"#,
            #"^running\s+\S+\s*\.{0,3}$"#,
            #"^invoking\s+\S+\s*\.{0,3}$"#,
            #"^using\s+\S+\s*\.{0,3}$"#,
            #"^now (calling|invoking|using|running)\s+\S+\s*\.{0,3}$"#,
            #"^(let me|i will|i'll|i need to)\s+(call|use|invoke|run)\s+\S+\s*\.{0,3}$"#,
        ]
        return raws.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    /// Returns the trimmed text if it carries signal, or `""` otherwise.
    ///
    /// - Empty / whitespace-only → `""`
    /// - Multi-line → passes through (real reasoning is almost always multi-line)
    /// - Longer than `stubLengthCap` chars → passes through (defends against
    ///   filtering a real explanation that happens to start with a stub verb)
    /// - Matches a stub pattern → `""`
    /// - Otherwise → trimmed input
    static func filter(_ raw: String?) -> String {
        guard let raw = raw else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Multi-line text is almost always real reasoning — don't filter it.
        if trimmed.contains("\n") { return trimmed }

        // Long text is almost always real reasoning — the length gate defends
        // against filtering a real explanation that happens to start with a
        // stub-shaped verb phrase like "Calling X to do Y because Z…".
        if trimmed.count > stubLengthCap { return trimmed }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for regex in stubPatterns {
            if regex.firstMatch(in: trimmed, range: range) != nil {
                return ""
            }
        }
        return trimmed
    }
}

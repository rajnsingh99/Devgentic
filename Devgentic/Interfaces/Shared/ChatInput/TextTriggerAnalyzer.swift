// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TextTriggerAnalyzer.swift
//  Devgentic
//
//  Created by Raj Singh on 05/02/26.
//

import Foundation

class TextTriggerAnalyzer {
    
    /// ⚠️ `CaseIterable` so `ComposerSuggestionKeyRoutingTests` can assert that every trigger type
    /// has a keyboard-routing parameter. Adding a case here without adding one to
    /// `ComposerSuggestionKeyRouting.anyPickerIsOpen` yields a picker the keyboard cannot reach —
    /// which is exactly how `/` shipped deaf.
    enum TriggerType: CaseIterable {
        case prompt // #
        case file   // @
        case skill  // /
    }
    
    struct Result {
        let type: TriggerType
        let range: NSRange
        let query: String
    }
    
    /// Analyzes the text backwards from the cursor location to find a valid trigger.
    /// - Parameters:
    ///   - text: The full text content.
    ///   - cursorLocation: The current cursor index (NSRange location).
    /// - Returns: A `Result` containing the trigger type, range, and query if found; otherwise `nil`.
    static func analyze(text: String, cursorLocation: Int) -> Result? {
        // 1. Use NSString for robust UTF-16 indexing (matches NSRange)
        let nsText = text as NSString
        let length = nsText.length

        // 2. Guard bounds in UTF-16 space.
        //
        // `cursorLocation` is an NSRange location (UTF-16 offset), so it must be compared
        // against `nsText.length` — NOT `text.count`, which counts grapheme clusters. A
        // single emoji before the cursor makes the UTF-16 offset exceed the Character
        // count, the guard failed, and `@`/`#` suggestions silently stopped working for
        // the rest of the message. (`length` was already being computed here and thrown
        // away — the compiler warned it was unused.)
        guard cursorLocation > 0, cursorLocation <= length else { return nil }

        // Optimization: Don't scan back more than N characters (queries shouldn't be huge)
        let maxScanDepth = 120
        let startIndex = max(0, cursorLocation - maxScanDepth)
        
        var i = cursorLocation - 1
        
        // 3. Scan backwards
        while i >= startIndex {
            let charCode = nsText.character(at: i)
            // A surrogate half belongs to an astral character (emoji, rare CJK). It is
            // neither a trigger nor a word breaker, so keep scanning past it —
            // `UnicodeScalar(_:)` returns nil for surrogates, and bailing out here aborted
            // the scan whenever an emoji sat inside the query ("@fi👍le").
            guard let scalar = UnicodeScalar(charCode) else {
                i -= 1
                continue
            }
            
            // A. Check for Triggers
            if scalar == "#" || scalar == "@" || scalar == "/" {
                // ⚠️ `/` HAS A STRICTER BOUNDARY THAN `#` AND `@`, and it must keep it.
                //
                // Those two allow "start of line OR preceded by whitespace", which is right for
                // them: `@file` and `#prompt` read as mentions mid-sentence. The same rule applied
                // to `/` fires on ordinary prose and paths — `cd /usr`, `and/or`, `24/7`,
                // `TODO: fix /etc/hosts` — popping a skill picker over someone's sentence.
                //
                // A slash command is the WHOLE message's intent, not a mention inside it, so it is
                // only a trigger at offset 0 of the entire text. That is also what Claude Code does,
                // and it makes the rule explainable in one line: it has to be the first thing typed.
                let isStart = (i == 0)
                var isPrecededByValid = isStart

                if !isStart && scalar != "/" {
                    let prevChar = nsText.character(at: i - 1)
                    if let prevScalar = UnicodeScalar(prevChar),
                       (Character(prevScalar).isWhitespace || Character(prevScalar).isNewline) {
                        isPrecededByValid = true
                    }
                }

                if isPrecededByValid {
                    let type: TriggerType
                    switch scalar {
                    case "#": type = .prompt
                    case "@": type = .file
                    default:  type = .skill
                    }
                    
                    // Range covers the symbol (#/@) up to the cursor
                    let matchLength = cursorLocation - i
                    let range = NSRange(location: i, length: matchLength)
                    
                    // Query is the text *after* the symbol
                    let queryRange = NSRange(location: i + 1, length: matchLength - 1)
                    let query = nsText.substring(with: queryRange)
                    
                    return Result(type: type, range: range, query: query)
                } else {
                    // We found a symbol (e.g. 'email@domain'), but it's not a valid trigger.
                    // Since triggers cannot be inside words, we stop scanning.
                    return nil
                }
            }
            
            // B. Check for Breakers (Whitespace/Newline)
            // If we hit a space before hitting a symbol, it's not a valid "typing" trigger.
            if Character(scalar).isWhitespace || Character(scalar).isNewline {
                return nil
            }
            
            i -= 1
        }
        
        return nil
    }
}

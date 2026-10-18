// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TextTriggerAnalyzer.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

class TextTriggerAnalyzer {
    
    // Why: a case missing from `ComposerSuggestionKeyRouting.anyPickerIsOpen` yields a picker the keyboard cannot reach
    /// `CaseIterable` so tests can assert every trigger type has a keyboard-routing parameter.
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
    
    /// Scans backwards from the cursor for a valid trigger.
    /// text is the full content; cursorLocation is an NSRange location.
    /// Returns the trigger type, range and query, or nil if none.
    static func analyze(text: String, cursorLocation: Int) -> Result? {
        // 1. Use NSString for robust UTF-16 indexing (matches NSRange)
        let nsText = text as NSString
        let length = nsText.length

        // Why: grapheme counts drift past UTF-16 offsets after an emoji and silently disable `@`/`#` suggestions
        // Bounds are checked in UTF-16 space against `nsText.length`, not `text.count`.
        guard cursorLocation > 0, cursorLocation <= length else { return nil }

        // Optimization: Don't scan back more than N characters (queries shouldn't be huge)
        let maxScanDepth = 120
        let startIndex = max(0, cursorLocation - maxScanDepth)
        
        var i = cursorLocation - 1
        
        // 3. Scan backwards
        while i >= startIndex {
            let charCode = nsText.character(at: i)
            // A surrogate half belongs to an astral character; it is neither a trigger nor a word breaker, so keep scanning.
            guard let scalar = UnicodeScalar(charCode) else {
                i -= 1
                continue
            }
            
            // A. Check for Triggers
            if scalar == "#" || scalar == "@" || scalar == "/" {
                // Why: the looser rule fires on prose and paths (`cd /usr`, `and/or`, `24/7`) and pops a picker over a sentence
                // `/` is a trigger only at offset 0 of the whole text, unlike `#` and `@`, which also accept a preceding space.
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

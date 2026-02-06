//
//  TextTriggerAnalyzer.swift
//  Devgentic
//
//  Created by Raj Singh on 05/02/26.
//

import Foundation

class TextTriggerAnalyzer {
    
    enum TriggerType {
        case prompt // #
        case file   // @
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
        // 1. Guard bounds
        guard cursorLocation > 0, cursorLocation <= text.count else { return nil }
        
        // 2. Use NSString for robust UTF-16 indexing (matches NSRange)
        let nsText = text as NSString
        let length = nsText.length
        
        // Optimization: Don't scan back more than N characters (queries shouldn't be huge)
        let maxScanDepth = 120
        let startIndex = max(0, cursorLocation - maxScanDepth)
        
        var i = cursorLocation - 1
        
        // 3. Scan backwards
        while i >= startIndex {
            let charCode = nsText.character(at: i)
            guard let scalar = UnicodeScalar(charCode) else { return nil }
            
            // A. Check for Triggers
            if scalar == "#" || scalar == "@" {
                // Boundary Check: Must be start of line or preceded by whitespace
                let isStart = (i == 0)
                var isPrecededByValid = isStart
                
                if !isStart {
                    let prevChar = nsText.character(at: i - 1)
                    if let prevScalar = UnicodeScalar(prevChar),
                       (Character(prevScalar).isWhitespace || Character(prevScalar).isNewline) {
                        isPrecededByValid = true
                    }
                }
                
                if isPrecededByValid {
                    let type: TriggerType = (scalar == "#") ? .prompt : .file
                    
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

//
//  DiffUtility.swift
//  Devgentic
//
//  Created by Raj Singh on 08/08/25.
//
//  ENHANCED: Now calculates line numbers for professional diff display.

import Foundation

/// Describes the type of change for a single line in a diff result.
enum LineChangeType {
    case added
    case deleted
    case unchanged
}

/// Represents a single line in a diff comparison result, conforming to Identifiable and Hashable for SwiftUI.
struct DiffResult: Identifiable, Hashable {
    let id = UUID()
    let line: String
    let type: LineChangeType
    let originalLineNumber: Int?
    let modifiedLineNumber: Int?
}

/// A utility for generating a line-by-line diff between two strings.
struct DiffUtility {

    /// Generates a diff between an original and a modified string.
    /// This implementation uses a standard Longest Common Subsequence (LCS) based algorithm
    /// to efficiently determine the differences between the two inputs.
    static func generateDiff(original: String, modified: String) -> [DiffResult] {
        let originalLines = original.components(separatedBy: .newlines)
        let modifiedLines = modified.components(separatedBy: .newlines)

        // Create a table to store the lengths of the longest common subsequences.
        var lcsTable = Array(repeating: Array(repeating: 0, count: modifiedLines.count + 1), count: originalLines.count + 1)

        for i in 1...originalLines.count {
            for j in 1...modifiedLines.count {
                if originalLines[i-1] == modifiedLines[j-1] {
                    lcsTable[i][j] = lcsTable[i-1][j-1] + 1
                } else {
                    lcsTable[i][j] = max(lcsTable[i-1][j], lcsTable[i][j-1])
                }
            }
        }

        // Backtrack through the table to build the diff results.
        var rawDiff: [(String, LineChangeType)] = []
        var i = originalLines.count
        var j = modifiedLines.count

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && originalLines[i-1] == modifiedLines[j-1] {
                rawDiff.insert((originalLines[i-1], .unchanged), at: 0)
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || lcsTable[i][j-1] >= lcsTable[i-1][j]) {
                rawDiff.insert((modifiedLines[j-1], .added), at: 0)
                j -= 1
            } else if i > 0 && (j == 0 || lcsTable[i][j-1] < lcsTable[i-1][j]) {
                rawDiff.insert((originalLines[i-1], .deleted), at: 0)
                i -= 1
            } else {
                break
            }
        }
        
        // Post-process to assign line numbers
        var finalDiff: [DiffResult] = []
        var oldLineCounter = 1
        var newLineCounter = 1
        
        for (line, type) in rawDiff {
            switch type {
            case .unchanged:
                finalDiff.append(DiffResult(line: line, type: .unchanged, originalLineNumber: oldLineCounter, modifiedLineNumber: newLineCounter))
                oldLineCounter += 1
                newLineCounter += 1
            case .added:
                finalDiff.append(DiffResult(line: line, type: .added, originalLineNumber: nil, modifiedLineNumber: newLineCounter))
                newLineCounter += 1
            case .deleted:
                finalDiff.append(DiffResult(line: line, type: .deleted, originalLineNumber: oldLineCounter, modifiedLineNumber: nil))
                oldLineCounter += 1
            }
        }
        
        return finalDiff
    }
}

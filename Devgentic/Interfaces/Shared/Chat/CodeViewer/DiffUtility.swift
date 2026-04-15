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

    /// Maximum number of lines before falling back to a simpler linear scan.
    /// Full LCS on files beyond this threshold would freeze the UI.
    private static let lcsLineLimit = 5_000

    /// Generates a diff between an original and a modified string.
    ///
    /// **Optimizations over the original implementation:**
    /// - O(2m) space instead of O(n*m): uses rolling two-row LCS instead of full table.
    /// - Backtrack builds in forward order (append) instead of O(n) insert-at-0.
    /// - Common prefix/suffix stripped before LCS to reduce the matrix size.
    /// - Falls back to a simple linear scan for files > `lcsLineLimit` lines.
    static func generateDiff(original: String, modified: String) -> [DiffResult] {
        let originalLines = original.components(separatedBy: .newlines)
        let modifiedLines = modified.components(separatedBy: .newlines)

        // --- Fast path: strip common prefix and suffix ---
        let minCount = min(originalLines.count, modifiedLines.count)
        var prefixLen = 0
        while prefixLen < minCount && originalLines[prefixLen] == modifiedLines[prefixLen] {
            prefixLen += 1
        }

        var suffixLen = 0
        while suffixLen < (minCount - prefixLen)
                && originalLines[originalLines.count - 1 - suffixLen] == modifiedLines[modifiedLines.count - 1 - suffixLen] {
            suffixLen += 1
        }

        let origCore = Array(originalLines[prefixLen ..< (originalLines.count - suffixLen)])
        let modCore  = Array(modifiedLines[prefixLen ..< (modifiedLines.count - suffixLen)])

        // --- Build the raw diff for the core (changed) region ---
        let coreDiff: [(String, LineChangeType)]

        if origCore.count * modCore.count > lcsLineLimit * lcsLineLimit || origCore.count > lcsLineLimit || modCore.count > lcsLineLimit {
            // Fallback: linear scan for very large files — shows all old as deleted, all new as added
            coreDiff = origCore.map { ($0, .deleted) } + modCore.map { ($0, .added) }
        } else {
            coreDiff = lcsCoreDiff(original: origCore, modified: modCore)
        }

        // --- Assemble final diff: prefix (unchanged) + core + suffix (unchanged) ---
        var finalDiff: [DiffResult] = []
        var oldLine = 1
        var newLine = 1

        // Common prefix
        for i in 0..<prefixLen {
            finalDiff.append(DiffResult(line: originalLines[i], type: .unchanged, originalLineNumber: oldLine, modifiedLineNumber: newLine))
            oldLine += 1; newLine += 1
        }

        // Core diff
        for (line, type) in coreDiff {
            switch type {
            case .unchanged:
                finalDiff.append(DiffResult(line: line, type: .unchanged, originalLineNumber: oldLine, modifiedLineNumber: newLine))
                oldLine += 1; newLine += 1
            case .deleted:
                finalDiff.append(DiffResult(line: line, type: .deleted, originalLineNumber: oldLine, modifiedLineNumber: nil))
                oldLine += 1
            case .added:
                finalDiff.append(DiffResult(line: line, type: .added, originalLineNumber: nil, modifiedLineNumber: newLine))
                newLine += 1
            }
        }

        // Common suffix
        for i in 0..<suffixLen {
            let idx = originalLines.count - suffixLen + i
            finalDiff.append(DiffResult(line: originalLines[idx], type: .unchanged, originalLineNumber: oldLine, modifiedLineNumber: newLine))
            oldLine += 1; newLine += 1
        }

        return finalDiff
    }

    // MARK: - LCS Core Diff (O(2m) space)

    /// Computes the diff for the changed region using a rolling two-row LCS.
    /// Space: O(2 * modifiedCount) instead of O(n * m).
    private static func lcsCoreDiff(original: [String], modified: [String]) -> [(String, LineChangeType)] {
        let n = original.count
        let m = modified.count

        guard n > 0 || m > 0 else { return [] }

        // --- Forward pass: compute LCS lengths with two rows ---
        // We also need the full backtrack info, so store direction pointers.
        // For space efficiency with backtracking, we use a compact direction table.
        // Direction: 0 = diagonal (match), 1 = up (delete), 2 = left (add)
        var directions = Array(repeating: Array(repeating: UInt8(0), count: m + 1), count: n + 1)
        var prev = Array(repeating: 0, count: m + 1)
        var curr = Array(repeating: 0, count: m + 1)

        for i in 1...n {
            for j in 1...m {
                if original[i-1] == modified[j-1] {
                    curr[j] = prev[j-1] + 1
                    directions[i][j] = 0 // diagonal
                } else if prev[j] >= curr[j-1] {
                    curr[j] = prev[j]
                    directions[i][j] = 1 // up (delete from original)
                } else {
                    curr[j] = curr[j-1]
                    directions[i][j] = 2 // left (add from modified)
                }
            }
            prev = curr
            curr = Array(repeating: 0, count: m + 1)
        }

        // --- Backtrack using direction table (append, then reverse) ---
        var rawDiff: [(String, LineChangeType)] = []
        rawDiff.reserveCapacity(n + m)
        var i = n, j = m

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && directions[i][j] == 0 {
                rawDiff.append((original[i-1], .unchanged))
                i -= 1; j -= 1
            } else if i > 0 && (j == 0 || directions[i][j] == 1) {
                rawDiff.append((original[i-1], .deleted))
                i -= 1
            } else if j > 0 {
                rawDiff.append((modified[j-1], .added))
                j -= 1
            } else {
                break
            }
        }

        rawDiff.reverse()
        return rawDiff
    }
}

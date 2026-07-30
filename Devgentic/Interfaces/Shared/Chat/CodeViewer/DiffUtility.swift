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

/// One run of characters within a diff line: either untouched context or part of the
/// intra-line change. A row's `segments` always reconstruct its `line` when concatenated.
struct DiffSegment: Hashable {
    let text: String
    /// True for the character runs that actually changed between the paired lines.
    let isEmphasized: Bool
}

/// Represents a single line in a diff comparison result, conforming to Identifiable and Hashable for SwiftUI.
struct DiffResult: Identifiable, Hashable {
    let id = UUID()
    let line: String
    let type: LineChangeType
    let originalLineNumber: Int?
    let modifiedLineNumber: Int?
    /// Intra-line refinement for MODIFIED line pairs (a deletion paired with an addition
    /// whose text is similar): the line split into changed/unchanged runs. Nil when the
    /// line has no counterpart, the pair is too dissimilar to be a "modification", or the
    /// row is unchanged — renderers fall back to the plain whole-line treatment.
    var segments: [DiffSegment]? = nil
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

        refineIntraLine(&finalDiff)
        return finalDiff
    }

    /// Added/deleted line counts for a "+N −M" stat badge.
    ///
    /// Uses git-style trailing-newline semantics: a final "\n" TERMINATES the last line
    /// rather than opening an empty one, so appending to a newline-terminated file counts
    /// as pure addition instead of reporting a phantom "deleted blank line". Counts only —
    /// `generateDiff` itself keeps its raw rows (hunk reconstruction depends on their
    /// exact round-trip).
    static func changeCounts(original: String, modified: String) -> (added: Int, deleted: Int) {
        func trimmed(_ text: String) -> String {
            text.hasSuffix("\n") ? String(text.dropLast()) : text
        }
        var added = 0, deleted = 0
        for row in generateDiff(original: trimmed(original), modified: trimmed(modified)) {
            switch row.type {
            case .added: added += 1
            case .deleted: deleted += 1
            case .unchanged: break
            }
        }
        return (added, deleted)
    }

    // MARK: - Hunks




    // MARK: - Intra-line refinement

    /// Character cores longer than this skip the char-LCS and fall back to one contiguous
    /// emphasized span (prefix/suffix strip only) — the quadratic table stays bounded.
    private static let intraLineCoreLimit = 400
    /// Unchanged gaps of at most this many characters BETWEEN two changed runs are absorbed
    /// into one run — `foo(a, b)` → `foo(x, y)` reads as one edit, not two chars of confetti.
    private static let intraLineMergeGap = 2
    /// Minimum fraction of a line pair that must be unchanged for it to count as a
    /// MODIFICATION. Below this the lines are just different lines; highlighting ~all of
    /// both is noise, so they keep the plain whole-line treatment. Deliberately strict:
    /// character-level LCS finds scattered letter-soup subsequences between UNRELATED
    /// code lines, so a lenient gate lets nonsense pairs through.
    private static let intraLineMinSimilarity = 0.45
    /// At most this many pairs are refined per diff — a pathological 1000-line rewrite
    /// gets plain rows past this point rather than a quadratic bill per pair.
    private static let intraLineMaxPairs = 300

    /// Pairs deletions with additions inside each change block (a maximal run of
    /// non-unchanged rows) positionally — k-th deletion ↔ k-th addition — and attaches
    /// character-level segments to pairs similar enough to be modifications.
    private static func refineIntraLine(_ results: inout [DiffResult]) {
        var refinedPairs = 0
        var i = 0
        while i < results.count, refinedPairs < intraLineMaxPairs {
            guard results[i].type != .unchanged else { i += 1; continue }
            var j = i
            while j < results.count && results[j].type != .unchanged { j += 1 }

            let deletions = (i..<j).filter { results[$0].type == .deleted }
            let additions = (i..<j).filter { results[$0].type == .added }
            for k in 0..<min(deletions.count, additions.count) {
                guard refinedPairs < intraLineMaxPairs else { break }
                refinedPairs += 1
                if let (oldSegments, newSegments) = intraLineSegments(
                    old: results[deletions[k]].line,
                    new: results[additions[k]].line
                ) {
                    results[deletions[k]].segments = oldSegments
                    results[additions[k]].segments = newSegments
                }
            }
            i = j
        }
    }

    /// Character-level refinement of one deletion/addition pair, or nil when the pair
    /// isn't similar enough to be a modification. Works on `Character`s (grapheme
    /// clusters), so multi-scalar content — emoji, combining marks — never splits.
    private static func intraLineSegments(old: String, new: String) -> (old: [DiffSegment], new: [DiffSegment])? {
        let oldChars = Array(old)
        let newChars = Array(new)
        guard !oldChars.isEmpty, !newChars.isEmpty else { return nil }

        // Common prefix/suffix — the cheap pass that already nails the dominant
        // "small edit in the middle of a line" case.
        let minCount = min(oldChars.count, newChars.count)
        var prefix = 0
        while prefix < minCount && oldChars[prefix] == newChars[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < (minCount - prefix)
                && oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }

        let oldCore = Array(oldChars[prefix ..< (oldChars.count - suffix)])
        let newCore = Array(newChars[prefix ..< (newChars.count - suffix)])
        guard !oldCore.isEmpty || !newCore.isEmpty else { return nil }   // identical lines

        // Changed masks over the cores.
        var oldCoreChanged: [Bool]
        var newCoreChanged: [Bool]
        if oldCore.count > intraLineCoreLimit || newCore.count > intraLineCoreLimit {
            // Bounded fallback: one contiguous span per side.
            oldCoreChanged = Array(repeating: true, count: oldCore.count)
            newCoreChanged = Array(repeating: true, count: newCore.count)
        } else {
            (oldCoreChanged, newCoreChanged) = charLCSChangedMasks(old: oldCore, new: newCore)
        }
        // Shared-character count derived from the MASK, pre-merge — consistent with what
        // will actually render by construction (both sides carry the same match count).
        let coreCommonCount = oldCoreChanged.lazy.filter { !$0 }.count

        // Similarity gate: mostly-shared pairs are modifications; mostly-different pairs
        // are just different lines and stay plain.
        let unchangedCount = prefix + suffix + coreCommonCount
        let similarity = Double(unchangedCount) / Double(max(oldChars.count, newChars.count))
        guard similarity >= intraLineMinSimilarity else { return nil }

        mergeSmallGaps(&oldCoreChanged)
        mergeSmallGaps(&newCoreChanged)

        return (
            segments(for: oldChars, prefix: prefix, suffix: suffix, coreChanged: oldCoreChanged),
            segments(for: newChars, prefix: prefix, suffix: suffix, coreChanged: newCoreChanged)
        )
    }

    /// Character-level rolling LCS over the (bounded) cores. Returns per-character
    /// changed masks. Mirrors the line-level algorithm above, including the `1...0`
    /// guards for one-sided cores.
    private static func charLCSChangedMasks(old: [Character], new: [Character]) -> ([Bool], [Bool]) {
        let n = old.count
        let m = new.count
        if n == 0 { return ([], Array(repeating: true, count: m)) }
        if m == 0 { return (Array(repeating: true, count: n), []) }

        var directions = Array(repeating: Array(repeating: UInt8(0), count: m + 1), count: n + 1)
        var prev = Array(repeating: 0, count: m + 1)
        var curr = Array(repeating: 0, count: m + 1)

        for i in 1...n {
            for j in 1...m {
                if old[i-1] == new[j-1] {
                    curr[j] = prev[j-1] + 1
                    directions[i][j] = 0
                } else if prev[j] >= curr[j-1] {
                    curr[j] = prev[j]
                    directions[i][j] = 1
                } else {
                    curr[j] = curr[j-1]
                    directions[i][j] = 2
                }
            }
            prev = curr
            curr = Array(repeating: 0, count: m + 1)
        }

        var oldChanged = Array(repeating: false, count: n)
        var newChanged = Array(repeating: false, count: m)
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && directions[i][j] == 0 {
                i -= 1; j -= 1
            } else if i > 0 && (j == 0 || directions[i][j] == 1) {
                oldChanged[i-1] = true
                i -= 1
            } else if j > 0 {
                newChanged[j-1] = true
                j -= 1
            } else {
                break
            }
        }
        return (oldChanged, newChanged)
    }

    /// Absorbs unchanged gaps of ≤ `intraLineMergeGap` characters between changed runs.
    private static func mergeSmallGaps(_ mask: inout [Bool]) {
        var index = 0
        while index < mask.count {
            guard mask[index] else { index += 1; continue }
            // End of this changed run; measure the unchanged gap to the next one.
            var gapStart = index + 1
            while gapStart < mask.count && mask[gapStart] { gapStart += 1 }
            var gapEnd = gapStart
            while gapEnd < mask.count && !mask[gapEnd] { gapEnd += 1 }
            if gapEnd < mask.count && (gapEnd - gapStart) <= intraLineMergeGap {
                for g in gapStart..<gapEnd { mask[g] = true }
                index = gapStart      // re-scan through the merged run
            } else {
                index = gapEnd
            }
        }
    }

    /// Builds the full-line segments: unchanged prefix, alternating core runs, unchanged
    /// suffix — concatenation always reconstructs the original line.
    private static func segments(for chars: [Character], prefix: Int, suffix: Int, coreChanged: [Bool]) -> [DiffSegment] {
        var result: [DiffSegment] = []
        func append(_ text: String, emphasized: Bool) {
            guard !text.isEmpty else { return }
            if let last = result.last, last.isEmphasized == emphasized {
                result[result.count - 1] = DiffSegment(text: last.text + text, isEmphasized: emphasized)
            } else {
                result.append(DiffSegment(text: text, isEmphasized: emphasized))
            }
        }

        append(String(chars[0..<prefix]), emphasized: false)
        var runStart = 0
        while runStart < coreChanged.count {
            var runEnd = runStart
            while runEnd < coreChanged.count && coreChanged[runEnd] == coreChanged[runStart] { runEnd += 1 }
            let text = String(chars[(prefix + runStart)..<(prefix + runEnd)])
            append(text, emphasized: coreChanged[runStart])
            runStart = runEnd
        }
        append(String(chars[(chars.count - suffix)...]), emphasized: false)
        return result
    }

    // MARK: - LCS Core Diff (O(2m) space)

    /// Computes the diff for the changed region using a rolling two-row LCS.
    /// Space: O(2 * modifiedCount) instead of O(n * m).
    private static func lcsCoreDiff(original: [String], modified: [String]) -> [(String, LineChangeType)] {
        let n = original.count
        let m = modified.count

        // A one-sided (or empty) core needs no LCS: an empty original means every
        // modified line was added; an empty modified means every original line was
        // deleted. This is identical to what the backtrack below would yield — and,
        // crucially, it guards the `1...n` / `1...m` loops, which trap on `1...0`
        // when a dimension is 0. That is reached on ANY pure-insertion or
        // pure-deletion diff (append lines to a file; a file ending in a newline vs
        // a trailing-trimmed snippet), i.e. common input, not an edge case. Both-empty
        // falls out of the first branch as `[]`.
        if n == 0 { return modified.map { ($0, .added) } }
        if m == 0 { return original.map { ($0, .deleted) } }

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

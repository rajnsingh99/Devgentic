// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DiffUtility.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

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
    /// Intra-line refinement for modified line pairs (a deletion paired with a similar addition): the line split into
    /// changed and unchanged runs. Nil when the line has no counterpart, the pair is too dissimilar to count as a
    /// modification, or the row is unchanged; renderers then use the plain whole-line treatment.
    var segments: [DiffSegment]? = nil
}

/// A utility for generating a line-by-line diff between two strings.
struct DiffUtility {

    // Why: 5,000 bounds two quadratic costs (doubling is 4x): up to 25,000,000 cell visits on the main actor, and a retained
    // ~25 MB `UInt8` direction table for the backtrack (see `lcsCoreDiff`).
    /// Maximum number of lines before falling back to a simpler linear scan; full LCS beyond this would freeze the UI.
    private static let lcsLineLimit = 5_000

    /// Generates a diff between an original and a modified string: line-level rows plus character-level `segments` on
    /// modified pairs. Callers that need only the row types should use `lineLevelDiff`; the refinement is the expensive
    /// half.
    static func generateDiff(original: String, modified: String) -> [DiffResult] {
        var rows = lineLevelDiff(original: original, modified: modified)
        refineIntraLine(&rows)
        return rows
    }

    // Why: the backtrack still needs a (n+1) x (m+1) direction table, so space is O(n*m) bytes; `lcsLineLimit` is sized
    // against exactly that.
    /// The line-level half of `generateDiff`: identical rows minus the character-level `refineIntraLine` pass (every
    /// `segments` is nil). Rolling two-row LCS, common prefix/suffix stripped first, linear scan above `lcsLineLimit`.
    /// Callers needing counts and diff text run it once and derive both from the same rows (`changeCounts(rows:)`).
    static func lineLevelDiff(original: String, modified: String) -> [DiffResult] {
        #if DEBUG
        lineLevelDiffCalls.withLock { $0 += 1 }
        #endif
        // An empty side is zero lines, and one trailing newline terminates the last line instead of opening an empty one
        // (git-style); otherwise creations show phantom rows. Applied here so rows and `changeCounts` describe the same thing.
        func lines(_ text: String) -> [String] {
            guard !text.isEmpty else { return [] }
            let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
            return body.isEmpty ? [] : body.components(separatedBy: .newlines)
        }
        let originalLines = lines(original)
        let modifiedLines = lines(modified)

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

    /// Added/deleted line counts for a '+N −M' stat badge, with git-style trailing-newline semantics.
    /// A final newline terminates the last line, so appending to a newline-terminated file counts as pure addition.
    /// Runs the line-level diff only: counts depend on `row.type`, which `refineIntraLine` never changes.
    static func changeCounts(original: String, modified: String) -> (added: Int, deleted: Int) {
        // The trailing-newline trim lives in `lineLevelDiff`, so the counts and the rows cannot disagree.
        changeCounts(rows: lineLevelDiff(original: original, modified: modified))
    }

    /// The counts of rows a caller ALREADY holds — for a site that also needs the rows
    /// themselves, so the line-level pass runs once ([cv-5], `ActionEffectBuilder`).
    static func changeCounts(rows: [DiffResult]) -> (added: Int, deleted: Int) {
        var added = 0, deleted = 0
        for row in rows {
            switch row.type {
            case .added: added += 1
            case .deleted: deleted += 1
            case .unchanged: break
            }
        }
        return (added, deleted)
    }

    #if DEBUG
    /// Test seams: how many times each pass has run in this process, so a test can assert the tool-completion site costs
    /// one line-level pass and zero refinements per write. Lock-protected because passes run from several isolation
    /// domains at once; a bare static would be a data race in every DEBUG build.
    private static let lineLevelDiffCalls = OSAllocatedUnfairLock(initialState: 0)
    private static let refineIntraLineCalls = OSAllocatedUnfairLock(initialState: 0)
    static var lineLevelDiffCallsForTesting: Int {
        get { lineLevelDiffCalls.withLock { $0 } }
        set { lineLevelDiffCalls.withLock { $0 = newValue } }
    }
    static var refineIntraLineCallsForTesting: Int {
        get { refineIntraLineCalls.withLock { $0 } }
        set { refineIntraLineCalls.withLock { $0 = newValue } }
    }
    #endif

    // MARK: - Hunks




    // MARK: - Intra-line refinement

    /// Character cores longer than this skip the char-LCS and fall back to one contiguous
    /// emphasized span (prefix/suffix strip only) — the quadratic table stays bounded.
    private static let intraLineCoreLimit = 400
    /// Unchanged gaps of at most this many characters BETWEEN two changed runs are absorbed
    /// into one run — `foo(a, b)` → `foo(x, y)` reads as one edit, not two chars of confetti.
    private static let intraLineMergeGap = 2
    /// Minimum fraction of a line pair that must be unchanged for it to count as a modification; below it the lines are
    /// just different lines and keep the whole-line treatment. Strict because character-level LCS finds scattered
    /// subsequences between unrelated code lines.
    private static let intraLineMinSimilarity = 0.45
    /// At most this many pairs are refined per diff — a pathological 1000-line rewrite
    /// gets plain rows past this point rather than a quadratic bill per pair.
    private static let intraLineMaxPairs = 300

    /// Pairs deletions with additions inside each change block (a maximal run of
    /// non-unchanged rows) positionally — k-th deletion ↔ k-th addition — and attaches
    /// character-level segments to pairs similar enough to be modifications.
    private static func refineIntraLine(_ results: inout [DiffResult]) {
        #if DEBUG
        refineIntraLineCalls.withLock { $0 += 1 }
        #endif
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

    // Why: the table is harmless only while both bounds hold: `intraLineCoreLimit` caps a pair at 400x400 and
    // `intraLineMaxPairs` caps how many are refined, with tables allocated and released one at a time.
    /// Character-level rolling LCS over the bounded cores; returns per-character changed masks.
    /// Mirrors the line-level algorithm, including the `1...0` guards for one-sided cores and its O(n*m)-byte table.
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

    // MARK: - LCS Core Diff

    /// Computes the diff for the changed region using a rolling two-row LCS for the lengths and a retained direction
    /// table for the backtrack. Space is O(m) for `prev`/`curr` plus O(n*m) bytes for `directions`, which is what
    /// `lcsLineLimit` bounds.
    private static func lcsCoreDiff(original: [String], modified: [String]) -> [(String, LineChangeType)] {
        let n = original.count
        let m = modified.count

        // A one-sided (or empty) core needs no LCS: an empty original means every line was added, an empty modified every
        // line deleted. It also guards the `1...n`/`1...m` loops, which trap on `1...0`. Both-empty yields `[]`.
        if n == 0 { return modified.map { ($0, .added) } }
        if m == 0 { return original.map { ($0, .deleted) } }

        // Forward pass: compute LCS lengths with two rows, storing direction pointers in a compact table for the backtrack.
        // Direction: 0 = diagonal (match), 1 = up (delete), 2 = left (add).
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

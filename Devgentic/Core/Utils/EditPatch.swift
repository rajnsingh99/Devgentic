// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  EditPatch.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import CryptoKit

/// The reversible record of one agent file write, applied backwards by Undo. Lines keep their terminators and
/// hunks carry line numbers plus `contextLines` of context, so a file restores byte for byte. Reverting
/// applies hunks bottom-up; a hunk whose lines were edited is a conflict and is left alone.
struct EditPatch: Codable, Equatable, Sendable {

    struct Hunk: Codable, Equatable, Sendable {
        /// 0-based line index of `oldLines` in the BEFORE file.
        let oldStart: Int
        /// 0-based line index of `newLines` in the AFTER file.
        let newStart: Int
        /// The before side, context included, each line with its terminator.
        let oldLines: [String]
        /// The after side, context included, each line with its terminator.
        let newLines: [String]
    }

    static let currentVersion = 1
    static let contextLines = 3

    let version: Int
    let path: String
    let conversationID: UUID
    let messageID: UUID
    /// The timeline row (`ToolExecutionData.id`) this write belongs to.
    let toolEventID: UUID
    let createdAt: Date
    /// The file did not exist before the write (`preWriteContent == ""` by convention).
    let createdFile: Bool
    let beforeHash: String
    let afterHash: String
    let hunks: [Hunk]
    /// Set once Undo has applied this patch, so it is not applied twice.
    var revertedAt: Date?

    // MARK: - Building

    /// Nil when nothing changed.
    static func make(before: String, after: String, path: String, conversationID: UUID,
                     messageID: UUID, toolEventID: UUID, createdFile: Bool, now: Date = Date()) -> EditPatch? {
        guard before != after else { return nil }
        let old = lines(of: before)
        let new = lines(of: after)
        return EditPatch(version: currentVersion, path: path, conversationID: conversationID,
                         messageID: messageID, toolEventID: toolEventID, createdAt: now,
                         createdFile: createdFile, beforeHash: hash(before), afterHash: hash(after),
                         hunks: hunks(old: old, new: new), revertedAt: nil)
    }

    /// Splits keeping each line's terminator, so joining reproduces the text exactly. Only `\n`
    /// ends a line; a `\r` before it stays part of the line.
    static func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "\n" || character == "\r\n" {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Past this many old×new lines in the CHANGED MIDDLE, the change becomes one hunk instead of
    /// a line-level diff — a whole-file rewrite of a large file would otherwise be a long diff for
    /// a patch that is effectively "replace the middle" anyway.
    static let lineDiffBudget = 4_000_000

    static func hunks(old: [String], new: [String]) -> [Hunk] {
        // Trim the common prefix and suffix first: a typical edit touches a few lines of a large
        // file, and this leaves the diff almost nothing to do.
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let oldMid = Array(old[prefix..<(old.count - suffix)])
        let newMid = Array(new[prefix..<(new.count - suffix)])

        // Per line of the full files: is it removed (old) / inserted (new)?
        var removed = Set<Int>()
        var inserted = Set<Int>()
        if oldMid.count * newMid.count > lineDiffBudget || oldMid.isEmpty || newMid.isEmpty {
            removed = Set(prefix..<(prefix + oldMid.count))
            inserted = Set(prefix..<(prefix + newMid.count))
        } else {
            for change in newMid.difference(from: oldMid) {
                switch change {
                case .remove(let offset, _, _): removed.insert(prefix + offset)
                case .insert(let offset, _, _): inserted.insert(prefix + offset)
                }
            }
        }

        // Walk both files together, collecting change runs with their positions.
        struct Run { var oldStart: Int; var oldEnd: Int; var newStart: Int; var newEnd: Int }
        var runs: [Run] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if removed.contains(i) || inserted.contains(j) {
                let start = (i, j)
                while removed.contains(i) { i += 1 }
                while inserted.contains(j) { j += 1 }
                runs.append(Run(oldStart: start.0, oldEnd: i, newStart: start.1, newEnd: j))
            } else {
                i += 1; j += 1
            }
        }

        // Add context, merging runs whose context would overlap.
        let c = contextLines
        var merged: [Run] = []
        for run in runs {
            var widened = Run(oldStart: max(0, run.oldStart - c), oldEnd: min(old.count, run.oldEnd + c),
                              newStart: max(0, run.newStart - c), newEnd: min(new.count, run.newEnd + c))
            if let last = merged.last, widened.oldStart <= last.oldEnd {
                widened.oldStart = last.oldStart
                widened.newStart = last.newStart
                merged[merged.count - 1] = widened
            } else {
                merged.append(widened)
            }
        }
        return merged.map {
            Hunk(oldStart: $0.oldStart, newStart: $0.newStart,
                 oldLines: Array(old[$0.oldStart..<$0.oldEnd]), newLines: Array(new[$0.newStart..<$0.newEnd]))
        }
    }

    // MARK: - Reverting

    enum RevertResult: Equatable {
        /// The file's content with this write undone.
        case content(String)
        /// The write created the file and it is still exactly as written: undoing deletes it.
        case deleteFile
        /// Hunks whose original lines are missing from the file (1-based, for display); nothing is applied.
        case conflict(hunks: [Int])
    }

    /// Undoes this write on `current` (nil = the file does not exist now).
    func revert(current: String?) -> RevertResult {
        if createdFile {
            // Deleting is all-or-nothing: only a file still exactly as written may go.
            guard let current, Self.hash(current) == afterHash else { return .conflict(hunks: Array(1...max(1, hunks.count))) }
            return .deleteFile
        }
        guard let current else { return .conflict(hunks: Array(1...max(1, hunks.count))) }

        var lines = Self.lines(of: current)
        var conflicts: [Int] = []
        // Bottom-up, each hunk must sit above the one placed after it.
        var ceiling = lines.count
        for (index, hunk) in hunks.enumerated().reversed() {
            guard let at = Self.locate(hunk.newLines, in: lines, near: hunk.newStart, below: ceiling) else {
                conflicts.append(index + 1)
                continue
            }
            lines.replaceSubrange(at..<(at + hunk.newLines.count), with: hunk.oldLines)
            ceiling = at
        }
        guard conflicts.isEmpty else { return .conflict(hunks: conflicts.sorted()) }
        return .content(lines.joined())
    }

    /// The start of `block` in `lines` closest to `expected`, ending at or before `ceiling`.
    static func locate(_ block: [String], in lines: [String], near expected: Int, below ceiling: Int) -> Int? {
        let last = ceiling - block.count
        guard last >= 0 else { return nil }
        func matches(_ start: Int) -> Bool {
            for k in 0..<block.count where lines[start + k] != block[k] { return false }
            return true
        }
        let anchor = min(max(expected, 0), last)
        for distance in 0...max(anchor, last - anchor) {
            if anchor - distance >= 0, matches(anchor - distance) { return anchor - distance }
            if distance > 0, anchor + distance <= last, matches(anchor + distance) { return anchor + distance }
        }
        return nil
    }
}

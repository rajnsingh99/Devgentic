// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitFileDiff.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// One side of a diff.
enum GitDiffSide: Equatable, Sendable {
    /// No such version (added, untracked, deleted, unborn branch) — diffs as empty text.
    case empty
    case head(path: String)
    case index(path: String)
    case worktree(path: String)

    /// Which two sides a row's diff compares.
    ///
    /// | Filter   | original | modified |
    /// |----------|----------|----------|
    /// | unstaged | index    | worktree |
    /// | staged   | HEAD     | index    |
    /// | all      | HEAD     | worktree |
    ///
    /// Decided from the STATUS, never by attempting a read and treating failure as "empty": a read
    /// that fails unexpectedly must surface as an error, not as "the whole file was added".
    ///
    /// - The HEAD side of a rename/copy is the ORIGINAL path; every later side is the new path.
    /// - Conflicted files have no stage-0 index entry (`:0:` fails during a conflict — they live in
    ///   stages 1–3), so a conflict always shows HEAD → worktree, i.e. the conflict markers.
    static func sides(for file: GitFileChange, filter: GitChangesFilter,
                      isUnborn: Bool) -> (original: GitDiffSide, modified: GitDiffSide) {
        let path = file.path
        let headPath = file.originalPath ?? path
        let head: GitDiffSide = (isUnborn || file.indexStatus == "A") ? .empty : .head(path: headPath)
        let index: GitDiffSide = file.indexStatus == "D" ? .empty : .index(path: path)
        let worktree: GitDiffSide = file.worktreeStatus == "D" ? .empty : .worktree(path: path)

        switch file.kind {
        case .untracked:
            return (.empty, .worktree(path: path))
        case .unmerged:
            return (isUnborn ? .empty : .head(path: path), .worktree(path: path))
        case .ignored:
            return (.empty, .empty)
        case .ordinary, .renamed, .copied:
            switch filter {
            case .unstaged: return (index, worktree)
            case .staged:   return (head, index)
            case .all:      return (head, worktree)
            }
        }
    }
}

/// One side's bytes, as read.
enum GitSideRead: Sendable {
    case content(Data)
    case tooLarge
    case failed(String)

    /// Reads a worktree file, refusing anything over the byte limit WITHOUT reading it.
    static func readWorktree(_ url: URL) -> GitSideRead {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if size > UntrackedFileInfo.byteLimit { return .tooLarge }
            return .content(try Data(contentsOf: url))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// The result of loading one row's diff.
enum GitFileDiff: Sendable {
    case lines([DiffResult])
    case binary
    /// A side exceeds `UntrackedFileInfo.byteLimit` (1 MB, mirroring the approval banner).
    case tooLarge
    case failed(String)
}

/// A rendered row: a diff line, or a run of unchanged lines folded away.
enum GitDiffDisplayRow: Identifiable, Sendable {
    case line(DiffResult)
    case gap(id: Int, hiddenLines: Int)

    var id: String {
        switch self {
        case .line(let result): return result.id.uuidString
        case .gap(let id, _): return "gap-\(id)"
        }
    }

    /// Keeps every changed line plus `context` unchanged lines either side of it; folds the rest.
    ///
    /// `generateDiff` returns the WHOLE file — fine for the approval banner's small previews, but
    /// a one-line change in a 3 000-line file would bury the change. A gap shorter than or equal
    /// to one line is shown instead of folded: "1 unchanged line" saves nothing.
    static func collapse(_ rows: [DiffResult], context: Int = 3) -> [GitDiffDisplayRow] {
        guard !rows.isEmpty else { return [] }
        var keep = [Bool](repeating: false, count: rows.count)
        for (i, row) in rows.enumerated() where row.type != .unchanged {
            for j in max(0, i - context)...min(rows.count - 1, i + context) { keep[j] = true }
        }

        var result: [GitDiffDisplayRow] = []
        var gapStart: Int?
        var gapCount = 0

        func flushGap(endingAt end: Int) {
            guard let start = gapStart else { return }
            if end - start <= 1 {
                for k in start..<end { result.append(.line(rows[k])) }
            } else {
                gapCount += 1
                result.append(.gap(id: gapCount, hiddenLines: end - start))
            }
            gapStart = nil
        }

        for (i, row) in rows.enumerated() {
            if keep[i] {
                flushGap(endingAt: i)
                result.append(.line(row))
            } else if gapStart == nil {
                gapStart = i
            }
        }
        flushGap(endingAt: rows.count)
        return result
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitChangesSnapshot.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Size of an untracked file, which `numstat` does not cover.
enum UntrackedFileInfo: Equatable, Sendable {
    case lines(Int)
    case binary
    /// Over `byteLimit` — not read.
    case tooLarge
    /// Vanished or unreadable between `status` and the read. Shown, not hidden.
    case unreadable

    /// Mirrors `FileChangePreviewView`'s diff byte limit.
    static let byteLimit = 1_000_000
    /// How far to look for a NUL byte. git's own binary heuristic uses the first 8000 bytes.
    static let binarySniffLength = 8000

    var addedLines: Int {
        if case .lines(let n) = self { return n }
        return 0
    }

    /// Classifies already-read bytes.
    static func classify(_ data: Data) -> UntrackedFileInfo {
        if data.isEmpty { return .lines(0) }
        if data.prefix(binarySniffLength).contains(0) { return .binary }
        var newlines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        // A last line without a trailing newline is still a line.
        if data.last != 0x0A { newlines += 1 }
        return .lines(newlines)
    }

    /// Reads and classifies a file on disk, refusing anything over `byteLimit` without reading it.
    static func measure(_ url: URL) -> UntrackedFileInfo {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return .unreadable }
        if size > byteLimit { return .tooLarge }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return classify(data)
    }
}

/// A merge, rebase, cherry-pick or revert the user is in the middle of.
enum GitInProgressOperation: String, Equatable, Sendable {
    case merge, rebase, cherryPick, revert

    /// Marker paths inside the git dir, in precedence order (a rebase can stop on a cherry-pick).
    static let markers: [(path: String, operation: GitInProgressOperation)] = [
        ("rebase-merge", .rebase),
        ("rebase-apply", .rebase),
        ("MERGE_HEAD", .merge),
        ("CHERRY_PICK_HEAD", .cherryPick),
        ("REVERT_HEAD", .revert),
    ]

    static func detect(gitDir: String, exists: (String) -> Bool) -> GitInProgressOperation? {
        markers.first { exists((gitDir as NSString).appendingPathComponent($0.path)) }?.operation
    }
}

enum GitChangesFilter: String, CaseIterable, Sendable {
    case all, staged, unstaged
}

struct GitLineTotals: Equatable, Sendable {
    var added: Int
    var deleted: Int

    /// Counts in words for VoiceOver. One key per plural form, count as a real argument — the
    /// codebase's convention (see `WorkflowCanvasState`): a translator attaches plural variations
    /// per key, and no `inflect:` markup can reach a user raw.
    static func spoken(_ totals: GitLineTotals) -> String {
        let added = totals.added == 1 ? String(localized: "1 line added") : String(localized: "\(totals.added) lines added")
        let deleted = totals.deleted == 1 ? String(localized: "1 line deleted") : String(localized: "\(totals.deleted) lines deleted")
        return "\(added), \(deleted)"
    }
}

/// One changed path.
struct GitFileChange: Equatable, Identifiable, Sendable {
    var id: String { path }

    /// Repo-root-relative.
    var path: String
    var originalPath: String?
    var indexStatus: Character
    var worktreeStatus: Character
    var kind: GitStatusEntry.Kind
    /// HEAD → index counts; nil when nothing is staged.
    var staged: GitLineCounts?
    /// index → worktree counts; nil when nothing is unstaged (or the file is untracked).
    var unstaged: GitLineCounts?
    /// Set for untracked files only.
    var untracked: UntrackedFileInfo?
    /// True when the project is a subfolder of the repository and this path lies outside it.
    var isOutsideProject: Bool

    var hasStagedChange: Bool { kind != .untracked && indexStatus != "." }
    var hasUnstagedChange: Bool { kind == .untracked || worktreeStatus != "." }

    /// The single glyph a row shows: `U` conflicted, `?` untracked, else the index status when
    /// something is staged, else the worktree status.
    var statusGlyph: Character {
        switch kind {
        case .unmerged: return "U"
        case .untracked: return "?"
        default: return indexStatus != "." ? indexStatus : worktreeStatus
        }
    }

    /// The status as a WORD, for VoiceOver — the glyph alone reads as a bare letter ("M").
    var statusDescription: String {
        switch statusGlyph {
        case "A": return String(localized: "added")
        case "M": return String(localized: "modified")
        case "D": return String(localized: "deleted")
        case "R": return String(localized: "renamed")
        case "C": return String(localized: "copied")
        case "T": return String(localized: "type changed")
        case "U": return String(localized: "conflicted")
        case "?": return String(localized: "untracked")
        default: return String(localized: "changed")
        }
    }

    /// What VoiceOver reads for a row: path, status word, and the counts in words (`+3 −2` read
    /// aloud is "plus three minus two" — not what it means).
    func accessibilitySummary(for filter: GitChangesFilter) -> String {
        let counts: String
        if let info = untracked {
            switch info {
            case .lines(let n): counts = n == 1 ? String(localized: "1 line") : String(localized: "\(n) lines")
            case .binary: counts = String(localized: "binary")
            case .tooLarge: counts = String(localized: "too large to count")
            case .unreadable: counts = String(localized: "unreadable")
            }
        } else if isBinary {
            counts = String(localized: "binary")
        } else {
            counts = GitLineTotals.spoken(totals(for: filter))
        }
        var parts = [path, statusDescription, counts]
        if let originalPath { parts.insert(String(localized: "from \(originalPath)"), at: 2) }
        if isOutsideProject { parts.append(String(localized: "outside the project")) }
        return parts.joined(separator: ", ")
    }

    var isBinary: Bool {
        if untracked == .binary { return true }
        return (staged?.isBinary ?? false) || (unstaged?.isBinary ?? false)
    }

    /// Lines for one filter. `.all` SUMS staged and unstaged — exact unless the unstaged edit
    /// partly reverts the staged one. Accepted: an exact HEAD→worktree count costs a third process
    /// per refresh (and fails on an unborn branch) for a number shown as a summary.
    func totals(for filter: GitChangesFilter) -> GitLineTotals {
        let untrackedAdded = untracked?.addedLines ?? 0
        let s = GitLineTotals(added: staged?.added ?? 0, deleted: staged?.deleted ?? 0)
        let u = GitLineTotals(added: (unstaged?.added ?? 0) + untrackedAdded, deleted: unstaged?.deleted ?? 0)
        switch filter {
        case .staged: return s
        case .unstaged: return u
        case .all: return GitLineTotals(added: s.added + u.added, deleted: s.deleted + u.deleted)
        }
    }
}

struct GitChangesSnapshot: Equatable, Sendable {
    var repoRoot: String
    var branch: GitBranchStatus
    var files: [GitFileChange]
    /// Untracked paths beyond `untrackedLimit`, counted but not listed.
    var untrackedOverflowCount: Int
    var inProgressOperation: GitInProgressOperation?
    /// Some git output was incomplete or unparseable: the list may be missing files. The panel says
    /// so instead of presenting a partial list as the whole one.
    var isTruncated: Bool

    /// Untracked rows listed (and measured) at most. Guards against an un-ignored `node_modules/`.
    static let untrackedLimit = 500

    var isClean: Bool { files.isEmpty && untrackedOverflowCount == 0 }

    func files(for filter: GitChangesFilter) -> [GitFileChange] {
        switch filter {
        case .all: return files
        case .staged: return files.filter(\.hasStagedChange)
        case .unstaged: return files.filter(\.hasUnstagedChange)
        }
    }

    func totals(for filter: GitChangesFilter = .all) -> GitLineTotals {
        files(for: filter).reduce(GitLineTotals(added: 0, deleted: 0)) { sum, file in
            let t = file.totals(for: filter)
            return GitLineTotals(added: sum.added + t.added, deleted: sum.deleted + t.deleted)
        }
    }

    /// Merges the parsed sources into rows. `projectPrefix` is the project folder relative to `repoRoot` with a
    /// trailing `/` (`""` for the root); rows outside it are marked, not dropped. `untrackedInfo` measures the
    /// first `untrackedLimit` untracked paths.
    static func build(
        repoRoot: String,
        status: GitStatusReport,
        unstaged: [String: GitLineCounts],
        staged: [String: GitLineCounts],
        untrackedInfo: [String: UntrackedFileInfo],
        projectPrefix: String,
        inProgressOperation: GitInProgressOperation?,
        isTruncated: Bool
    ) -> GitChangesSnapshot {
        var files: [GitFileChange] = []
        var untrackedSeen = 0
        var overflow = 0

        for entry in status.entries {
            switch entry.kind {
            case .ignored:
                continue
            case .untracked:
                untrackedSeen += 1
                if untrackedSeen > untrackedLimit { overflow += 1; continue }
            default:
                break
            }

            let isUntracked = entry.kind == .untracked
            files.append(GitFileChange(
                path: entry.path,
                originalPath: entry.originalPath,
                indexStatus: entry.indexStatus,
                worktreeStatus: entry.worktreeStatus,
                kind: entry.kind,
                staged: isUntracked || entry.indexStatus == "." ? nil : staged[entry.path],
                unstaged: isUntracked || entry.worktreeStatus == "." ? nil : unstaged[entry.path],
                untracked: isUntracked ? (untrackedInfo[entry.path] ?? .unreadable) : nil,
                isOutsideProject: !projectPrefix.isEmpty && !entry.path.hasPrefix(projectPrefix)
            ))
        }

        // Conflicts first — during a merge they are what the user came for. Otherwise git's order
        // (path order within each record type) is kept: the sort is stable.
        let ordered = files.enumerated().sorted { a, b in
            let ua = a.element.kind == .unmerged, ub = b.element.kind == .unmerged
            return ua != ub ? ua : a.offset < b.offset
        }.map(\.element)

        return GitChangesSnapshot(
            repoRoot: repoRoot,
            branch: status.branch,
            files: ordered,
            untrackedOverflowCount: overflow,
            inProgressOperation: inProgressOperation,
            isTruncated: isTruncated
        )
    }

    /// The untracked paths `build` will list — the ones worth measuring.
    static func untrackedPathsToMeasure(_ status: GitStatusReport) -> [String] {
        Array(status.entries.lazy.filter { $0.kind == .untracked }.map(\.path).prefix(untrackedLimit))
    }

    /// `projectPath` relative to `repoRoot` as a `/`-terminated prefix; `""` when they are the same
    /// directory or the project is not under the root. Both sides are symlink-resolved: git reports
    /// the REAL toplevel (`/private/var/…`) while a picked folder may be `/var/…`.
    static func projectPrefix(projectPath: URL, repoRoot: String) -> String {
        let project = projectPath.resolvingSymlinksInPath().standardizedFileURL.path
        let root = URL(fileURLWithPath: repoRoot).resolvingSymlinksInPath().standardizedFileURL.path
        guard project != root, project.hasPrefix(root + "/") else { return "" }
        return String(project.dropFirst(root.count + 1)) + "/"
    }
}

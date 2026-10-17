// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitPorcelainParser.swift
//  Devgentic
//
//  Pure parser for `git status --porcelain=v2 --branch -z` — the Git Changes panel's status
//  source. No process, no I/O: stdout bytes in, a report out.
//

import Foundation

/// The `# branch.*` headers of a porcelain v2 status.
struct GitBranchStatus: Equatable {
    /// The branch name; nil when HEAD is detached (`# branch.head (detached)`).
    var head: String?
    /// The commit HEAD points at; nil on an unborn branch (`# branch.oid (initial)`).
    var oid: String?
    /// `# branch.upstream`, when one is configured.
    var upstream: String?
    /// `# branch.ab +A -B`, present only when the upstream exists.
    var ahead: Int?
    var behind: Int?

    var isDetached: Bool { head == nil }
    var isUnborn: Bool { oid == nil }
}

/// One changed path. `indexStatus` / `worktreeStatus` are porcelain's `X` / `Y` characters
/// (`.` = unchanged, `M`, `A`, `D`, `R`, `C`, `T`, `U`); untracked and ignored entries carry `?` / `!`
/// in both.
struct GitStatusEntry: Equatable {
    enum Kind: Equatable {
        case ordinary
        /// `R` / `C` record. `score` is the similarity percentage (`R100` ⇒ 100).
        case renamed(score: Int?)
        case copied(score: Int?)
        case unmerged
        case untracked
        case ignored
    }

    /// Repo-root-relative path (porcelain ignores `status.relativePaths`).
    var path: String
    /// The source path of a rename / copy.
    var originalPath: String?
    var indexStatus: Character
    var worktreeStatus: Character
    var kind: Kind

    var hasStagedChange: Bool {
        kind != .untracked && kind != .ignored && indexStatus != "."
    }
    var hasUnstagedChange: Bool {
        kind == .untracked || (kind != .ignored && worktreeStatus != ".")
    }
}

struct GitStatusReport: Equatable {
    var branch: GitBranchStatus
    var entries: [GitStatusEntry]
    /// Records that matched no known shape. The parser stays pure; the CALLER logs this with
    /// its consequence (those paths are missing from the panel) — a silent drop is a lie.
    var malformedRecordCount: Int
}

enum GitPorcelainParser {

    /// Parses `--porcelain=v2 --branch -z` stdout.
    ///
    /// With `-z` every header and record is NUL-terminated and paths are emitted RAW — never
    /// quoted — so spaces, tabs, unicode and leading dashes need no unescaping. A rename record
    /// (`2`) is followed by ONE extra NUL field: its original path.
    ///
    /// Paths are decoded as UTF-8; a filename that is not valid UTF-8 decodes lossily and will not
    /// round-trip to disk. Accepted: macOS filesystems store UTF-8.
    static func parse(_ data: Data) -> GitStatusReport {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }

        var branch = GitBranchStatus()
        var entries: [GitStatusEntry] = []
        var malformed = 0

        var i = 0
        while i < fields.count {
            let field = fields[i]
            i += 1
            // The stream ends with a NUL, so the final split field is empty. No real record is.
            if field.isEmpty { continue }

            switch field.first {
            case "#":
                parseHeader(field, into: &branch)

            case "1":
                // 1 XY sub mH mI mW hH hI <path>
                let parts = field.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9, let (x, y) = statusPair(parts[1]) else { malformed += 1; continue }
                entries.append(GitStatusEntry(path: String(parts[8]), originalPath: nil,
                                              indexStatus: x, worktreeStatus: y, kind: .ordinary))

            case "2":
                // 2 XY sub mH mI mW hH hI <X><score> <path> \0 <origPath>
                let parts = field.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count == 10, let (x, y) = statusPair(parts[1]), i < fields.count else {
                    malformed += 1; continue
                }
                let original = fields[i]
                i += 1
                let marker = parts[8]
                let score = Int(marker.dropFirst())
                let kind: GitStatusEntry.Kind
                switch marker.first {
                case "R": kind = .renamed(score: score)
                case "C": kind = .copied(score: score)
                default: malformed += 1; continue
                }
                entries.append(GitStatusEntry(path: String(parts[9]), originalPath: original,
                                              indexStatus: x, worktreeStatus: y, kind: kind))

            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 <path>
                let parts = field.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11, let (x, y) = statusPair(parts[1]) else { malformed += 1; continue }
                entries.append(GitStatusEntry(path: String(parts[10]), originalPath: nil,
                                              indexStatus: x, worktreeStatus: y, kind: .unmerged))

            case "?", "!":
                guard field.count > 2, field.dropFirst().first == " " else { malformed += 1; continue }
                let isUntracked = field.first == "?"
                let marker: Character = isUntracked ? "?" : "!"
                entries.append(GitStatusEntry(path: String(field.dropFirst(2)), originalPath: nil,
                                              indexStatus: marker, worktreeStatus: marker,
                                              kind: isUntracked ? .untracked : .ignored))

            default:
                malformed += 1
            }
        }

        return GitStatusReport(branch: branch, entries: entries, malformedRecordCount: malformed)
    }

    // MARK: - Private

    private static func parseHeader(_ field: String, into branch: inout GitBranchStatus) {
        // "# branch.<key> <value>". Unknown headers (e.g. `# stash`) are ignored by design —
        // they carry no per-file data, so skipping one loses nothing the panel shows.
        let parts = field.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "#" else { return }
        let value = String(parts[2])
        switch parts[1] {
        case "branch.oid":
            branch.oid = value == "(initial)" ? nil : value
        case "branch.head":
            branch.head = value == "(detached)" ? nil : value
        case "branch.upstream":
            branch.upstream = value
        case "branch.ab":
            let ab = value.split(separator: " ")
            if ab.count == 2, ab[0].hasPrefix("+"), ab[1].hasPrefix("-") {
                branch.ahead = Int(ab[0].dropFirst())
                branch.behind = Int(ab[1].dropFirst())
            }
        default:
            break
        }
    }

    private static func statusPair(_ xy: Substring) -> (Character, Character)? {
        guard xy.count == 2 else { return nil }
        return (xy[xy.startIndex], xy[xy.index(after: xy.startIndex)])
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitNumstatParser.swift
//  Devgentic
//
//  Pure parser for `git diff [--cached] --numstat -z -M` — the per-file `+N −N` counts in the
//  Git Changes panel. No process, no I/O.
//

import Foundation

/// Added / deleted line counts for one path. Both nil ⇒ binary (numstat prints `-  -`).
struct GitLineCounts: Equatable {
    var added: Int?
    var deleted: Int?

    var isBinary: Bool { added == nil && deleted == nil }
    static let binary = GitLineCounts(added: nil, deleted: nil)
}

struct GitNumstatEntry: Equatable {
    /// Repo-root-relative path; for a rename, the DESTINATION.
    var path: String
    /// The rename source, when this record is a rename.
    var originalPath: String?
    var counts: GitLineCounts
}

struct GitNumstatReport: Equatable {
    var entries: [GitNumstatEntry]
    /// Records that matched no known shape — the caller logs these with their consequence.
    var malformedRecordCount: Int

    /// Counts keyed by (destination) path, with duplicates resolved.
    ///
    /// ⚠️ A path CAN appear twice. Captured from real git 2.54 on a conflicted file: the unstaged
    /// numstat emits `0 0 conflict.txt` (the unmerged placeholder) and THEN `4 0 conflict.txt`
    /// (the diff against our side). Last-wins happens to be right for that order, but it is order
    /// luck, so the rule is explicit: a real count beats a `0 0` placeholder; between two real
    /// counts the first stands.
    func countsByPath() -> [String: GitLineCounts] {
        var result: [String: GitLineCounts] = [:]
        for entry in entries {
            if let existing = result[entry.path], !Self.isPlaceholder(existing) { continue }
            result[entry.path] = entry.counts
        }
        return result
    }

    private static func isPlaceholder(_ counts: GitLineCounts) -> Bool {
        counts.added == 0 && counts.deleted == 0
    }
}

enum GitNumstatParser {

    /// Parses `--numstat -z` stdout.
    ///
    /// Two record shapes, both captured from real git:
    /// - ordinary: `added \t deleted \t path \0`
    /// - rename:   `added \t deleted \t \0 src \0 dst \0` — the path field is EMPTY and the two
    ///   paths follow as their own NUL fields.
    /// `-` in both count columns marks a binary file. The caller passes `-M` so the user's
    /// `diff.renames` config cannot change which shape a rename arrives in (verified: `-M`
    /// overrides `diff.renames=false`).
    static func parse(_ data: Data) -> GitNumstatReport {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }

        var entries: [GitNumstatEntry] = []
        var malformed = 0

        var i = 0
        while i < fields.count {
            let field = fields[i]
            i += 1
            if field.isEmpty { continue }   // trailing terminator

            // maxSplits 2: a tab inside the PATH (legal on macOS) stays in the path.
            let parts = field.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let counts = counts(added: parts[0], deleted: parts[1]) else {
                malformed += 1; continue
            }

            if parts[2].isEmpty {
                guard i + 1 < fields.count, !fields[i].isEmpty, !fields[i + 1].isEmpty else {
                    // Only a truncated stream ends mid-rename. Stop: the leftover src field is a
                    // PATH, and re-reading it as a record would count one defect twice.
                    malformed += 1; break
                }
                entries.append(GitNumstatEntry(path: fields[i + 1], originalPath: fields[i], counts: counts))
                i += 2
            } else {
                entries.append(GitNumstatEntry(path: String(parts[2]), originalPath: nil, counts: counts))
            }
        }

        return GitNumstatReport(entries: entries, malformedRecordCount: malformed)
    }

    private static func counts(added: Substring, deleted: Substring) -> GitLineCounts? {
        if added == "-" && deleted == "-" { return .binary }
        guard let a = Int(added), let d = Int(deleted), a >= 0, d >= 0 else { return nil }
        return GitLineCounts(added: a, deleted: d)
    }
}

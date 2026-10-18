// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeProjectGrouping.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The Code sidebar lists sessions under their project, not a date: a session is bound to one folder (`projectPath`).
/// Pure and generic so the ordering rules are testable without SwiftData or a view.
enum CodeProjectGrouping {

    /// Sessions a project shows before "Show N more".
    static let visibleSessionsPerProject = 5

    struct Group<Item> {
        /// Standardized folder path; nil for "No project" (sessions from before folders were recorded).
        let path: String?
        let items: [Item]
        let lastActivity: Date
        /// The folder was moved or deleted. Its sessions stay readable; they cannot run.
        let isMissing: Bool

        var id: String { path ?? "" }

        var title: String {
            guard let path else { return String(localized: "No project") }
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    /// Projects most-recently-active first, each project's sessions newest first. "No project" is
    /// always last — it only holds sessions from before folders were recorded.
    static func groups<Item>(
        _ items: [Item],
        path: (Item) -> String?,
        date: (Item) -> Date,
        folderExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [Group<Item>] {
        var buckets: [String?: [Item]] = [:]
        var order: [String?] = []
        for item in items {
            let key = normalized(path(item))
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }

        let groups = order.map { key -> Group<Item> in
            let sorted = (buckets[key] ?? []).sorted { date($0) > date($1) }
            return Group(
                path: key,
                items: sorted,
                lastActivity: sorted.first.map(date) ?? .distantPast,
                isMissing: key.map { !folderExists($0) } ?? false
            )
        }

        return groups.sorted { lhs, rhs in
            if (lhs.path == nil) != (rhs.path == nil) { return rhs.path == nil }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    /// The same folder written two ways (trailing slash, `..`) is one project.
    static func normalized(_ path: String?) -> String? {
        guard let raw = path?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }
}

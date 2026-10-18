// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPRootsProvider.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import MCP
import os

private let logger = DGLogger(category: "MCPRootsProvider")

/// Publishes workspace roots to MCP servers (`roots/list`), telling them which directories they may operate on.
/// The roots come from Code mode's project path and the Explorer's opened folder.
@MainActor
enum MCPRootsProvider {

    /// The workspace roots currently exposed to MCP servers.
    /// Composed from independent slots (Code project, Explorer folder) so one owner's update cannot erase the other's.
    private(set) static var roots: [URL] = []

    /// How many times a changed root set has been published — one per `roots/list_changed` sent to
    /// every server. Read by tests: a project switch must cost exactly one.
    private(set) static var publishCount = 0

    /// Code mode's project folder. Nil when Code mode has no project selected.
    private static var codeProjectRoot: URL?

    /// The folder open in the Explorer sidebar. Available in chat and workflow too — roots
    /// are not a Code-mode feature, they are "the folders this app currently has open".
    private static var explorerRoot: URL?

    /// Code mode's project changed (or was cleared).
    static func setCodeProjectRoot(_ url: URL?) async {
        guard codeProjectRoot != url else { return }
        codeProjectRoot = url
        logger.info("[MCP-ROOTS] Code project root \(url.map { "→ \($0.path)" } ?? "cleared").")
        await recompute()
    }

    /// The Explorer's opened folder changed (or was cleared).
    static func setExplorerRoot(_ url: URL?) async {
        guard explorerRoot != url else { return }
        explorerRoot = url
        logger.info("[MCP-ROOTS] Explorer root \(url.map { "→ \($0.path)" } ?? "cleared").")
        await recompute()
    }

    /// Moves both slots to `url` in one publish, for a Code project switch.
    /// Setting both first makes the later per-slot calls no-ops, so servers get one notification and never a
    /// boundary that still includes the project just left.
    static func setWorkspace(_ url: URL) async {
        guard codeProjectRoot != url || explorerRoot != url else { return }
        codeProjectRoot = url
        explorerRoot = url
        logger.info("[MCP-ROOTS] Workspace → \(url.path) (Code project and Explorer together, one notification).")
        await recompute()
    }

    /// Publishes the union of the slots.
    /// With neither slot set the result is an empty list rather than a broad default such as the home directory.
    /// Roots are a permission boundary: an empty list makes a server decline or use its own launch directory.
    private static func recompute() async {
        await setRoots([codeProjectRoot, explorerRoot].compactMap { $0 })
    }

    /// Sets the root set and notifies every connected server (`notifications/roots/list_changed`).
    /// Idempotent: an unchanged set is a no-op, so callers can push on every project-path read.
    static func setRoots(_ urls: [URL]) async {
        // Resolve symlinks, not just standardize: servers test containment textually against their own resolved paths.
        // Dedup on the normalized path, not `URL` equality: `file:///a/b` and `file:///a/b/` compare unequal as URLs.
        var seen = Set<String>()
        var normalized: [URL] = []

        for url in urls {
            let resolved = url.resolvingSymlinksInPath()

            var key = resolved.path
            while key.count > 1 && key.hasSuffix("/") { key.removeLast() }

            guard seen.insert(key).inserted else {
                logger.info("""
                    [MCP-ROOTS] '\(url.path)' resolves to '\(key)', which is already advertised — \
                    listing it once. Both root slots can legitimately name the same folder by \
                    different paths.
                    """)
                continue
            }

            if url.standardizedFileURL.path != resolved.path {
                logger.info("""
                    [MCP-ROOTS] Canonicalised '\(url.path)' → '\(resolved.path)' before \
                    advertising it. Servers compare paths textually against their canonical \
                    form, so advertising the symlinked path would make files inside this folder \
                    read as outside it.
                    """)
            }

            normalized.append(resolved)
        }

        guard normalized != roots else { return }

        let previous = roots
        roots = normalized
        publishCount += 1
        logger.info("""
            [MCP-ROOTS] Workspace roots changed (\(previous.count) → \(normalized.count)): \
            \(normalized.map(\.path).joined(separator: ", ")). Notifying connected servers so \
            they re-scope; servers that ignore the notification keep the old boundary.
            """)

        await MCPClientService.shared.notifyRootsChangedEverywhere()
    }

    /// Answers `roots/list`. Only directories that still exist are advertised — naming a
    /// path the server cannot stat produces confusing per-server errors that look like the
    /// server is broken.
    static func currentRoots() -> [Root] {
        let existing = roots.filter { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }

        if existing.count != roots.count {
            let missing = roots.filter { !existing.contains($0) }
            logger.warning("""
                [MCP-ROOTS] \(missing.count) configured root(s) no longer exist and were omitted \
                from roots/list: \(missing.map(\.path).joined(separator: ", ")). Servers will not \
                be able to operate on them.
                """)
        }

        return existing.map { Root(uri: $0.absoluteString, name: $0.lastPathComponent) }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPRootsProvider.swift
//  Devgentic
//
//  Created 2026-08-01 — MCP `roots/list`.
//
//  Roots tell a server which directories it may operate on. Devgentic advertised no roots
//  capability and answered `roots/list` with `methodNotFound`, so filesystem-shaped MCP
//  servers — the single most common category — got no workspace boundary from us. They
//  either refused to operate, fell back to their own launch CWD, or ranged over the whole
//  disk, and the user had to duplicate the project path into every server's argv by hand.
//
//  The app already knows the answer: Code mode owns a project path. This publishes it.
//

import Foundation
import MCP
import os

private let logger = DGLogger(category: "MCPRootsProvider")

@MainActor
enum MCPRootsProvider {

    /// The workspace roots currently exposed to MCP servers.
    ///
    /// Composed from independent SLOTS rather than a single setter. Two unrelated parts of
    /// the app know about folders — Code mode's project and the Explorer's opened folder —
    /// and if both called one `setRoots`, whichever fired last would erase the other's
    /// contribution. Each owns its slot; the union is recomputed and published.
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

    /// Moves BOTH slots to `url` in ONE publish — a Code project switch.
    ///
    /// ⚠️ Why a combined setter (2026-09-24). A switch moves the Explorer and the Code project
    /// together, but they reached this type as two separate calls, so every switch published
    /// `[old, new]` and then `[new]`: two notifications to every connected server, and for the
    /// moment in between a server's boundary included the project the user had just LEFT. Setting
    /// both first means the per-slot calls that follow find nothing changed and publish nothing.
    static func setWorkspace(_ url: URL) async {
        guard codeProjectRoot != url || explorerRoot != url else { return }
        codeProjectRoot = url
        explorerRoot = url
        logger.info("[MCP-ROOTS] Workspace → \(url.path) (Code project and Explorer together, one notification).")
        await recompute()
    }

    /// Publishes the union of the slots.
    ///
    /// NO FALLBACK, deliberately. With neither slot set the answer is an empty list, which is
    /// the honest one: roots are a permission boundary, and defaulting to something broad —
    /// the home directory, the last-used folder — would silently hand a third-party server
    /// the run of the user's disk. This app is not sandboxed, so that grant would be real.
    /// An empty list makes the server decline or fall back to its own launch directory, which
    /// is a recoverable, explicable state; a silent over-grant is not.
    private static func recompute() async {
        await setRoots([codeProjectRoot, explorerRoot].compactMap { $0 })
    }

    /// Replaces the root set and notifies every connected server, per the
    /// `notifications/roots/list_changed` contract. Idempotent — an unchanged set is a
    /// no-op, so callers can push on every project-path read without churn.
    static func setRoots(_ urls: [URL]) async {
        // ⚠️ Symlinks are RESOLVED, not merely standardized. `standardizedFileURL` collapses
        // `..` and `~` but leaves symlinks alone, so a project reached through a symlinked
        // parent was advertised as the link path. Servers enforce their boundary by TEXTUAL
        // containment against the path they resolved for themselves, so the two forms
        // disagree and a file plainly inside the user's folder reads as outside it —
        // "Access denied - path outside allowed directories". Verified against
        // `@modelcontextprotocol/server-filesystem`, which does exactly this.
        //
        // ⚠️ This does NOT rewrite `/var` → `/private/var`. Foundation's
        // `resolvingSymlinksInPath()` deliberately hides the `/private` prefix on macOS's
        // `/tmp`, `/var` and `/etc`, and forcing it (via `realpath`) would advertise a path
        // the user never sees in Finder for no benefit — real roots are project folders under
        // `/Users`, not system temp directories. Anything comparing our roots against a
        // `realpath`-canonical form must canonicalise both sides itself.
        //
        // Resolving also makes the dedup below correct for two paths reaching one directory.
        // ⚠️ Dedup on the normalized PATH, not on `URL` equality. `file:///a/b` and
        // `file:///a/b/` are the same directory and compare UNEQUAL as URLs, and the two
        // slots produce URLs both ways — `NSTemporaryDirectory()`-derived paths carry a
        // trailing slash while `URL(fileURLWithPath:)` on a symlink does not. Set the same
        // folder in both slots and it was advertised twice.
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

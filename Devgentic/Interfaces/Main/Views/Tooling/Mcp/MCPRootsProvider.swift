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
        let normalized = urls
            .map { $0.standardizedFileURL }
            .reduce(into: [URL]()) { acc, url in
                if !acc.contains(url) { acc.append(url) }
            }

        guard normalized != roots else { return }

        let previous = roots
        roots = normalized
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

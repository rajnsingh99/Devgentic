// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MCPRuntimeProbe.swift
//  Devgentic
//
//  Created 2026-08-01 — is the launcher a registry entry needs actually on this machine?
//
//  A registry entry says `runtimeHint: "uvx"`. If uv isn't installed, connecting can only
//  ever fail — with a bare ENOENT from `posix_spawn` that says nothing a user can act on.
//  Checking first lets the browse list disable that row and say "Needs uv" instead, which
//  is the difference between a dead end and an instruction.
//
//  Resolution deliberately mirrors `ShellProcess`: the same augmented PATH, so what the
//  probe finds is exactly what the spawn will find. A probe that consulted a different PATH
//  would be worse than none — it would promise a runtime that then failed to launch.
//

import Foundation
import os

private let logger = DGLogger(category: "MCPRuntimeProbe")

@MainActor
enum MCPRuntimeProbe {

    /// Cached per launcher name. Runtimes do not appear or vanish mid-session often enough
    /// to justify a `stat` on every row of a scrolling grid.
    private static var cache: [String: String?] = [:]

    /// Absolute path to `runtime`, or nil when it is not installed.
    static func resolve(_ runtime: String) -> String? {
        let name = runtime.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if let cached = cache[name] { return cached }

        let resolved = search(name)
        cache[name] = resolved

        if let resolved {
            logger.info("[MCP-RUNTIME] '\(name)' found at \(resolved).")
        } else {
            logger.warning("""
                [MCP-RUNTIME] '\(name)' NOT found on the augmented PATH. Registry entries \
                needing it will be listed but not offerable — the user is told to install it \
                rather than being allowed to add a server that cannot launch. Note the converse \
                does NOT hold for container runtimes: finding `docker` proves only that the CLI \
                is installed, not that its daemon is running — see `isAvailable`.
                """)
        }
        return resolved
    }

    /// Whether the launcher BINARY exists. Not whether it can currently run anything.
    ///
    /// ⚠️ The distinction only matters for container runtimes, and there it matters a lot.
    /// `npx` and `uvx` present on PATH means they will run; `docker` present on PATH means
    /// nothing of the sort — Docker Desktop may be stopped, in which case every `docker run`
    /// exits 125 with "Cannot connect to the Docker daemon". So a docker-backed registry entry
    /// is offered as installable even when it cannot start today.
    ///
    /// That is the RIGHT trade for this call site: it renders a scrolling grid, and probing a
    /// daemon per row would put a socket round-trip on every frame to answer a question that
    /// changes while the user is reading. The daemon's absence is caught where it is cheap and
    /// unambiguous — at connect, where docker's own stderr says exactly what is wrong and
    /// `processFailedToStart` shows it verbatim.
    static func isAvailable(_ runtime: String) -> Bool {
        resolve(runtime) != nil
    }

    /// Forgets cached results — call after the user installs a runtime so the list updates
    /// without a relaunch.
    static func invalidate() {
        logger.info("[MCP-RUNTIME] Cache invalidated; runtimes will be re-probed on next read.")
        cache.removeAll()
    }

    /// What to tell the user when a runtime is missing.
    static func installHint(for runtime: String) -> String {
        switch runtime.lowercased() {
        case "npx", "node":  return "Needs Node.js"
        case "uvx", "uv":    return "Needs uv"
        case "docker":       return "Needs Docker"
        case "":             return "Unsupported"
        default:             return "Needs \(runtime)"
        }
    }

    // MARK: - Private

    /// Same search order as `ShellProcess.resolveExecutable`, over the same augmented PATH.
    private static func search(_ name: String) -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path

        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        // A .app launched from Finder inherits a minimal PATH that contains none of these,
        // which is why they are prepended for the spawn — and must be here too.
        for path in [
            "\(home)/.cargo/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ] where !candidates.contains(path) {
            candidates.insert(path, at: 0)
        }

        for directory in candidates {
            let candidate = "\(directory)/\(name)"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

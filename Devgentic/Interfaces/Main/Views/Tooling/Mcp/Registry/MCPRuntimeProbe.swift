// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPRuntimeProbe.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "MCPRuntimeProbe")

/// Checks whether the launcher a registry entry needs (such as `uvx`) is installed, so the browse list can say
/// "Needs uv" instead of failing with a bare ENOENT. Resolves like `ShellProcess`, with the same augmented PATH, so
/// the probe finds exactly what the spawn will find.
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

    /// Whether the launcher binary exists, not whether it can currently run anything. A docker-backed entry is offered
    /// even when Docker Desktop is stopped: probing a daemon per row would cost a socket round trip per frame, and
    /// connect reports the failure with docker's own stderr.
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

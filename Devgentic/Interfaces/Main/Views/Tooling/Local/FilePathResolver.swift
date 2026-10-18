// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FilePathResolver.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Single source of truth for turning a model-supplied path into an absolute filesystem path. Relative paths
/// anchor to the home directory, since `URL(fileURLWithPath:)` would resolve them against the process working
/// directory, which is the read-only volume root `/` for a GUI-launched app.
enum FilePathResolver {

    /// Resolves a user/model-supplied path to an absolute filesystem path: a leading `~` is expanded, an
    /// already-absolute path is returned unchanged, and a relative path is anchored to the user's HOME directory
    /// (not the process working directory), so `Desktop/x` → `<home>/Desktop/x`.
    static func resolve(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { return expanded }
        return (NSHomeDirectory() as NSString).appendingPathComponent(expanded)
    }
}

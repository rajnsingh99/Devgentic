// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FilePathResolver.swift
//  Devgentic
//
//  Single source of truth for turning a model-supplied path into an absolute
//  filesystem path.
//
//  Why this exists: the file tools historically resolved paths with only
//  `(path as NSString).expandingTildeInPath`, which expands `~` but leaves a
//  RELATIVE path untouched. `URL(fileURLWithPath:)` / `FileManager` then resolve
//  a relative path against the PROCESS working directory — which for a
//  Finder/Xcode-launched macOS app is `/`, the root of the read-only system
//  volume. So a model emitting a natural bare path like `test_data` or
//  `project/index.html` produced `/test_data` → "the volume 'Macintosh HD' is
//  read only", or `/project/index.html` → a misleading "folder doesn't exist".
//  The agent then wrongly concluded the whole filesystem was read-only.
//
//  The execution system prompt already instructs the model to "use absolute
//  paths; user folders are under <home>". This resolver is the safety net for
//  when a small model slips anyway: a relative path anchors to HOME (matching
//  that guidance) instead of the unwritable volume root.
//

import Foundation

enum FilePathResolver {

    /// Resolves a user/model-supplied path to an absolute filesystem path.
    ///
    /// - A leading `~` is expanded.
    /// - An already-absolute path (after expansion) is returned unchanged.
    /// - A relative path is anchored to the user's HOME directory — NOT the
    ///   process working directory (which is the read-only volume root for a
    ///   GUI-launched app). This mirrors the "user folders are under <home>"
    ///   instruction the model receives, so `Desktop/x` → `<home>/Desktop/x`
    ///   and a bare `test_data` → `<home>/test_data`.
    static func resolve(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { return expanded }
        return (NSHomeDirectory() as NSString).appendingPathComponent(expanded)
    }
}

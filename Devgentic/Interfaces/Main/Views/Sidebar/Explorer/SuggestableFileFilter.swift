// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SuggestableFileFilter.swift
//  Devgentic
//
//  The ONE rule for which files the composer's `@` picker offers. Both the full index
//  (`ExplorerViewModel.indexAllFiles`) and the incremental refresh (`fetchAllFiles`)
//  apply it — they used to carry separate copies, and a copy that drifts re-admits
//  build output on the first file-system event.
//
//  ⚠️ This shapes SUGGESTIONS only. The Explorer tree, drag-and-drop and the file
//  picker still reach every file; a binary that arrives that way is refused by
//  `BinaryFileProbe` at attach time instead.
//

import Foundation
import UniformTypeIdentifiers

enum SuggestableFileFilter {

    /// Dependency and build-output folders. Their contents duplicate source names
    /// (`January2026.class` beside `January2026.java`) and sort ahead of them, so the
    /// auto-focused first suggestion was a compiled artifact the send path can't read.
    static let excludedDirectoryNames: Set<String> = [
        ".git", ".build", "node_modules", "Pods", "DerivedData",
        "out", "build", "target", "dist", "__pycache__"
    ]

    /// Compiled, packaged or otherwise non-text artifacts by extension — for types
    /// `UTType` doesn't classify (`.class`, `.o`) or classifies inconsistently.
    static let excludedExtensions: Set<String> = [
        "class", "jar", "war", "ear", "o", "a", "so", "dylib", "dll", "exe", "lib",
        "pyc", "pyo", "wasm", "beam", "rlib", "ko", "bin",
        "sqlite", "sqlite3", "db"
    ]

    /// Whether a FILE (not a folder) is offered, judged by its type alone.
    static func admits(fileURL: URL) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        if excludedExtensions.contains(ext) { return false }
        if let type = UTType(filenameExtension: ext),
           type.conforms(to: .audiovisualContent)
            || type.conforms(to: .archive)
            || type.conforms(to: .diskImage)
            || type.conforms(to: .font) {
            return false
        }
        return true
    }

    /// Whether `url` sits inside an excluded folder BELOW `root`.
    ///
    /// ⚠️ Only components under the root count: a project that itself lives in a folder
    /// named `build` must still be indexed. The incremental refresh needs this because it
    /// enumerates from the changed subfolder, so the enumerator never sees the excluded
    /// ancestor it is already inside.
    static func isInsideExcludedDirectory(_ url: URL, root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else { return false }
        return components.dropFirst(rootComponents.count).contains(where: excludedDirectoryNames.contains)
    }
}

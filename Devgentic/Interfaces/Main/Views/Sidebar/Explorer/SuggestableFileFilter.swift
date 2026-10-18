// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SuggestableFileFilter.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import UniformTypeIdentifiers

/// The one rule for which files the composer's `@` picker offers, applied by both the full index and the
/// incremental refresh. Shapes suggestions only: the Explorer tree, drag-and-drop and the file picker still reach
/// every file, and `BinaryFileProbe` refuses a binary at attach time.
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

    /// Whether `url` sits inside an excluded folder below `root`.
    /// Only components under the root count, so a project that itself lives in a folder named `build` is still indexed.
    /// The incremental refresh needs it: it enumerates from the changed subfolder and never sees the excluded ancestor.
    static func isInsideExcludedDirectory(_ url: URL, root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else { return false }
        return components.dropFirst(rootComponents.count).contains(where: excludedDirectoryNames.contains)
    }
}

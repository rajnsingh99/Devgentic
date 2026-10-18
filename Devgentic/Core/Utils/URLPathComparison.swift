// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  URLPathComparison.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Helpers for deciding whether two file URLs name the same location.
/// `==` is not location equality: it differs by trailing slash and does not resolve symlinks.
extension URL {

    /// True when both URLs name the same filesystem location.
    /// Compares `.path` after resolving symlinks, which drops the trailing-slash distinction; use it instead of `==`.
    /// Touches the filesystem; for paths built from one root, `sameLocationLexically(as:)` does no I/O.
    func sameLocation(as other: URL) -> Bool {
        resolvingSymlinksInPath().path == other.resolvingSymlinksInPath().path
    }

    /// Trailing-slash-insensitive comparison with **no** filesystem access, and therefore no
    /// symlink resolution. Correct when both sides are derived from the same root within the
    /// app's own storage.
    func sameLocationLexically(as other: URL) -> Bool {
        standardizedFileURL.path == other.standardizedFileURL.path
    }
}

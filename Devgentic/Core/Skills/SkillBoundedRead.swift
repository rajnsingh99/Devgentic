// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillBoundedRead.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Reads a file only if it fits a byte limit, refusing rather than truncating so a partial skill is never imported.
/// The `fileSize` stat is only a pre-filter; the post-read check on the bytes actually read is the real bound.
enum SkillBoundedRead {

    /// A file that would not fit the remaining budget. Carries the path so the caller can name it.
    struct Refusal: Error {
        let path: String
        let bytes: Int?
    }

    /// Reads a file's bytes, refusing before the read when the file cannot fit and after it when the
    /// stat lied.
    static func data(at url: URL, limit: Int) throws -> Data {
        let declared = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let declared, declared > limit {
            throw Refusal(path: url.lastPathComponent, bytes: declared)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else {
            throw Refusal(path: url.lastPathComponent, bytes: data.count)
        }
        return data
    }

    /// The same bound for a file read as UTF-8 text. Bounded on UTF-8 bytes, not `String.count`, since the budget is a
    /// storage budget.
    static func text(at url: URL, limit: Int) throws -> String {
        let bytes = try data(at: url, limit: limit)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }
}

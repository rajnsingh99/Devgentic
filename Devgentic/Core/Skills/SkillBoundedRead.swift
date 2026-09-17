// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillBoundedRead.swift
//  Devgentic
//
//  Reading a file only if it fits.
//
//  ## Why this exists
//
//  `SkillIngest` enforced its 30 MB envelope AFTER the walk: every regular file at any depth was
//  read with `Data(contentsOf:)` into memory, and only then were the totals summed and the skill
//  refused. So the cap was reached by first loading whatever the folder actually held.
//
//  The ARCHIVE path was never exposed to this — `SkillArchiveStaging.enforceExtractedSizeBudget`
//  bounds the staged tree at 100 MB and bails on the FIRST breach, before ingest reads anything.
//  The folder and drag-drop path had no equivalent, which is the whole of the gap.
//
//  ⚠️ TWO CHECKS, AND ONLY THE SECOND IS LOAD-BEARING. The `fileSize` stat is a cheap pre-filter
//  whose only job is to avoid starting a read that cannot possibly fit. It is not a defence: a stat
//  can be nil, stale, or beaten by a file still being written. The post-read check on what was
//  ACTUALLY read is the bound. Do not delete the second check on the grounds that the first one
//  already covers it — that is the same reasoning `SkillArchiveStaging` records about trusting an
//  archive's declared sizes.
//
//  ⚠️ REFUSES, NEVER TRUNCATES. `SkillIngest`'s header already commits to rejecting rather than
//  importing a partial skill — "half a skill is worse than a refusal, because it looks complete" —
//  and a silently shortened file is the content-corruption class this codebase has shipped four
//  times.
//

import Foundation

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

    /// The same bound for a file read as UTF-8 text.
    ///
    /// ⚠️ Bounded on UTF-8 BYTES, not `String.count`. The budget is a storage budget, and a
    /// character count would let a multi-byte body pass a byte cap several times over.
    static func text(at url: URL, limit: Int) throws -> String {
        let bytes = try data(at: url, limit: limit)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }
}

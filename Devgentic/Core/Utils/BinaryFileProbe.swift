// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BinaryFileProbe.swift
//  Devgentic
//
//  Content check behind `AttachmentKind.binary`. The send path reads every non-image,
//  non-document attachment as UTF-8 text (`FileProcessorService.readFileContentOrThrow`);
//  a binary (`.class`, `.o`, `.jar`) fails that read and reaches the model as nothing.
//
//  ⚠️ This judges BYTES only. Images and extractable documents are binary too — the type
//  exemptions live in `AttachmentClassifier`, which must be asked instead of this.
//

import Foundation

enum BinaryFileProbe {

    /// Bytes inspected from the head of the file. Enough to catch every common binary
    /// header (class/Mach-O/ELF/zip all carry NULs in the first few dozen bytes).
    static let probeLength = 8192

    /// `true` only on POSITIVE evidence the content is not UTF-8 text.
    ///
    /// ⚠️ Anything that cannot be inspected (missing, unreadable, empty) returns `false`:
    /// the send path's own read reports those with their real cause.
    static func contentLooksBinary(_ url: URL) -> Bool {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: probeLength), !head.isEmpty else { return false }

        return looksBinary(head, isTruncated: head.count == probeLength)
    }

    /// Pure classifier over a file's leading bytes — separated so tests need no files.
    ///
    /// - Parameter isTruncated: the bytes are a prefix of a longer file, so a multi-byte
    ///   UTF-8 sequence may be cut at the end. Up to 3 trailing bytes are then forgiven.
    static func looksBinary(_ head: Data, isTruncated: Bool) -> Bool {
        if head.contains(0) { return true }
        if String(data: head, encoding: .utf8) != nil { return false }
        guard isTruncated else { return true }
        for trim in 1...3 where head.count > trim {
            if String(data: head.dropLast(trim), encoding: .utf8) != nil { return false }
        }
        return true
    }
}

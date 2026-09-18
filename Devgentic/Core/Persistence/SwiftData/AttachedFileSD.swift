// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AttachedFileSD.swift
//  Devgentic
//
//  Created by Raj Singh on 03/04/26.
//  SwiftData models replacing AttachedTextFileEntity and AttachedImageFileEntity (CoreData).
//

import Foundation
import SwiftData

private let logger = DGLogger(category: "AttachedFileSD")

/// Resolves a persisted URL string without ever trapping.
///
/// ⚠️ Both `toStruct()` methods used to do `URL(string: url)!`. That trapped on the READ path —
/// while LOADING A CONVERSATION, with the user's history on screen — not merely rendering badly.
///
/// ⚠️ MEASURED on macOS 26, because the intuition here is wrong: `URL(string:)` returns nil ONLY
/// for the EMPTY string. Spaces, NUL bytes, newlines and control characters all parse, percent-
/// encoded. So the crash surface was exactly one value — but an empty column is precisely what a
/// defaulted or truncated write produces, so it was a real trap, not a theoretical one.
///
/// That leniency creates a second, quieter problem this also fixes: a BARE PATH like `/tmp/x`
/// parses successfully into a SCHEMELESS URL, which is not a usable file URL. `from(_:)` always
/// writes an `absoluteString` (which carries a scheme), so a schemeless value means the row came
/// from somewhere else — a hand-edited store, or a future change that persists raw paths.
///
/// The ladder, in order:
///   1. A parse that yields a SCHEME — the normal `absoluteString` round-trip.
///   2. An existing file at that path — recovered as a proper file URL rather than left schemeless.
///   3. Whatever the lenient parse produced — preserved rather than discarded.
///   4. A placeholder derived from the row id (the empty-string case).
///
/// ⚠️ The placeholder must be UNIQUE PER ROW, not a shared sentinel: `MessagingCoordinator` builds
/// `FileSystemItem(id: $0.url, …)`, so a shared value would collide two attachments into one
/// identity in a SwiftUI list. Deriving it from the row id also keeps it stable across loads.
///
/// Nothing is lost at any rung — `name`, `content` and `binaryData` live in their own columns, so
/// the attachment still renders; only its source path is degraded.
private func resolvePersistedURL(_ raw: String, rowID: UUID, kind: String) -> URL {
    let parsed = URL(string: raw)

    // 1. The normal case.
    if let parsed, parsed.scheme != nil { return parsed }

    // 2. A bare path that actually exists — better as a real file URL than a schemeless one.
    if !raw.isEmpty, raw.hasPrefix("/"), FileManager.default.fileExists(atPath: raw) {
        logger.warning(
            "[DECODE] \(kind) \(rowID.uuidString.prefix(8)): stored url had no scheme but IS an "
            + "existing path — recovered as a file URL. CONSEQUENCE: none; the attachment is intact "
            + "and file operations on it will now work, which they would not have with the "
            + "schemeless value."
        )
        return URL(fileURLWithPath: raw)
    }

    // 3. Schemeless but parseable — keep it. It is still a usable identity, and discarding it
    //    would lose information the row genuinely holds.
    if let parsed {
        logger.warning(
            "[DECODE] \(kind) \(rowID.uuidString.prefix(8)): stored url has no scheme and no file "
            + "exists at that path — kept as-is. CONSEQUENCE: the attachment renders normally, but "
            + "anything treating this as a file URL will not resolve it."
        )
        return parsed
    }

    // 4. Empty. The only value that used to crash.
    logger.error(
        "[DECODE] \(kind) \(rowID.uuidString.prefix(8)): stored url is EMPTY — substituting a "
        + "unique placeholder. CONSEQUENCE: the attachment's name and contents are unaffected and "
        + "still render; only its source path is lost, so revealing it in Finder or re-reading it "
        + "from disk will not work. Previously this trapped and crashed the app while loading the "
        + "conversation."
    )
    // Guaranteed non-nil: the scheme and host are literals and the UUID is hex.
    return URL(string: "devgentic-unresolved://attachment/\(rowID.uuidString)")
        ?? URL(fileURLWithPath: "/dev/null")
}

@Model
final class AttachedTextFileSD {
    @Attribute(.unique) var id: UUID
    var name: String
    var url: String
    var fileExtension: String
    var content: String
    var size: Int64

    func toStruct() -> AttachedTextFile {
        AttachedTextFile(id: id, name: name,
                         url: resolvePersistedURL(url, rowID: id, kind: "AttachedTextFile"),
                         fileExtension: fileExtension, content: content, size: size)
    }

    static func from(_ file: AttachedTextFile) -> AttachedTextFileSD {
        AttachedTextFileSD(id: file.id, name: file.name, url: file.url.absoluteString,
                           fileExtension: file.fileExtension, content: file.content, size: file.size)
    }

    init(id: UUID, name: String, url: String, fileExtension: String, content: String, size: Int64) {
        self.id = id; self.name = name; self.url = url
        self.fileExtension = fileExtension; self.content = content; self.size = size
    }
}

@Model
final class AttachedImageFileSD {
    @Attribute(.unique) var id: UUID
    var name: String
    var url: String
    var fileExtension: String
    /// The transcript's durable copy of the image — `AttachedImageCardView` renders
    /// from these bytes because the source `url` goes stale (moved/deleted files,
    /// sandbox scope not surviving relaunch). `.externalStorage` keeps the blob out
    /// of the SQLite row (sidecar file, managed by the store) so fetching messages
    /// doesn't drag megabytes of pixels through the row cache. Storage-option-only
    /// change: lightweight migration; existing inline blobs remain readable.
    @Attribute(.externalStorage) var binaryData: Data
    var size: Int64

    func toStruct() -> AttachedImageFile {
        AttachedImageFile(id: id, name: name,
                          url: resolvePersistedURL(url, rowID: id, kind: "AttachedImageFile"),
                          fileExtension: fileExtension, binaryData: binaryData, size: size)
    }

    /// [mm-4] The struct WITHOUT its bytes. `binaryData` is the schema's only
    /// `@Attribute(.externalStorage)` field and the ONE property this method never reads, so
    /// the sidecar file is never faulted in — for consumers that need the name and size only
    /// (the conversation export lists images by name and size and never embeds them). `size`
    /// is the byte count recorded at attach time, which is what `ConversationExporter.
    /// imageByteCount` falls back to when `binaryData` is empty.
    ///
    /// The "never faulted in" part is MEASURED, not assumed (2026-09-12, standalone SwiftData
    /// probe, on-disk store, 40 rows × 2 MB, fresh process): fetching all rows and reading
    /// `name`/`size` only took ~1 ms; reading `data.count` took ~9 ms and the store had written
    /// 40 sidecar files. SwiftData loads an external-storage blob on ATTRIBUTE access, not when
    /// the object fault fires. The unit test can only pin the struct's shape (it runs in-memory,
    /// where there is no sidecar), which is why the number lives here.
    func toStructOmittingBytes() -> AttachedImageFile {
        AttachedImageFile(id: id, name: name,
                          url: resolvePersistedURL(url, rowID: id, kind: "AttachedImageFile"),
                          fileExtension: fileExtension, binaryData: Data(), size: size)
    }

    static func from(_ file: AttachedImageFile) -> AttachedImageFileSD {
        AttachedImageFileSD(id: file.id, name: file.name, url: file.url.absoluteString,
                            fileExtension: file.fileExtension, binaryData: file.binaryData, size: file.size)
    }

    init(id: UUID, name: String, url: String, fileExtension: String, binaryData: Data, size: Int64) {
        self.id = id; self.name = name; self.url = url
        self.fileExtension = fileExtension; self.binaryData = binaryData; self.size = size
    }
}

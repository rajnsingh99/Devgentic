// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AttachedFileSD.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData

private let logger = DGLogger(category: "AttachedFileSD")

// Why: the placeholder must be unique per row (the id feeds `FileSystemItem(id:)`), or two attachments collide in a list.
/// Resolves a persisted URL string without ever trapping.
/// `URL(string:)` returns nil only for the empty string, and a schemeless bare path parses but is not a usable file URL.
/// Ladder: a parse with a scheme, an existing file at that path, the lenient parse, else a row-id placeholder.
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

    // Empty: the one value `URL(string:)` rejects.
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

/// SwiftData models for attached text and image files.
@Model
final class AttachedTextFileSD {
    @Attribute(.unique) var id: UUID
    var name: String
    var url: String
    var fileExtension: String
    var content: String
    var size: Int64
    /// `AttachmentDelivery`, flattened — see its `storage` / `init(kind:sent:total:)`, the only
    /// codec. Optional columns: a lightweight addition; rows written before it read as nil.
    var deliveryKind: String?
    var deliverySentChars: Int?
    var deliveryTotalChars: Int?

    func toStruct() -> AttachedTextFile {
        AttachedTextFile(id: id, name: name,
                         url: resolvePersistedURL(url, rowID: id, kind: "AttachedTextFile"),
                         fileExtension: fileExtension, content: content, size: size,
                         delivery: AttachmentDelivery(kind: deliveryKind, sent: deliverySentChars, total: deliveryTotalChars))
    }

    static func from(_ file: AttachedTextFile) -> AttachedTextFileSD {
        let row = AttachedTextFileSD(id: file.id, name: file.name, url: file.url.absoluteString,
                                     fileExtension: file.fileExtension, content: file.content, size: file.size)
        if let stored = file.delivery?.storage {
            row.deliveryKind = stored.kind
            row.deliverySentChars = stored.sent
            row.deliveryTotalChars = stored.total
        }
        return row
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
    /// The durable copy of the image: `AttachedImageCardView` renders from these bytes because the source `url` goes stale.
    /// `.externalStorage` keeps the blob out of the SQLite row so fetching messages does not load the pixels.
    @Attribute(.externalStorage) var binaryData: Data
    var size: Int64

    func toStruct() -> AttachedImageFile {
        AttachedImageFile(id: id, name: name,
                          url: resolvePersistedURL(url, rowID: id, kind: "AttachedImageFile"),
                          fileExtension: fileExtension, binaryData: binaryData, size: size)
    }

    // Why: SwiftData loads an external-storage blob on attribute access, so reading `binaryData` would fault in sidecar files.
    /// Returns the struct without its bytes; `binaryData` is never read, so its external-storage sidecar is never loaded.
    /// For consumers that need name and size only; `size` is the byte count recorded at attach time.
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

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ImageExport.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import AppKit
import UniformTypeIdentifiers
import os

private let logger = DGLogger(category: "ImageExport")

/// One place to save or copy a chat image, shared by the image renderers.
/// Names files from the payload's real image type, sniffed from its bytes.
enum ImageExport {

    enum SaveError: LocalizedError {
        case noDownloadsDirectory
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDownloadsDirectory:
                return String(localized: "Couldn't find your Downloads folder.")
            case .writeFailed(let reason):
                return reason
            }
        }
    }

    /// The type of an image payload, read from the bytes themselves rather than the declared mimeType,
    /// which a provider may mislabel.
    static func fileExtension(for data: Data, declaredMimeType: String? = nil) -> String {
        if let sniffed = sniffExtension(data) { return sniffed }
        if let mime = declaredMimeType,
           let type = UTType(mimeType: mime),
           let ext = type.preferredFilenameExtension {
            return ext
        }
        return "png"
    }

    /// Magic-number sniffing for the formats these backends actually return.
    private static func sniffExtension(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 4 else { return nil }

        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if bytes.count >= 12, bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if bytes.starts(with: [0x42, 0x4D]) { return "bmp" }
        // TIFF, either byte order.
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        return nil
    }

    /// Writes the ORIGINAL payload — no re-encode, so nothing is recompressed and the
    /// extension matches the bytes. Returns the URL actually written.
    @discardableResult
    static func saveToDownloads(
        data: Data,
        declaredMimeType: String? = nil,
        baseName: String
    ) throws -> URL {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            // Force-unwrapping this crashed the app in a sandbox or on an account with no
            // Downloads folder, for something as minor as saving a picture.
            logger.error("❌ No Downloads directory available.")
            throw SaveError.noDownloadsDirectory
        }

        let ext = fileExtension(for: data, declaredMimeType: declaredMimeType)
        let url = uniqueURL(in: downloads, baseName: baseName, ext: ext)
        do {
            try data.write(to: url)
            logger.info("✅ Saved image to \(url.path)")
            return url
        } catch {
            logger.error("❌ Failed to save image to \(url.path): \(error.localizedDescription)")
            throw SaveError.writeFailed(error.localizedDescription)
        }
    }

    /// Never silently clobber a file the user already has.
    private static func uniqueURL(in directory: URL, baseName: String, ext: String) -> URL {
        let first = directory.appendingPathComponent("\(baseName).\(ext)")
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        for n in 2...999 {
            let candidate = directory.appendingPathComponent("\(baseName)-\(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(baseName)-\(UUID().uuidString.prefix(6)).\(ext)")
    }

    /// Save panel variant, for renderers that ask the user where to put it.
    static func savePanel(baseName: String, data: Data, declaredMimeType: String? = nil) -> NSSavePanel {
        let ext = fileExtension(for: data, declaredMimeType: declaredMimeType)
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(baseName).\(ext)"
        return panel
    }

    // Why: `writeObjects` can fail after `clearContents()` emptied the clipboard, so success must not be assumed.
    /// Puts an image on the general pasteboard. Returns whether it actually landed.
    /// Callers showing a "Copied" affordance should key it off the result.
    @discardableResult
    static func copyToPasteboard(_ image: NSImage) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([image]) else {
            logger.error("[MEDIA] Image copy FAILED — the pasteboard refused the image. CONSEQUENCE: the clipboard was already cleared, so it now holds NOTHING; the caller must not report success.")
            return false
        }
        logger.info("✅ Image copied to clipboard.")
        return true
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AttachmentClassifier.swift
//  Devgentic
//
//  The ONE answer to "what kind of attachment is this file?". Every site that branches on
//  it asks here:
//    • `AttachmentIntake`          — accept or refuse at attach time
//    • `MessageAttachmentBuilder`  — what the TRANSCRIPT records
//    • `BackendOrchestrationService` — what the MODEL receives (image payload vs text)
//    • `RAGIndexingService`         — what later turns can retrieve
//    • `PreSendFitHint`             — what the context GAUGE prices, and how
//
//  ⚠️ Why one owner (ATT-1): these sites each carried their own classifier and disagreed.
//  The transcript checked "text" before "image" while the backend checked "image" first, so
//  an `.svg` (image/svg+xml — on the text list AND an image UTType) was recorded as text
//  but shipped as an image. Extension-less files once fell through the transcript's
//  classifiers entirely. A new type rule added here reaches all five sites at once.
//

import Foundation
import UniformTypeIdentifiers

enum AttachmentKind: String, Equatable, Sendable {
    /// Sent natively to vision models (`buildImagePayload`); recorded as an image.
    case image
    /// Rich document the extraction registry turns into text (PDF, DOCX, XLSX…).
    case document
    /// Read as UTF-8 and injected. Also the kind for anything not positively known to be
    /// otherwise — including a missing file, whose read reports the real cause.
    case text
    /// No send path expands a folder (ATT-3); only the stateless manifest can hand its path on.
    case folder
    /// Video/movie — no send path carries it.
    case video
    /// Content is not UTF-8 text (`.class`, `.o`, archives): every text read fails for it.
    case binary
}

enum AttachmentClassifier {

    static func classify(_ item: FileSystemItem) -> AttachmentKind {
        item.isDirectory ? .folder : classify(item.url)
    }

    /// Order matters and mirrors delivery: image beats every text rule (the backend sends an
    /// image natively even when its MIME is XML-based), and a type-known document is never
    /// content-probed (a PDF is binary by bytes but extractable by design).
    static func classify(_ url: URL) -> AttachmentKind {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .folder
        }

        let processor = FileProcessorService()
        if processor.isImageFile(mimeType: processor.getFileMimeType(for: url), url: url) {
            return .image
        }
        if let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .movie) || type.conforms(to: .video) {
            return .video
        }
        if DocumentExtractionRegistry.shared.canExtract(from: url) {
            return .document
        }
        return BinaryFileProbe.contentLooksBinary(url) ? .binary : .text
    }
}

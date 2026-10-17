// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MessageAttachmentBuilder.swift
//  Devgentic
//
//  Builds the persisted attachment records for an outgoing user message.
//  Extracted from `MessagingCoordinator.createUserMessage` so the transcript
//  side of the attachment contract is unit-testable — the coordinator itself
//  needs the full VM graph and can't be constructed in tests.
//
//  CONTRACT (ATT-1): the backend's direct-injection path
//  (`BackendOrchestrationService.assembleTextFileContent`) reads EVERY
//  non-image attachment, so everything that isn't an image must be recorded
//  on the message too — otherwise the transcript lies about what the model
//  received. Classification is `AttachmentClassifier` — shared with the backend
//  and RAG indexing — so the three sites cannot disagree about a file's kind.
//

import Foundation

@MainActor
struct MessageAttachmentBuilder {

    private let fileProcessorService: FileProcessorService
    private let logger = DGLogger(category: "MessageAttachmentBuilder")

    init(fileProcessorService: FileProcessorService) {
        self.fileProcessorService = fileProcessorService
    }

    /// Classifies each picked file and reads it into the attachment record the
    /// persisted `ChatMessage` will carry. Files that can't be represented are
    /// logged — a silent drop here is what made the transcript diverge from the
    /// model input (ATT-1).
    ///
    /// - Parameter deliveryMode: the profile's `AttachmentDeliveryMode`. When given, each text
    ///   file records what the model will receive (`AttachedTextFile.delivery`) by running the
    ///   backend's own `DirectInjectionPlan`. nil records no delivery (a sender with no files).
    func build(from files: [FileSystemItem], deliveryMode: AttachmentDeliveryMode? = nil) async -> (textFiles: [AttachedTextFile], imageFiles: [AttachedImageFile]) {
        var textFiles: [AttachedTextFile] = []
        var imageFiles: [AttachedImageFile] = []

        for fileItem in files {
            let fileExtension = fileItem.url.pathExtension
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileItem.url.path)
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

            // ⚠️ The SAME classifier the backend uses to decide what the model receives —
            // a private classifier here is exactly how the transcript drifted (ATT-1, and
            // `.svg` recorded as text while it shipped as an image).
            let kind = AttachmentClassifier.classify(fileItem)
            switch kind {
            case .text, .document:
                // Extension-less files (Makefile, LICENSE, .env) classify as `.text` by their
                // content, so they need no fallback branch any more.
                // The backend's reader at the backend's cap — so a file is recorded here exactly
                // when `assembleTextFileContent` reads it, which the delivery plan below needs.
                if let content = try? await fileProcessorService.readFileContentOrThrow(for: fileItem.url, maxSize: DirectInjectionBudget.readCap) {
                    let textFile = AttachedTextFile(name: fileItem.name, url: fileItem.url, fileExtension: fileExtension, content: content, size: fileSize)
                    textFiles.append(textFile)
                } else {
                    // readFileContent logged the cause; state the CONSEQUENCE here.
                    logger.warning("\(kind.rawValue.capitalized) attachment '\(fileItem.name)' couldn't be read — it will be missing from the transcript; the backend read will surface its own failure notice.")
                }

            case .image:
                // [M7] Reject an oversized image BEFORE reading it into memory. Fan-in safety net
                // for every sender (main / QuickAccess / Scheduler), redo, and any file that grew
                // since it was picked; interactive attaches are refused earlier by AttachmentIntake.
                // `fileSize` was already stat'd above, so a huge file is never read.
                guard fileSize <= ImageConstraints.maxAttachmentImageBytes else {
                    logger.warning("Skipping oversized image attachment '\(fileItem.name)' — \(fileSize) bytes exceeds the \(ImageConstraints.maxAttachmentImageBytes)-byte cap.")
                    continue
                }
                do {
                    _ = fileItem.url.startAccessingSecurityScopedResource()
                    let data = try Data(contentsOf: fileItem.url)
                    fileItem.url.stopAccessingSecurityScopedResource()
                    let imageFile = AttachedImageFile(name: fileItem.name, url: fileItem.url, fileExtension: fileExtension, binaryData: data, size: fileSize)
                    imageFiles.append(imageFile)
                } catch {
                    logger.error("Could not read image data for file: \(fileItem.name)")
                }

            case .folder:
                // ATT-3 (known, deferred): no send path expands a folder; direct injection
                // fails to read it. Log the drop so it's traceable instead of invisible.
                logger.warning("Folder attachment '\(fileItem.name)' isn't supported by the send pipeline — not persisted; the backend will surface a read failure for it.")

            case .binary, .video:
                // AttachmentIntake refuses these at attach time; one can still arrive from a
                // non-interactive sender or a file rewritten since it was attached. The backend's
                // read fails for it too, so transcript and model input still agree.
                logger.warning("Attachment '\(fileItem.name)' is \(kind.rawValue) content no send path can carry — omitted from the transcript; the backend will surface its own failure notice.")
            }
        }

        if let deliveryMode {
            textFiles = Self.recordingDelivery(on: textFiles, mode: deliveryMode)
        }
        return (textFiles, imageFiles)
    }

    /// Stamps each text file with what the model receives. ⚠️ Runs `DirectInjectionPlan` — the
    /// backend's assembler — over the same files in the same order, so the transcript can no
    /// longer imply the model saw content it didn't (it used to store a 120K file whole while
    /// the model received none of it). Images aren't in `textFiles`; the backend skips them too.
    static func recordingDelivery(on textFiles: [AttachedTextFile], mode: AttachmentDeliveryMode) -> [AttachedTextFile] {
        let deliveries: [AttachmentDelivery]
        switch mode {
        case .pathManifest:
            deliveries = Array(repeating: .pathOnly, count: textFiles.count)
        case .inject(let includeAbsolutePaths):
            deliveries = DirectInjectionPlan.assemble(
                textFiles.map { .init(name: $0.name, path: $0.url.path, content: $0.content) },
                includeAbsolutePaths: includeAbsolutePaths
            ).deliveries
        }
        return zip(textFiles, deliveries).map { file, delivery in
            var stamped = file
            stamped.delivery = delivery
            return stamped
        }
    }
}

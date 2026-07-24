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
//  received. Both type classifiers are keyed entirely off the path extension,
//  so extension-less files (Makefile, LICENSE, Dockerfile, .env — their
//  `pathExtension` is "") match neither and need the read-probe fallback.
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
    func build(from files: [FileSystemItem]) async -> (textFiles: [AttachedTextFile], imageFiles: [AttachedImageFile]) {
        var textFiles: [AttachedTextFile] = []
        var imageFiles: [AttachedImageFile] = []

        for fileItem in files {
            let mimeType = fileProcessorService.getFileMimeType(for: fileItem.url)
            let fileExtension = fileItem.url.pathExtension
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileItem.url.path)
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

            if fileProcessorService.isTextFile(mimeType: mimeType, url: fileItem.url) {
                if let content = await fileProcessorService.readFileContent(for: fileItem.url) {
                    let textFile = AttachedTextFile(name: fileItem.name, url: fileItem.url, fileExtension: fileExtension, content: content, size: fileSize)
                    textFiles.append(textFile)
                } else {
                    // readFileContent logged the cause; state the CONSEQUENCE here —
                    // this drop was previously silent, and a missing record is the
                    // exact divergence class ATT-1 is about.
                    logger.warning("Text attachment '\(fileItem.name)' couldn't be read — it will be missing from the transcript; the backend read will surface its own failure notice.")
                }
            } else if fileProcessorService.isImageFile(mimeType: mimeType, url: fileItem.url) {
                // [M7] Reject an oversized image BEFORE reading it into memory. Fan-in safety net
                // for every sender (main / ChatOps / QuickAccess / Scheduler), redo, and any file
                // that grew since it was picked; interactive attaches are also warned at the picker.
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
            } else if fileItem.isDirectory {
                // ATT-3 (known, deferred): folders are offered by the picker but the
                // send pipeline never expands them — the backend read fails for them
                // too. Log the drop so it's traceable instead of invisible.
                logger.warning("Folder attachment '\(fileItem.name)' isn't supported by the send pipeline — not persisted; the backend will surface a read failure for it.")
            } else {
                // ATT-1 fallback: no classifier matched. Both classifiers are keyed
                // off the path extension, so extension-less files (Makefile, LICENSE,
                // Dockerfile, .env — `pathExtension` is "") land here even though the
                // backend's direct-injection path reads and sends them (it skips only
                // images). Mirror the backend: persist anything that reads as UTF-8
                // text so the transcript records what the model actually received.
                // A genuinely binary file fails the same UTF-8 read on both sides,
                // so transcript and model input still agree when this probe fails.
                if let content = await fileProcessorService.readFileContent(for: fileItem.url) {
                    logger.log("Attachment '\(fileItem.name)' (mime: \(mimeType)) matched no type classifier; persisted as text — the backend injects every non-image attachment (ATT-1 fallback).")
                    let textFile = AttachedTextFile(name: fileItem.name, url: fileItem.url, fileExtension: fileExtension, content: content, size: fileSize)
                    textFiles.append(textFile)
                } else {
                    logger.warning("Attachment '\(fileItem.name)' (mime: \(mimeType)) matched no classifier and isn't readable as text — omitted from the transcript; the backend will surface its own failure notice.")
                }
            }
        }

        return (textFiles, imageFiles)
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MessageAttachmentBuilderTests.swift
//  DevgenticTests
//
//  ATT-1 (chat hardening round 3, 2026-07-19): the transcript and the backend
//  disagreed about attachments. `createUserMessage` persisted a file only if it
//  classified as text or image — both checks are keyed entirely off the path
//  extension — while the backend's direct-injection path reads every non-image
//  attachment. An extension-less file (Makefile, LICENSE, Dockerfile, .env) was
//  therefore SENT TO THE MODEL but recorded nowhere: no chip, no persisted row,
//  no export entry, no warning. `MessageAttachmentBuilder` (extracted from the
//  coordinator so this contract is testable) must mirror the backend: anything
//  that isn't an image is persisted as a text attachment if it reads as UTF-8.
//
//  `RAGEligibilityTests` pins the same contract at the second divergent site:
//  `RAGIndexingService.indexAttachedFiles` skipped the same files from turn-2+
//  retrieval while the model had seen them on turn 1.
//

import XCTest
@testable import devgentic

@MainActor
final class MessageAttachmentBuilderTests: XCTestCase {

    private var tempDir: URL!
    private var builder: MessageAttachmentBuilder!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageAttachmentBuilderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        builder = MessageAttachmentBuilder(fileProcessorService: FileProcessorService())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func write(_ name: String, data: Data) throws -> FileSystemItem {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return FileSystemItem(id: url, name: name, url: url, isDirectory: false)
    }

    private func write(_ name: String, text: String) throws -> FileSystemItem {
        try write(name, data: Data(text.utf8))
    }

    // MARK: - ATT-1: extension-less UTF-8 files must be persisted

    func testMakefileIsPersistedAsTextAttachment() async throws {
        let makefile = "build:\n\tswift build\n"
        let item = try write("Makefile", text: makefile)

        let result = await builder.build(from: [item])

        XCTAssertEqual(result.textFiles.count, 1,
                       "An extension-less UTF-8 file is injected into the model request (the backend skips only images), so it must be recorded on the message too (ATT-1).")
        XCTAssertEqual(result.textFiles.first?.content, makefile, "Full content must round-trip into the persisted record.")
        XCTAssertEqual(result.textFiles.first?.name, "Makefile")
        XCTAssertEqual(result.textFiles.first?.fileExtension, "")
        XCTAssertTrue(result.imageFiles.isEmpty)
    }

    func testDotEnvIsPersistedAsTextAttachment() async throws {
        let item = try write(".env", text: "API_KEY=secret123\n")

        let result = await builder.build(from: [item])

        XCTAssertEqual(result.textFiles.count, 1,
                       "A leading-dot file has an empty pathExtension; its content reaches the model, so it must reach the transcript too (ATT-1 — this is the secrets-leave-no-trace case).")
    }

    func testMixedBatchClassifiesEveryFile() async throws {
        let makefile = try write("Makefile", text: "all: build\n")
        let swiftFile = try write("main.swift", text: "print(1)\n")
        // Classifiers are extension-keyed only, so junk bytes with a .png name
        // exercise the image path without needing a real encoder.
        let image = try write("pixel.png", data: Data([0x89, 0x50, 0x4E, 0x47]))

        let result = await builder.build(from: [makefile, swiftFile, image])

        XCTAssertEqual(result.textFiles.map(\.name).sorted(), ["Makefile", "main.swift"],
                       "The extension-less file must be persisted alongside the classified one — the backend injects both.")
        XCTAssertEqual(result.imageFiles.map(\.name), ["pixel.png"])
    }

    // MARK: - Controls (prove the harness CAN reject — a broken harness otherwise reads as a pass)

    func testBinaryExtensionlessFileIsNotPersisted() async throws {
        // 0x81/0xFF/0xC0 are never valid UTF-8 (continuation-without-lead / invalid bytes).
        let item = try write("blob", data: Data([0x81, 0xFF, 0xC0, 0x00, 0x81]))

        let result = await builder.build(from: [item])

        XCTAssertTrue(result.textFiles.isEmpty,
                      "A genuinely binary file must NOT be laundered into a text attachment — the backend's UTF-8 read fails for it too, so transcript and model input still agree.")
        XCTAssertTrue(result.imageFiles.isEmpty)
    }

    func testDirectoryProducesNoAttachment() async throws {
        let dirURL = tempDir.appendingPathComponent("SomeFolder")
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let item = FileSystemItem(id: dirURL, name: "SomeFolder", url: dirURL, isDirectory: true)

        let result = await builder.build(from: [item])

        XCTAssertTrue(result.textFiles.isEmpty, "Folders are unsupported by the send pipeline (known ATT-3) — they must not become attachments.")
        XCTAssertTrue(result.imageFiles.isEmpty)
    }

    // MARK: - Regression pins for the pre-existing branches

    func testRecognizedTextExtensionStillPersists() async throws {
        let item = try write("notes.txt", text: "hello\n")

        let result = await builder.build(from: [item])

        XCTAssertEqual(result.textFiles.count, 1)
        XCTAssertEqual(result.textFiles.first?.fileExtension, "txt")
    }

    func testImageGoesToImageArrayNotText() async throws {
        let item = try write("photo.jpg", data: Data([0xFF, 0xD8, 0xFF, 0xE0]))

        let result = await builder.build(from: [item])

        XCTAssertEqual(result.imageFiles.count, 1)
        XCTAssertTrue(result.textFiles.isEmpty, "An image must never fall through to the text fallback.")
    }

    func testTextClassifiedButUnreadableFileIsDroppedNotCrashed() async throws {
        // .txt classifies as text, but the bytes aren't valid UTF-8 — the read
        // returns nil and the file is skipped (now with a log, previously silent).
        let item = try write("bad.txt", data: Data([0x81, 0xFF, 0xC0]))

        let result = await builder.build(from: [item])

        XCTAssertTrue(result.textFiles.isEmpty)
        XCTAssertTrue(result.imageFiles.isEmpty)
    }
}

/// Pins `RAGIndexingService.isRAGEligible` — the second site where classification
/// must agree with what the backend injects. Pure decision, no embedding stack.
final class RAGEligibilityTests: XCTestCase {

    private var tempDir: URL!
    private let fileProcessor = FileProcessorService()

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RAGEligibilityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func item(_ name: String, data: Data = Data("x".utf8), isDirectory: Bool = false) throws -> FileSystemItem {
        let url = tempDir.appendingPathComponent(name)
        if isDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try data.write(to: url)
        }
        return FileSystemItem(id: url, name: name, url: url, isDirectory: isDirectory)
    }

    func testMakefileIsEligible() throws {
        // ATT-1: the model saw this file on turn 1 (backend skips only images),
        // so turn-2+ retrieval must be able to find it.
        XCTAssertTrue(RAGIndexingService.isRAGEligible(try item("Makefile"), fileProcessor: fileProcessor))
    }

    func testUnknownExtensionIsEligible() throws {
        // Same rule as the backend: attempt everything non-image; the read probe
        // (not the extension) decides readability at index time.
        XCTAssertTrue(RAGIndexingService.isRAGEligible(try item("data.xyz"), fileProcessor: fileProcessor))
    }

    func testImageIsNotEligible() throws {
        XCTAssertFalse(RAGIndexingService.isRAGEligible(try item("pixel.png"), fileProcessor: fileProcessor))
    }

    func testDirectoryIsNotEligible() throws {
        XCTAssertFalse(RAGIndexingService.isRAGEligible(try item("SomeFolder", isDirectory: true), fileProcessor: fileProcessor))
    }

    func testPlainTextIsEligible() throws {
        XCTAssertTrue(RAGIndexingService.isRAGEligible(try item("notes.txt"), fileProcessor: fileProcessor))
    }

    func testDocxIsEligible() throws {
        XCTAssertTrue(RAGIndexingService.isRAGEligible(try item("report.docx"), fileProcessor: fileProcessor))
    }
}

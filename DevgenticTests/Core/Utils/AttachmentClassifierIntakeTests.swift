// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AttachmentClassifierIntakeTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class AttachmentClassifierIntakeTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("AttachIntake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func file(_ name: String, _ data: Data) throws -> FileSystemItem {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return FileSystemItem(id: url, name: name, url: url, isDirectory: false)
    }

    private func folder(_ name: String) throws -> FileSystemItem {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return FileSystemItem(id: url, name: name, url: url, isDirectory: true)
    }

    private let classBytes = Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x41])
    private let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>"#.utf8)

    // MARK: - Classifier

    func testKinds() throws {
        XCTAssertEqual(AttachmentClassifier.classify(try file("Main.java", Data("class Main {}".utf8))), .text)
        XCTAssertEqual(AttachmentClassifier.classify(try file("Makefile", Data("all:\n".utf8))), .text,
                       "extension-less text is text by content")
        XCTAssertEqual(AttachmentClassifier.classify(try file("January2026.class", classBytes)), .binary)
        XCTAssertEqual(AttachmentClassifier.classify(try file("photo.png", Data([0x89, 0x50, 0x4E, 0x47]))), .image)
        XCTAssertEqual(AttachmentClassifier.classify(try file("clip.mov", Data([0x00, 0x01]))), .video)
        XCTAssertEqual(AttachmentClassifier.classify(try file("spec.pdf", Data("%PDF-1.4".utf8))), .document)
        XCTAssertEqual(AttachmentClassifier.classify(try folder("src")), .folder)
    }

    /// A folder passed as a URL (no FileSystemItem flag) is still a folder.
    func testFolderByURL() throws {
        XCTAssertEqual(AttachmentClassifier.classify(try folder("src").url), .folder)
    }

    /// The divergence this owner fixed: `.svg` is image/svg+xml — on the old transcript's
    /// TEXT list and an image UTType — so the transcript said text while the backend sent an image.
    func testSVGIsAnImage() throws {
        XCTAssertEqual(AttachmentClassifier.classify(try file("logo.svg", svg)), .image)
    }

    /// A missing file is `.text` so the send path's read reports `notFound` with its real cause.
    func testMissingFileIsLeftToTheSendPath() {
        XCTAssertEqual(AttachmentClassifier.classify(dir.appendingPathComponent("ghost.txt")), .text)
    }

    // MARK: - Intake

    func testIntakeRefusesWhatNoSendPathCarries() throws {
        let binary = try file("January2026.class", classBytes)
        let video = try file("clip.mov", Data([0x00, 0x01]))
        let source = try file("Main.java", Data("class Main {}".utf8))
        let src = try folder("src")

        let (accepted, refused) = AttachmentIntake.partition([binary, video, source, src])

        XCTAssertEqual(accepted.map(\.name), ["Main.java", "src"],
                       "folders are accepted — the stateless strategy hands their path to an agent")
        XCTAssertEqual(refused.map(\.item.name), ["January2026.class", "clip.mov"])
    }

    /// ATT-3: a folder is refused only where the profile sends CONTENTS. A stateless agent gets
    /// its path and can list it; an unknown profile defers to the send path's `.isFolder`.
    func testFolderVerdictFollowsTheDeliveryMode() throws {
        let src = try folder("src")
        if case .refuse(let reason) = AttachmentIntake.evaluate(src, deliveryMode: .inject(includeAbsolutePaths: false)) {
            XCTAssertTrue(reason.contains("folder"), reason)
        } else {
            XCTFail("an injecting profile must refuse a folder")
        }
        XCTAssertNotEqual(AttachmentIntake.evaluate(src, deliveryMode: .inject(includeAbsolutePaths: true)), .accept(.folder))
        XCTAssertEqual(AttachmentIntake.evaluate(src, deliveryMode: .pathManifest), .accept(.folder))
        XCTAssertEqual(AttachmentIntake.evaluate(src), .accept(.folder))
    }

    func testIntakeRefusesAnOversizedImage() throws {
        let big = try file("huge.png", Data(count: Int(ImageConstraints.maxAttachmentImageBytes) + 1))
        let small = try file("small.png", Data([0x89, 0x50, 0x4E, 0x47]))

        let (accepted, refused) = AttachmentIntake.partition([big, small])

        XCTAssertEqual(accepted.map(\.name), ["small.png"])
        XCTAssertEqual(refused.map(\.item.name), ["huge.png"])
    }

    func testSummaryNamesEveryRefusedFile() throws {
        let (_, refused) = AttachmentIntake.partition([try file("a.class", classBytes), try file("b.o", classBytes)])
        let summary = try XCTUnwrap(AttachmentIntake.summary(refused))
        XCTAssertTrue(summary.contains("'a.class'") && summary.contains("'b.o'"), summary)
        XCTAssertNil(AttachmentIntake.summary([]))
    }

    func testRemovedSummaryIsWordedAsARemoval() throws {
        let (_, refused) = AttachmentIntake.partition([try folder("java")], deliveryMode: .inject(includeAbsolutePaths: false))
        XCTAssertTrue(try XCTUnwrap(AttachmentIntake.summary(refused, removed: true)).hasPrefix("Removed from this message: 'java'"))
        XCTAssertTrue(try XCTUnwrap(AttachmentIntake.summary(refused)).hasPrefix("Not attached: 'java'"))
    }

    // MARK: - Agreement (the reason the classifier is shared)

    /// The transcript must record an SVG the way the backend delivers it: as an image.
    func testTranscriptRecordsSVGAsImage() async throws {
        let item = try file("logo.svg", svg)

        let result = await MessageAttachmentBuilder(fileProcessorService: FileProcessorService()).build(from: [item])

        XCTAssertEqual(result.imageFiles.map(\.name), ["logo.svg"])
        XCTAssertTrue(result.textFiles.isEmpty, "recorded as text while the model got an image — the ATT-1 drift")
    }

    /// RAG indexes only what reached the model as text.
    func testRAGEligibilityFollowsTheClassifier() throws {
        let processor = FileProcessorService()
        XCTAssertTrue(RAGIndexingService.isRAGEligible(try file("Main.java", Data("class Main {}".utf8)), fileProcessor: processor))
        XCTAssertFalse(RAGIndexingService.isRAGEligible(try file("January2026.class", classBytes), fileProcessor: processor),
                       "a binary has no text to chunk")
        XCTAssertFalse(RAGIndexingService.isRAGEligible(try file("logo.svg", svg), fileProcessor: processor))
    }
}

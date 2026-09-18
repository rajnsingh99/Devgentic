// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowInputAssemblerDocumentTests.swift
//  DevgenticTests
//
//  Pins the 2026-08-15 user decision (WF-OB3): document artifacts are inlined IN FULL — the
//  4000-char total budget, the per-document split, the silent `break` past budget, and the
//  "too large" mis-report for an over-share plain-text file are all retired. Fitting the result
//  is the downstream model's context window, the author's responsibility — the same decision
//  that made node TEXT unbounded on 2026-08-13.
//
//  ⚠️ These construct `.document` MediaArtifacts DIRECTLY. No production code creates one yet
//  (every producer in the app emits `.image`), so this function is scaffolding for a future
//  document-producing tool — these tests are what keep the scaffolding matching the decision
//  until that producer lands.
//

import XCTest
@testable import devgentic

final class WorkflowInputAssemblerDocumentTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-doc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeDoc(_ name: String, characters: Int) throws -> MediaArtifact {
        let url = tempDir.appendingPathComponent(name)
        // Distinct head/tail markers so truncation at EITHER end is detectable.
        let body = "HEAD-\(name) " + String(repeating: "x", count: max(0, characters - 30)) + " TAIL-\(name)"
        try body.write(to: url, atomically: true, encoding: .utf8)
        return MediaArtifact(kind: .document, reference: .diskPath(url), mimeType: "text/plain", label: name)
    }

    /// ⚠️ THE DECISION, pinned. Three documents totalling ~9000 chars — more than double the
    /// retired 4000 budget, each over the retired 500 floor share. Under the old code the third
    /// document was silently DROPPED by the budget `break` and the survivors were clipped; every
    /// document must now arrive whole, head and tail included.
    func testAllDocumentsAreInlinedInFull() async throws {
        let docs = [
            try writeDoc("first.txt", characters: 3000),
            try writeDoc("second.txt", characters: 3000),
            try writeDoc("third.txt", characters: 3000),
        ]

        let (text, failures) = await WorkflowInputAssembler.extractDocumentText(
            from: docs, fileProcessor: FileProcessorService())

        XCTAssertTrue(failures.isEmpty, "nothing failed — got: \(failures)")
        for name in ["first.txt", "second.txt", "third.txt"] {
            XCTAssertTrue(text.contains("--- \(name) ---"), "\(name) must have its section header")
            XCTAssertTrue(text.contains("HEAD-\(name)"), "\(name)'s start must survive")
            XCTAssertTrue(text.contains("TAIL-\(name)"), "\(name)'s END must survive — the old budget clipped tails first")
        }
        XCTAssertFalse(text.contains("[... document truncated ...]"),
                       "the truncation marker is retired with the budget")
        XCTAssertGreaterThan(text.count, 8000, "the total must exceed the retired 4000 budget, or this test pins nothing")
    }

    /// ⚠️ THE MIS-REPORT, pinned dead. With 8 documents the retired per-document share hit its
    /// 500-char floor, and the plain-text reader THROWS `.tooLarge` above `maxSize` — so a
    /// perfectly ordinary 600-char text file was reported to the user as "too large". All eight
    /// must now inline cleanly with zero failures.
    func testManySmallDocumentsAreNotReportedTooLarge() async throws {
        let docs = try (0..<8).map { try writeDoc("doc\($0).txt", characters: 600) }

        let (text, failures) = await WorkflowInputAssembler.extractDocumentText(
            from: docs, fileProcessor: FileProcessorService())

        XCTAssertTrue(failures.isEmpty,
                      "a 600-char file is not 'too large' — the old per-doc floor said it was: \(failures)")
        for i in 0..<8 {
            XCTAssertTrue(text.contains("TAIL-doc\(i).txt"), "doc\(i) must arrive whole")
        }
    }

    /// A genuinely unreadable document still surfaces as a TYPED failure — retiring the budget
    /// must not have widened into swallowing real errors.
    func testMissingFileStillReportsATypedFailure() async throws {
        let ghost = MediaArtifact(
            kind: .document,
            reference: .diskPath(tempDir.appendingPathComponent("does-not-exist.txt")),
            mimeType: "text/plain", label: "ghost")
        let real = try writeDoc("real.txt", characters: 100)

        let (text, failures) = await WorkflowInputAssembler.extractDocumentText(
            from: [ghost, real], fileProcessor: FileProcessorService())

        XCTAssertEqual(failures.count, 1, "the missing file must fail, typed — not vanish")
        XCTAssertTrue(text.contains("TAIL-real.txt"), "…while the readable one still arrives whole")
    }

    /// An `.ephemeralData` document cannot be inlined (no disk path) — it is skipped, logged, and
    /// must NOT appear as a failure: nothing failed, the artifact just is not extractable.
    func testInMemoryDocumentIsSkippedWithoutAFailure() async throws {
        let inMemory = MediaArtifact(
            kind: .document, reference: .ephemeralData(Data("hello".utf8)),
            mimeType: "text/plain", label: "in-memory")

        let (text, failures) = await WorkflowInputAssembler.extractDocumentText(
            from: [inMemory], fileProcessor: FileProcessorService())

        XCTAssertTrue(text.isEmpty)
        XCTAssertTrue(failures.isEmpty, "a skip is not a failure — the log carries the consequence")
    }
}

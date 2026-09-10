// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  KnowledgeSourceRowTests.swift
//  DevgenticTests
//
//  Created on 07/08/26.
//
//  Register A65 — a healthy reference document was drawn in the WARNING colour, so "this file is
//  fine" (orange) and "this file is missing" (red) both read as alarm states, one shade apart, with
//  colour the only thing separating them on the icon.
//
//  A SwiftUI `body` is not reachable from a unit test, so the assertion here is on the seam that
//  carries the fix's intent: the two states differ by SYMBOL, not only by tint. That is the property
//  that regresses silently when someone later tidies two icon names back into one.
//

import XCTest
@testable import devgentic

final class KnowledgeSourceRowTests: XCTestCase {

    // MARK: - The states are distinguishable without colour

    func testAMissingFileUsesADifferentSymbolFromAHealthyOne() {
        let healthy = KnowledgeSourceRow.iconName(forExistingFile: true)
        let missing = KnowledgeSourceRow.iconName(forExistingFile: false)

        XCTAssertNotEqual(healthy, missing,
                          "colour must not be the only differentiator — that is the A65 defect, and "
                          + "it leaves the two states identical to anyone who cannot perceive the hue")
    }

    /// A healthy document should look like a document. Naming the symbol pins the intent: a status
    /// glyph here would say "something is up" about a file that is perfectly fine.
    func testAHealthyFileIsDrawnAsAPlainDocument() {
        XCTAssertEqual(KnowledgeSourceRow.iconName(forExistingFile: true), "doc.text.fill")
    }

    func testAMissingFileIsDrawnAsAWarning() {
        XCTAssertEqual(KnowledgeSourceRow.iconName(forExistingFile: false), "exclamationmark.triangle.fill")
    }

    // MARK: - The state the row renders

    /// The row keys off `KnowledgeSource.exists`, so it is worth pinning that this reflects the
    /// filesystem rather than anything stored — a moved or deleted file is the case A65's red state
    /// exists to report.
    func testExistsReflectsTheFilesystem() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("a65-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("reference.md")
        try "# Reference".write(to: file, atomically: true, encoding: .utf8)

        let present = KnowledgeSource(type: .file, location: file.path)
        XCTAssertTrue(present.exists)
        XCTAssertEqual(present.fileName, "reference.md")

        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(present.exists,
                       "the row must reflect the file being gone — the location is a path, not a copy")
    }

    /// ⚠️ A URL source is not a local file, so `exists` is false for it by construction. It must not
    /// be drawn as a broken document: only `.file` sources are ever checked against disk today.
    func testAURLSourceIsNotTreatedAsALocalFile() {
        let remote = KnowledgeSource(type: .url, location: "https://example.com/doc")
        XCTAssertFalse(remote.isLocalFile)
    }
}

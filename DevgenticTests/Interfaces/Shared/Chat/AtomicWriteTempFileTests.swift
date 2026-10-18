// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AtomicWriteTempFileTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class AtomicWriteTempFileTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devgentic-atomicwrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Clear the immutable flag first or the directory cannot be removed.
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in contents {
                try? FileManager.default.setAttributes([.immutable: false],
                                                       ofItemAtPath: dir.appendingPathComponent(name).path)
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Every `.devgentic_tmp_*` left in the directory. The temp is hidden by its dot prefix, so
    /// `contentsOfDirectory` (which lists dotfiles) is what makes the orphan visible at all —
    /// in Finder it is not, which is why this leaked unnoticed.
    private func tempFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".devgentic_tmp_") }
    }

    /// The success path must leave nothing behind — `replaceItemAt` consumes the temp, and the
    /// new `defer` must not resurrect or mis-handle it.
    func testSuccessfulWriteLeavesNoTempFile() async throws {
        let target = dir.appendingPathComponent("ok.txt")
        try "OLD".write(to: target, atomically: true, encoding: .utf8)

        try await ChatHistoryViewModel.atomicallyWrite("NEW", to: target)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "NEW")
        XCTAssertTrue(try tempFiles().isEmpty, "the temp must not survive a successful save")
    }

    /// A write to a file that does not exist yet still cleans up (and creates the file).
    func testCreatingANewFileLeavesNoTempFile() async throws {
        let target = dir.appendingPathComponent("fresh.txt")

        try await ChatHistoryViewModel.atomicallyWrite("HELLO", to: target)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "HELLO")
        XCTAssertTrue(try tempFiles().isEmpty)
    }

    /// THE defect: when the replace step throws, the temp used to survive — holding the file's
    /// full proposed contents, hidden, one more per retry. An immutable target reproduces it
    /// deterministically: the temp writes fine (the directory is writable) and `replaceItemAt`
    /// then fails with a permissions error.
    func testFailedReplaceDoesNotOrphanTheTempFile() async throws {
        let target = dir.appendingPathComponent("locked.txt")
        try "OLD".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: target.path)

        do {
            try await ChatHistoryViewModel.atomicallyWrite("NEW", to: target)
            XCTFail("expected the replace to fail against an immutable target")
        } catch {
            // expected
        }

        XCTAssertTrue(try tempFiles().isEmpty,
                      "a failed save must not leave its temp file next to the user's file")
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: target.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "OLD",
                       "and the original must be untouched")
    }

    /// The drift guard refuses BEFORE any temp is created, so a refused save leaves nothing
    /// either — and must not clobber the file it refused to write.
    func testDriftRefusalWritesNothingAndLeavesNoTemp() async throws {
        let target = dir.appendingPathComponent("drifted.txt")
        try "CHANGED ON DISK".write(to: target, atomically: true, encoding: .utf8)

        do {
            try await ChatHistoryViewModel.atomicallyWrite("MINE", to: target,
                                                           expectingBaseline: "WHAT I LAST SAW")
            XCTFail("expected the drift guard to refuse")
        } catch {
            // expected
        }

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "CHANGED ON DISK")
        XCTAssertTrue(try tempFiles().isEmpty)
    }
}

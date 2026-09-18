// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AttachmentSizingTests.swift
//  DevgenticTests
//
//  The composer priced attachments as `min(statBytes, perFileBudget)`, summed until the total
//  budget. Two things about the reader make that wrong:
//
//   1. `readFileContentOrThrow` THROWS `.tooLarge` when `content.count > maxSize` — it does
//      NOT truncate — and `assembleTextFileContent` records the failure and moves on. So an
//      oversized file contributes ZERO, while the composer charged the full 50,000.
//   2. Every included file carries `--- Start of file: … ---` / `--- End of file: … ---`
//      wrapper text, which the composer charged nothing for.
//
//  And a `.stateless` profile never injects content at all — it hands over a path manifest
//  and lets the agent `read_file` on demand. Charging file bytes there over-warned by orders
//  of magnitude on a large attachment, with a banner the user could only clear by detaching a
//  file that was costing almost nothing.
//

import XCTest
@testable import devgentic

final class AttachmentSizingTests: XCTestCase {

    // MARK: - Dropped, not clipped

    /// The headline correction. A file past the per-file budget is refused by the reader, so
    /// it must cost nothing — not the budget.
    func testFileOverThePerFileBudgetContributesNothing() {
        let oversized = DirectInjectionBudget.perFile + 1
        XCTAssertEqual(
            PromptFitCheck.attachmentInjectionChars(forFileSizes: [oversized], wrapperCharsPerFile: 0), 0,
            "the reader throws .tooLarge — the model never sees this file"
        )
    }

    func testFileExactlyAtTheBudgetIsStillCounted() {
        XCTAssertEqual(
            PromptFitCheck.attachmentInjectionChars(
                forFileSizes: [DirectInjectionBudget.perFile], wrapperCharsPerFile: 0),
            DirectInjectionBudget.perFile,
            "the boundary is inclusive — > maxSize throws, == does not"
        )
    }

    /// One oversized file must not suppress the others; the reader skips it and continues.
    func testAnOversizedFileDoesNotSuppressItsNeighbours() {
        let sizes = [1_000, DirectInjectionBudget.perFile + 5_000, 2_000]
        XCTAssertEqual(
            PromptFitCheck.attachmentInjectionChars(forFileSizes: sizes, wrapperCharsPerFile: 0),
            3_000
        )
    }

    /// Regression guard on the old behaviour, kept as a witness.
    func testTheOldClampWouldHaveChargedTheWholeBudget() {
        let oversized = DirectInjectionBudget.perFile * 3
        let now = PromptFitCheck.attachmentInjectionChars(forFileSizes: [oversized], wrapperCharsPerFile: 0)
        let oldClamp = min(oversized, DirectInjectionBudget.perFile)
        XCTAssertEqual(now, 0)
        XCTAssertEqual(oldClamp, DirectInjectionBudget.perFile, "documents the defect: \(oldClamp) phantom chars")
    }

    // MARK: - Wrappers

    func testWrapperCharsAreChargedPerIncludedFile() {
        let withWrapper = PromptFitCheck.attachmentInjectionChars(
            forFileSizes: [100, 200], wrapperCharsPerFile: 80)
        XCTAssertEqual(withWrapper, 300 + 160)
    }

    /// A dropped file carries no wrapper either — it never reaches the assembler.
    func testDroppedFilesCarryNoWrapper() {
        XCTAssertEqual(
            PromptFitCheck.attachmentInjectionChars(
                forFileSizes: [DirectInjectionBudget.perFile + 1], wrapperCharsPerFile: 500),
            0
        )
    }

    // MARK: - Total budget

    func testTotalBudgetStopsAccumulation() {
        let many = Array(repeating: 40_000, count: 20)   // 800K raw vs a 200K ceiling
        let charged = PromptFitCheck.attachmentInjectionChars(forFileSizes: many, wrapperCharsPerFile: 0)
        XCTAssertLessThanOrEqual(charged, DirectInjectionBudget.total)
        XCTAssertGreaterThan(charged, DirectInjectionBudget.total / 2, "it should fill most of the budget")
    }

    func testNoAttachmentsCostNothing() {
        XCTAssertEqual(PromptFitCheck.attachmentInjectionChars(forFileSizes: [], wrapperCharsPerFile: 80), 0)
    }

}

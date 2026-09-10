// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  FileImportOutcomeTests.swift
//  DevgenticTests
//
//  Created on 07/08/26.
//
//  Registers A40 and A60 — the three `.fileImporter` handlers dropped `.failure` entirely, and
//  silently discarded duplicates.
//
//  ⚠️ The whole difficulty of this fix is in one place: SwiftUI reports **user cancellation as a
//  `.failure`**. The naive repair — surface every `.failure` — puts a red banner on screen every
//  time somebody backs out of the picker, which is worse than the silence it replaced. These tests
//  exist mainly to pin that boundary, because getting it wrong is invisible in code review and
//  obvious to a user.
//

import XCTest
import SwiftUI
@testable import devgentic

final class FileImportOutcomeTests: XCTestCase {

    private let file = URL(fileURLWithPath: "/tmp/skills/code-review")

    // MARK: - Cancellation is not a failure

    /// The exact error AppKit delivers when the user dismisses the open panel.
    func testUserCancellationIsClassifiedAsCancelled() {
        let cancellation: Result<[URL], Error> = .failure(CocoaError(.userCancelled))

        guard case .cancelled = cancellation.fileImportOutcome() else {
            return XCTFail("cancelling the picker must never be reported to the user as an error")
        }
    }

    /// Belt and braces: the same thing built as a raw `NSError`, since AppKit surfaces this through
    /// more than one error type and the check is on domain/code rather than a cast.
    func testRawUserCancelledNSErrorIsClassifiedAsCancelled() {
        let raw = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        let result: Result<[URL], Error> = .failure(raw)

        guard case .cancelled = result.fileImportOutcome() else {
            return XCTFail("NSUserCancelledError in NSCocoaErrorDomain is a dismissal, not a fault")
        }
    }

    /// ⚠️ An empty success is a dismissal too. Reporting `.selected([])` would push the `isEmpty`
    /// check back out to all three call sites, and one of them would forget it.
    func testAnEmptySuccessfulSelectionIsClassifiedAsCancelled() {
        let result: Result<[URL], Error> = .success([])

        guard case .cancelled = result.fileImportOutcome() else {
            return XCTFail("selecting nothing is not an import of nothing")
        }
    }

    // MARK: - Real failures reach the user

    /// The A60 scenario: a permission denial. Before the fix this was indistinguishable from Cancel.
    func testAPermissionDenialIsClassifiedAsFailed() throws {
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let result: Result<[URL], Error> = .failure(denied)

        guard case .failed(let message) = result.fileImportOutcome() else {
            return XCTFail("a permission denial must be surfaced, not swallowed")
        }
        XCTAssertFalse(message.trimmingCharacters(in: .whitespaces).isEmpty,
                       "an empty message would leave the banner blank — no better than silence")
    }

    /// An iCloud placeholder that never materialises — the register's own example, and a different
    /// error domain, so it also proves the cancellation check is not over-broad.
    func testANonCocoaErrorIsClassifiedAsFailed() {
        let result: Result<[URL], Error> = .failure(URLError(.cannotOpenFile))

        guard case .failed = result.fileImportOutcome() else {
            return XCTFail("only NSCocoaErrorDomain/NSUserCancelledError is a dismissal")
        }
    }

    /// ⚠️ Guards the near-miss that would break this: `NSUserCancelledError` (3072) in a DIFFERENT
    /// domain is not the user dismissing our picker, and must not silence a real fault.
    func testTheCancelledCodeInAnotherDomainIsStillAFailure() {
        let result: Result<[URL], Error> = .failure(
            NSError(domain: "com.example.Something", code: NSUserCancelledError))

        guard case .failed = result.fileImportOutcome() else {
            return XCTFail("the domain is part of the check — code 3072 alone is not a dismissal")
        }
    }

    func testASelectionIsPassedThroughIntact() throws {
        let result: Result<[URL], Error> = .success([file])

        guard case .selected(let urls) = result.fileImportOutcome() else {
            return XCTFail("expected the selected URLs")
        }
        XCTAssertEqual(urls, [file])
    }
}

// MARK: - The shared knowledge-file importer

final class KnowledgeSourceImportTests: XCTestCase {

    /// A mutable box so a real `Binding` can be handed to the code under test — the two editors
    /// pass a computed binding into the profile draft, so the seam has to be exercised as a binding.
    private final class Box {
        var sources: [KnowledgeSource] = []
        var binding: Binding<[KnowledgeSource]> {
            Binding(get: { self.sources }, set: { self.sources = $0 })
        }
    }

    private let alpha = URL(fileURLWithPath: "/tmp/docs/alpha.md")
    private let beta = URL(fileURLWithPath: "/tmp/docs/beta.md")

    func testSelectedFilesAreAttachedWithNothingToReport() {
        let box = Box()

        let message = KnowledgeSourceImport.apply(.success([alpha, beta]), to: box.binding, profileKind: "agent")

        XCTAssertNil(message, "a clean import must not put a banner on screen")
        XCTAssertEqual(box.sources.map(\.location), [alpha.path, beta.path])
    }

    func testAFailureIsReportedAndAttachesNothing() throws {
        let box = Box()
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)

        let message = KnowledgeSourceImport.apply(.failure(denied), to: box.binding, profileKind: "agent")

        XCTAssertNotNil(message, "register A60 — this arm previously produced nothing at all")
        XCTAssertTrue(box.sources.isEmpty)
    }

    func testCancellingReportsNothingAndAttachesNothing() {
        let box = Box()

        let message = KnowledgeSourceImport.apply(
            .failure(CocoaError(.userCancelled)), to: box.binding, profileKind: "bot")

        XCTAssertNil(message, "a banner on every Cancel would be worse than the original silence")
        XCTAssertTrue(box.sources.isEmpty)
    }

    /// ⚠️ Register A40's other half. Re-picking an attached file is not an error, but selecting
    /// three files and watching the list grow by one needs explaining, or the import reads as broken.
    func testDuplicatesAreSkippedAndSaidOutLoud() throws {
        let box = Box()
        _ = KnowledgeSourceImport.apply(.success([alpha]), to: box.binding, profileKind: "agent")

        let message = KnowledgeSourceImport.apply(.success([alpha, beta]), to: box.binding, profileKind: "agent")

        XCTAssertEqual(box.sources.count, 2, "the duplicate must not be attached twice")
        let reported = try XCTUnwrap(message)
        XCTAssertTrue(reported.contains("alpha.md"),
                      "the message has to name the file — a bare count leaves the user guessing")
        XCTAssertFalse(reported.contains("beta.md"), "beta was added, not skipped")
    }

    func testAnAllDuplicateSelectionChangesNothing() {
        let box = Box()
        _ = KnowledgeSourceImport.apply(.success([alpha]), to: box.binding, profileKind: "agent")

        let message = KnowledgeSourceImport.apply(.success([alpha]), to: box.binding, profileKind: "agent")

        XCTAssertEqual(box.sources.count, 1)
        XCTAssertNotNil(message, "otherwise the button looks dead")
    }
}

// MARK: - Duplicate skills are reported, not dropped

final class DuplicateSkillReportingTests: XCTestCase {

    /// The duplicate case rides the `skipped` list the UI already renders, so the fix needed no new
    /// surface — but the text has to say which copy survived, since that is the actual question.
    func testTheDuplicateSkipReasonNamesTheFolderThatWon() {
        let entry = SkippedSkillEntry(
            directoryName: "code-review",
            reason: .duplicateName(keptFrom: "team-skills"))

        XCTAssertTrue(entry.reason.displayText.contains("team-skills"))
    }

    /// The pre-existing reasons must be untouched — they share one disclosure list with the new one.
    func testExistingSkipReasonsStillRender() {
        XCTAssertEqual(SkippedSkillEntry.SkipReason.noSkillFile.displayText, "No SKILL.md file")
        XCTAssertEqual(SkippedSkillEntry.SkipReason.parseError("bad frontmatter").displayText,
                       "bad frontmatter")
    }

    /// A skipped duplicate has to count toward the "N skipped" label, or it is reported nowhere.
    func testASkippedDuplicateCountsInTheScanSummary() {
        let result = SkillScanResult(
            manifests: [],
            skipped: [SkippedSkillEntry(directoryName: "code-review",
                                        reason: .duplicateName(keptFrom: "team-skills"))],
            totalSubdirectories: 1)

        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertTrue(result.summary.contains("1 skipped"))
    }
}

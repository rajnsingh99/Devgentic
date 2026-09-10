// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  StoreOpenDiagnosticsTests.swift
//  DevgenticTests
//
//  Created on 04/08/26.
//
//  Proves the launch path can say WHY the database failed to open.
//
//  Before this, every distinct cause reached the app as `SwiftDataError` code 1 with empty
//  `userInfo` and empty `underlyingErrors`, so the alert, the log line and the support clipboard
//  all carried the same content-free string (G39). The one message that identifies the bug is
//  printed by Core Data to stderr, which a Finder-launched `.app` discards (G40).
//
//  These tests cover both replacement channels: metadata-based classification, and stderr capture.
//

import XCTest
import SwiftData
@testable import devgentic

final class StoreOpenDiagnosticsTests: XCTestCase {

    private var workDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StoreDiagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDirectory {
            // A permissions test may have made the directory read-only; restore before removing.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: workDirectory.path)
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Classification

    func testMissingStoreIsClassifiedAsMissing() {
        let absent = workDirectory.appendingPathComponent("nope.store")
        XCTAssertEqual(
            StoreOpenDiagnostics.classify(storeURL: absent, expectedEntityNames: ["ConversationSD"]),
            .storeMissing
        )
    }

    func testUnwritableDirectoryIsClassifiedBeforeAnythingElse() throws {
        let storeURL = workDirectory.appendingPathComponent(DevgenticSchema.storeFilename)
        try Data("not a store".utf8).write(to: storeURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: workDirectory.path)

        let diagnosis = StoreOpenDiagnostics.classify(
            storeURL: storeURL, expectedEntityNames: ["ConversationSD"]
        )

        guard case .pathNotWritable = diagnosis else {
            return XCTFail("Expected .pathNotWritable, got \(diagnosis)")
        }
    }

    /// A file that is not a SQLite store must produce the REAL underlying error — the whole point
    /// of dropping to Core Data's raw metadata API instead of introspecting the SwiftData error.
    func testGarbageFileYieldsRealUnderlyingError() throws {
        let storeURL = workDirectory.appendingPathComponent(DevgenticSchema.storeFilename)
        try Data(repeating: 0xFF, count: 4096).write(to: storeURL)

        let diagnosis = StoreOpenDiagnostics.classify(
            storeURL: storeURL, expectedEntityNames: ["ConversationSD"]
        )

        guard case .unreadableAsStore(let domain, let code, let reason) = diagnosis else {
            return XCTFail("Expected .unreadableAsStore, got \(diagnosis)")
        }
        XCTAssertFalse(domain.isEmpty, "A real NSError domain must survive — not SwiftData's empty one.")
        XCTAssertNotEqual(code, 0)
        XCTAssertFalse(reason.isEmpty, "Must carry an actual reason, unlike SwiftDataError code 1.")
        XCTAssertFalse(diagnosis.summary.isEmpty)
    }

    /// The realistic case: the pre-V1 legacy fixture was written when `CodeViewerSessionSD`
    /// existed. Classifying it against today's schema must NAME the retired entity — that is the
    /// diagnosis a developer or support engineer actually needs.
    ///
    /// ⚠️ The LEGACY fixture, not `devgentic-schema-v1-fixture`. This test originally read the V1
    /// fixture, which at the time was the pre-V1 artifact carrying the retired entity. When V2
    /// landed (2026-08-22) that artifact was renamed `devgentic-pre-v1-legacy-fixture` and a true
    /// V1 store — today's 12 entities exactly, no retired one — was regenerated under the old
    /// name; this test kept pointing at the old name and started (correctly) getting
    /// `.entityShapeChanged` from a store whose entity SET now matches the code's.
    func testEntityPresentInStoreButNotInCodeIsNamed() throws {
        guard let fixture = Bundle(for: StoreOpenDiagnosticsTests.self)
            .url(forResource: SchemaMigrationTests.legacyFixtureBaseName, withExtension: "store") else {
            // Same convention as testPreV1StoreIsRefusedLoudlyUnderStagedMigration: the legacy
            // artifact is irreplaceable by design (the retired type is gone), so its absence is
            // "not checked", never a red suite.
            throw XCTSkip("No checked-in pre-V1 legacy fixture found "
                          + "(\(SchemaMigrationTests.legacyFixtureBaseName).store).")
        }

        let diagnosis = StoreOpenDiagnostics.classify(
            storeURL: fixture,
            expectedEntityNames: Set(DevgenticSchema.schema.entities.map(\.name))
        )

        guard case .entitySetChanged(let addedInCode, let missingFromCode) = diagnosis else {
            return XCTFail("Expected .entitySetChanged, got \(diagnosis)")
        }
        XCTAssertTrue(missingFromCode.contains("CodeViewerSessionSD"),
                      "The retired entity must be named. Got missingFromCode=\(missingFromCode)")
        XCTAssertTrue(addedInCode.isEmpty, "Nothing was added; got \(addedInCode)")
        XCTAssertTrue(diagnosis.summary.contains("CodeViewerSessionSD"),
                      "The human-readable summary must name it too: \(diagnosis.summary)")
    }

    /// A new entity declared in code but absent from the store is the mirror case.
    func testEntityAddedInCodeIsNamed() throws {
        let fixture = try XCTUnwrap(
            Bundle(for: StoreOpenDiagnosticsTests.self)
                .url(forResource: "devgentic-schema-v1-fixture", withExtension: "store")
        )
        var expected = Set(DevgenticSchema.schema.entities.map(\.name))
        expected.insert("SomeBrandNewEntitySD")

        let diagnosis = StoreOpenDiagnostics.classify(storeURL: fixture, expectedEntityNames: expected)

        guard case .entitySetChanged(let addedInCode, _) = diagnosis else {
            return XCTFail("Expected .entitySetChanged, got \(diagnosis)")
        }
        XCTAssertTrue(addedInCode.contains("SomeBrandNewEntitySD"))
    }

    /// When the entity sets match, the incompatibility is INSIDE an entity — metadata cannot
    /// narrow it further, and the diagnosis must say so rather than guessing.
    ///
    /// Uses the pre-V1 LEGACY fixture (see the pointer-drift warning on
    /// `testEntityPresentInStoreButNotInCodeIsNamed`): its entity set is today's plus the retired
    /// `CodeViewerSessionSD`, so passing exactly that set makes the sets EQUAL while the store's
    /// pre-freeze `ConversationSD` shape still differs — the precise "same names, different
    /// insides" case this diagnosis exists for.
    func testMatchingEntitySetsReportShapeChange() throws {
        guard let fixture = Bundle(for: StoreOpenDiagnosticsTests.self)
            .url(forResource: SchemaMigrationTests.legacyFixtureBaseName, withExtension: "store") else {
            throw XCTSkip("No checked-in pre-V1 legacy fixture found "
                          + "(\(SchemaMigrationTests.legacyFixtureBaseName).store).")
        }
        // The legacy fixture's own entity set = today's entities plus the retired one.
        var storedEntities = Set(DevgenticSchema.schema.entities.map(\.name))
        storedEntities.insert("CodeViewerSessionSD")

        XCTAssertEqual(
            StoreOpenDiagnostics.classify(storeURL: fixture, expectedEntityNames: storedEntities),
            .entityShapeChanged
        )
    }

    func testEveryDiagnosisHasANonEmptySummaryAndTag() {
        let all: [StoreOpenDiagnosis] = [
            .storeMissing,
            .pathNotWritable(directory: "/tmp"),
            .unreadableAsStore(domain: "NSCocoaErrorDomain", code: 259, reason: "bad"),
            .entitySetChanged(addedInCode: ["A"], missingFromCode: ["B"]),
            .entityShapeChanged,
            .indeterminate,
        ]
        for diagnosis in all {
            XCTAssertFalse(diagnosis.summary.isEmpty, "\(diagnosis) has no summary")
            XCTAssertFalse(diagnosis.tag.isEmpty, "\(diagnosis) has no tag")
        }
        XCTAssertEqual(Set(all.map(\.tag)).count, all.count, "Tags must be distinct for triage.")
    }

    // MARK: - stderr capture

    func testCaptureReturnsWhatWasWrittenToStandardError() throws {
        let captured = StoreOpenDiagnostics.captureStandardError {
            fputs("CoreData: error: hello from stderr\n", stderr)
        }
        let text = try XCTUnwrap(captured, "Nothing captured.")
        XCTAssertTrue(text.contains("hello from stderr"), "Got: \(text)")
    }

    /// Redirection must be undone even though the app is about to exit — a leaked redirect would
    /// swallow every later diagnostic, including the ones the alert depends on.
    func testStandardErrorIsRestoredAfterCapture() throws {
        _ = StoreOpenDiagnostics.captureStandardError { fputs("first\n", stderr) }

        let second = StoreOpenDiagnostics.captureStandardError {
            fputs("second capture still works\n", stderr)
        }
        XCTAssertTrue(try XCTUnwrap(second).contains("second capture still works"),
                      "stderr was not restored — the second capture saw nothing.")
    }

    func testCaptureReturnsNilWhenNothingIsWritten() {
        XCTAssertNil(StoreOpenDiagnostics.captureStandardError { })
    }

    func testCaptureStillRunsBodyAndPropagatesItsEffect() {
        var ran = false
        _ = StoreOpenDiagnostics.captureStandardError { ran = true }
        XCTAssertTrue(ran, "The body must run even when capture is pointless.")
    }

    // MARK: - Detail extraction

    /// Real Core Data output, verbatim from a reproduced `134110` failure earlier in this work.
    private static let realCoreDataOutput = """
        2026-08-04 11:37:06.461880+0530 devgentic[99757:30301106] [error] CoreData: error: \
        NSUnderlyingError : Error Domain=NSCocoaErrorDomain Code=134110 "An error occurred during \
        persistent store migration." UserInfo={entity=PromptModel, attribute=driftProbe, \
        reason=Validation error missing attribute values on mandatory destination attribute}
        CoreData: error: NSUnderlyingError : Error Domain=NSCocoaErrorDomain Code=134110 "An error \
        occurred during persistent store migration." UserInfo={entity=PromptModel, \
        attribute=driftProbe, reason=Validation error missing attribute values on mandatory \
        destination attribute}
        2026-08-04 11:37:06.462946+0530 devgentic[99757:30301106] [DataStore] Unresolved error \
        loading container
        some completely unrelated chatter
        """

    func testDetailExtractionFindsTheEntityAndAttribute() {
        let lines = StoreOpenDiagnostics.migrationDetailLines(in: Self.realCoreDataOutput)

        XCTAssertFalse(lines.isEmpty, "Extracted nothing from real Core Data output.")
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("entity=PromptModel"), "Lost the entity name: \(joined)")
        XCTAssertTrue(joined.contains("attribute=driftProbe"), "Lost the attribute name: \(joined)")
        XCTAssertTrue(joined.contains("134110"), "Lost the error code: \(joined)")
    }

    /// Core Data repeats the same diagnostic several times per failure; a support paste that says
    /// the same thing four times is worse than one that says it once.
    func testDetailExtractionDeduplicates() {
        let lines = StoreOpenDiagnostics.migrationDetailLines(in: Self.realCoreDataOutput)
        XCTAssertEqual(Set(lines).count, lines.count, "Duplicate lines survived: \(lines)")
    }

    func testDetailExtractionDropsUnrelatedChatter() {
        let lines = StoreOpenDiagnostics.migrationDetailLines(in: Self.realCoreDataOutput)
        XCTAssertFalse(lines.contains { $0.contains("completely unrelated chatter") })
    }

    /// The alert embeds these lines, so the count must be bounded no matter how noisy the failure.
    func testDetailExtractionRespectsItsLimit() {
        let noisy = (0..<200).map { "CoreData: error: reason=failure number \($0)" }
            .joined(separator: "\n")
        XCTAssertEqual(StoreOpenDiagnostics.migrationDetailLines(in: noisy, limit: 6).count, 6)
    }

    func testDetailExtractionReturnsEmptyForIrrelevantOutput() {
        XCTAssertTrue(
            StoreOpenDiagnostics.migrationDetailLines(in: "nothing to see\nhere at all").isEmpty
        )
    }

    /// Core Data lines embed nested NSError descriptions with absolute URLs and run to several
    /// hundred characters. The alert and clipboard both embed these, so the cap matters.
    func testDetailExtractionTruncatesOverlongLines() {
        let long = "CoreData: error: reason=" + String(repeating: "x", count: 5000)
        let lines = StoreOpenDiagnostics.migrationDetailLines(in: long, maxLineLength: 100)
        XCTAssertEqual(lines.count, 1)
        XCTAssertLessThanOrEqual(lines[0].count, 101, "Line was not truncated: \(lines[0].count) chars")
        XCTAssertTrue(lines[0].hasSuffix("…"), "Truncation must be visible to the reader.")
    }

    // MARK: - Primary reason (outranks classification)

    /// The money quote: which entity, which attribute, why. This is what a developer acts on.
    func testPrimaryReasonExtractsEntityAttributeAndReason() throws {
        let reason = try XCTUnwrap(
            StoreOpenDiagnostics.primaryFailureReason(in: Self.realCoreDataOutput)
        )
        XCTAssertTrue(reason.contains("entity=PromptModel"), reason)
        XCTAssertTrue(reason.contains("attribute=driftProbe"), reason)
        XCTAssertTrue(reason.contains("reason=Validation error"), reason)
        XCTAssertFalse(reason.contains("}"), "Should stop at the UserInfo closing brace: \(reason)")
    }

    /// Regression guard for the ordering defect found during end-to-end verification: the store
    /// carried a retired entity (harmless) while the real blocker was an attribute in a DIFFERENT
    /// entity. Leading with the metadata classification named the wrong cause.
    func testPrimaryReasonNamesTheBlockerNotAnUnrelatedEntityDifference() throws {
        let output = """
            CoreData: error: NSUnderlyingError : Error Domain=NSCocoaErrorDomain Code=134110 \
            UserInfo={entity=PromptModel, attribute=driftProbe, reason=Validation error missing \
            attribute values on mandatory destination attribute}
            """
        let reason = try XCTUnwrap(StoreOpenDiagnostics.primaryFailureReason(in: output))
        XCTAssertTrue(reason.contains("PromptModel"))
        XCTAssertFalse(reason.contains("CodeViewerSessionSD"),
                       "The blocker must not be conflated with an unrelated entity difference.")
    }

    /// Not every failure names an entity — a missing mapping model does not. Fall back to the
    /// bare reason rather than returning nothing.
    func testPrimaryReasonFallsBackToBareReason() throws {
        let output = "CoreData: error: reason=Persistent store migration failed, missing mapping model."
        let reason = try XCTUnwrap(StoreOpenDiagnostics.primaryFailureReason(in: output))
        XCTAssertTrue(reason.hasPrefix("reason="), reason)
        XCTAssertTrue(reason.contains("missing mapping model"), reason)
    }

    func testPrimaryReasonIsNilWhenCoreDataSaidNothingUseful() {
        XCTAssertNil(StoreOpenDiagnostics.primaryFailureReason(in: "just some chatter\nand more"))
    }
}

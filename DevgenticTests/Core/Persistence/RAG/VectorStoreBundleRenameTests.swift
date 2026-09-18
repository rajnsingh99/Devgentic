// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  VectorStoreBundleRenameTests.swift
//  devgenticTests
//
//  What a bundle-identifier rename does to a database whose path is keyed on it.
//
//  ⚠️⚠️ THE FAILURE THIS PINS, AND IT ALREADY HAPPENED. `VectorStoreService.storeDirectoryURL()` is
//  `~/Library/Application Support/<bundleID>/vector-db`, and commit `2faad1c` renamed that identifier
//  `com.dev.devgentic` → `app.devgentic.macos` for the public release. Nothing failed and nothing was
//  deleted: the app created an EMPTY store at the new path and carried on beside a full one it could
//  no longer address.
//
//  ⚠️ THAT IS THE WORST SHAPE THIS FAILURE COULD TAKE. Every protection in `VectorStoreService`
//  guards against DELETION — `quarantineSupersededStore` exists precisely because this index "CANNOT
//  be rebuilt (there is no reindex-from-transcripts mechanism)" — and a rename walks past all of it
//  by never touching the old data at all. A silent empty index reads exactly like a working one.
//

import XCTest
@testable import devgentic

final class VectorStoreBundleRenameTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vectorstore-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - The database test the migration and the schema gate must share

    /// ⚠️ A DIRECTORY HOLDING ONLY OUR SCHEMA MARKER IS NOT A DATABASE. If the migration and the
    /// schema gate disagreed on this, the migration would either skip a real store or overwrite one.
    func testAMarkerOnlyDirectoryDoesNotCountAsADatabase() throws {
        let dir = root.appendingPathComponent("vector-db")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "3".write(to: dir.appendingPathComponent(VectorStoreService.schemaMarkerFilename),
                      atomically: true, encoding: .utf8)

        XCTAssertFalse(VectorStoreService.containsDatabase(at: dir),
                       "a lone schema marker is not a database; treating it as one blocks the migration")
    }

    func testADirectoryHoldingDataCountsAsADatabase() throws {
        let dir = root.appendingPathComponent("vector-db")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("data.mdb"))

        XCTAssertTrue(VectorStoreService.containsDatabase(at: dir))
    }

    func testAnAbsentDirectoryHoldsNoDatabase() {
        XCTAssertFalse(VectorStoreService.containsDatabase(at: root.appendingPathComponent("nope")))
    }

    // MARK: - Adoption

    /// The clean case: the renamed build has not launched yet, so there is nothing at the
    /// destination to lose.
    func testALegacyStoreIsAdoptedWhenTheDestinationHoldsNothing() throws {
        let legacy = root.appendingPathComponent("com.dev.devgentic/vector-db")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("real index".utf8).write(to: legacy.appendingPathComponent("data.mdb"))

        let destination = root.appendingPathComponent("app.devgentic.macos/vector-db")
        let outcome = adopt(legacy: legacy, destination: destination)

        guard case .adopted = outcome else {
            return XCTFail("a legacy store must be adopted when the destination is empty; got \(outcome)")
        }
        XCTAssertTrue(VectorStoreService.containsDatabase(at: destination),
                      "the index did not arrive at the destination")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("data.mdb"), encoding: .utf8),
                       "real index", "the adopted store is not the legacy one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "the legacy directory should be MOVED, not copied — two copies of a 28 MB index is its own bug")
    }

    /// ⚠️⚠️ THE RESTRAINT IS THE POINT. Once the renamed build has launched once, BOTH directories
    /// hold a store, and the new one may since have indexed real content. Choosing between two live
    /// databases and discarding one is not a decision to take silently at launch — the same lesson
    /// `quarantineSupersededStore` records.
    func testALegacyStoreIsNotAdoptedOverAnExistingOne() throws {
        let legacy = root.appendingPathComponent("com.dev.devgentic/vector-db")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("old index".utf8).write(to: legacy.appendingPathComponent("data.mdb"))

        let destination = root.appendingPathComponent("app.devgentic.macos/vector-db")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("new index".utf8).write(to: destination.appendingPathComponent("data.mdb"))

        let outcome = adopt(legacy: legacy, destination: destination)

        // ⚠️ `.ambiguous` SPECIFICALLY, not merely "did not adopt". `moveItem` refuses an existing
        //   destination on its own, so a missing guard would ALSO fail to adopt — and report a
        //   generic move error instead of the actionable both-paths-and-sizes line the user needs.
        //   Asserting the outcome is what makes the guard's removal visible.
        guard case .ambiguous = outcome else {
            return XCTFail("""
                Expected `.ambiguous` — the both-stores-exist case must be REPORTED as its own \
                outcome. Got \(outcome), which means the guard is gone and this is being handled as \
                an incidental move failure.
                """)
        }
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("data.mdb"), encoding: .utf8),
                       "new index", "the destination store was overwritten")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), """
            The legacy store was removed without being adopted. Nothing may be deleted here — this \
            index cannot be rebuilt, and the user needs both paths intact to choose between them.
            """)
    }

    func testNothingHappensWhenThereIsNoLegacyStore() throws {
        let destination = root.appendingPathComponent("app.devgentic.macos/vector-db")
        XCTAssertEqual(adopt(legacy: root.appendingPathComponent("com.dev.devgentic/vector-db"),
                             destination: destination), .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "no legacy store means nothing to create")
    }

    // MARK: - Wiring

    /// ⚠️ The outgoing identifier must stay listed, or every install that has not yet launched the
    /// migrating build is stranded permanently.
    func testThePreviousBundleIdentifierIsListed() {
        XCTAssertTrue(VectorStoreService.legacyBundleIdentifiers.contains("com.dev.devgentic"), """
            `com.dev.devgentic` is no longer in `legacyBundleIdentifiers`. Any install still holding \
            its index under that path loses semantic recall with no way to rebuild it.
            """)
    }

    /// ⚠️ The migration must run BEFORE the schema gate: an adopted store on an old schema still has
    /// to be quarantined rather than opened, and the gate is what knows how to do that.
    func testAdoptionRunsBeforeTheSchemaGate() throws {
        let source = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/Core/Persistence/RAG/VectorStoreService.swift")
        guard let adopt = source.range(of: "adoptLegacyStoreIfUnambiguous(destination:"),
              let gate = source.range(of: "switch Self.schemaGateAction(") else {
            return XCTFail("could not find both the adoption call and the schema gate in init")
        }
        XCTAssertTrue(adopt.lowerBound < gate.lowerBound, """
            The bundle-identifier gate runs after the schema gate. A store adopted afterwards skips \
            the schema check entirely and is opened on whatever schema it happens to carry.
            """)
    }

    // MARK: - Helper

    /// Drives the REAL adoption, with its legacy candidates injected so it acts on a temporary
    /// directory instead of the user's Application Support.
    ///
    /// ⚠️ This calls production. An earlier draft of this file reimplemented the decision here and
    /// would have passed with `adoptLegacyStoreIfUnambiguous` deleted — the exact coverage illusion
    /// this codebase audits for.
    private func adopt(legacy: URL, destination: URL) -> VectorStoreService.LegacyAdoption {
        VectorStoreService.adoptLegacyStoreIfUnambiguous(
            destination: destination,
            legacyCandidates: [legacy],
            logger: DGLogger(category: "VectorStoreBundleRenameTests")
        )
    }
}

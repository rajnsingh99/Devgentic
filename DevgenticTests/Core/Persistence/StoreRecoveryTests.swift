// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  StoreRecoveryTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class StoreRecoveryTests: XCTestCase {

    private var workDirectory: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StoreRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        storeURL = workDirectory.appendingPathComponent(DevgenticSchema.storeFilename)
    }

    override func tearDownWithError() throws {
        if let workDirectory {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: workDirectory.path)
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        storeURL = nil
        try super.tearDownWithError()
    }

    /// Builds the full four-artifact set, matching what SwiftData actually writes.
    private func makeCompleteArtifactSet(externalBlobs: Int = 2) throws {
        let fileManager = FileManager.default
        try Data("main store".utf8).write(to: storeURL)
        try Data("wal contents".utf8).write(to: URL(fileURLWithPath: storeURL.path + "-wal"))
        try Data("shm contents".utf8).write(to: URL(fileURLWithPath: storeURL.path + "-shm"))

        let support = DevgenticSchema.storeArtifactURLs(for: storeURL).support
            .appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        for index in 0..<externalBlobs {
            try Data(repeating: UInt8(index), count: 1024)
                .write(to: support.appendingPathComponent("blob-\(index)"))
        }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - Artifact discovery (G27)

    func testDiscoveryFindsAllFourArtifacts() throws {
        try makeCompleteArtifactSet()
        let artifacts = StoreRecovery.existingArtifacts(for: storeURL)

        XCTAssertEqual(artifacts.count, 4, "Expected store + wal + shm + support, got \(artifacts.map(\.lastPathComponent))")
        let names = Set(artifacts.map(\.lastPathComponent))
        XCTAssertTrue(names.contains("DevgenticSD.store"))
        XCTAssertTrue(names.contains("DevgenticSD.store-wal"))
        XCTAssertTrue(names.contains("DevgenticSD.store-shm"))
        XCTAssertTrue(names.contains(".DevgenticSD_SUPPORT"),
                      "The hidden external-storage sidecar must be discovered — it is the artifact everyone forgets.")
    }

    /// The store file must move LAST, so an interrupted move never leaves a store at the
    /// destination without the WAL that completes it.
    func testDiscoveryOrdersTheStoreFileLast() throws {
        try makeCompleteArtifactSet()
        let artifacts = StoreRecovery.existingArtifacts(for: storeURL)
        XCTAssertEqual(artifacts.last?.lastPathComponent, "DevgenticSD.store")
    }

    func testDiscoverySkipsArtifactsThatDoNotExist() throws {
        try Data("main store".utf8).write(to: storeURL)
        XCTAssertEqual(StoreRecovery.existingArtifacts(for: storeURL).count, 1)
    }

    func testTotalSizeIncludesTheExternalStorageDirectory() throws {
        try makeCompleteArtifactSet(externalBlobs: 3)
        // 3 KB of blobs alone; the sidecar must not be counted as zero just because it is a folder.
        XCTAssertGreaterThan(StoreRecovery.totalSize(for: storeURL), 3 * 1024)
    }

    // MARK: - Export (G30, G33)

    func testExportCopiesEveryArtifact() throws {
        try makeCompleteArtifactSet()
        let destination = workDirectory.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let folder = try StoreRecovery.exportCopy(of: storeURL, into: destination, folderName: "backup")

        XCTAssertTrue(exists(folder.appendingPathComponent("DevgenticSD.store")))
        XCTAssertTrue(exists(folder.appendingPathComponent("DevgenticSD.store-wal")),
                      "A copy without the WAL can be missing the newest rows.")
        XCTAssertTrue(exists(folder.appendingPathComponent("DevgenticSD.store-shm")))
        XCTAssertTrue(exists(folder.appendingPathComponent(".DevgenticSD_SUPPORT/_EXTERNAL_DATA/blob-0")),
                      "Image attachments live in the sidecar — an export without it is not a backup.")
    }

    func testExportLeavesTheOriginalUntouched() throws {
        try makeCompleteArtifactSet()
        let destination = workDirectory.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        _ = try StoreRecovery.exportCopy(of: storeURL, into: destination, folderName: "backup")

        XCTAssertEqual(StoreRecovery.existingArtifacts(for: storeURL).count, 4)
        XCTAssertEqual(try Data(contentsOf: storeURL), Data("main store".utf8))
    }

    func testExportDoesNotOverwriteAnExistingFolder() throws {
        try makeCompleteArtifactSet()
        let destination = workDirectory.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let first = try StoreRecovery.exportCopy(of: storeURL, into: destination, folderName: "backup")
        let second = try StoreRecovery.exportCopy(of: storeURL, into: destination, folderName: "backup")

        XCTAssertNotEqual(first, second, "A second export must not clobber the first.")
        XCTAssertTrue(exists(first.appendingPathComponent("DevgenticSD.store")))
        XCTAssertTrue(exists(second.appendingPathComponent("DevgenticSD.store")))
    }

    func testExportOfAMissingStoreThrows() {
        let destination = workDirectory.appendingPathComponent("exports", isDirectory: true)
        XCTAssertThrowsError(
            try StoreRecovery.exportCopy(of: storeURL, into: destination, folderName: "backup")
        )
    }

    // MARK: - Quarantine (G29, G31)

    func testQuarantineMovesEveryArtifactAndClearsTheOriginalName() throws {
        try makeCompleteArtifactSet()
        let result = try StoreRecovery.quarantine(storeURL: storeURL, suffix: "20260804-120000")

        // Nothing left under the original name — a leftover WAL would confuse a fresh store.
        XCTAssertTrue(StoreRecovery.existingArtifacts(for: storeURL).isEmpty,
                      "Original name still has artifacts: \(StoreRecovery.existingArtifacts(for: storeURL))")
        XCTAssertEqual(result.movedArtifacts.count, 4)
        XCTAssertTrue(exists(result.quarantinedStoreURL))
    }

    /// THE subtle one. Core Data names the sidecar from the store's BASE NAME, so a rename that
    /// ignores it leaves a NEW store adopting the OLD store's external blobs.
    func testQuarantineRenamesTheSupportDirectoryToMatch() throws {
        try makeCompleteArtifactSet()
        let result = try StoreRecovery.quarantine(storeURL: storeURL, suffix: "20260804-120000")

        let originalSupport = DevgenticSchema.storeArtifactURLs(for: storeURL).support
        XCTAssertFalse(exists(originalSupport),
                       """
                       .DevgenticSD_SUPPORT still sits at the original name. A newly created store \
                       would adopt the quarantined store's image blobs and own their lifecycle, \
                       which silently breaks the reversibility promise.
                       """)

        let quarantinedSupport = DevgenticSchema.storeArtifactURLs(for: result.quarantinedStoreURL).support
        XCTAssertTrue(exists(quarantinedSupport),
                      "Expected the sidecar at \(quarantinedSupport.lastPathComponent)")
        XCTAssertTrue(exists(quarantinedSupport.appendingPathComponent("_EXTERNAL_DATA/blob-0")),
                      "The blobs must travel with the quarantined store.")
    }

    func testQuarantinePreservesContentSoItIsGenuinelyReversible() throws {
        try makeCompleteArtifactSet()
        let result = try StoreRecovery.quarantine(storeURL: storeURL, suffix: "20260804-120000")

        XCTAssertEqual(try Data(contentsOf: result.quarantinedStoreURL), Data("main store".utf8))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: result.quarantinedStoreURL.path + "-wal")),
            Data("wal contents".utf8)
        )
    }

    /// Quarantining twice in the same second must not collide — the user may click it repeatedly,
    /// and the second attempt must never overwrite the first rescue.
    func testRepeatedQuarantineWithTheSameSuffixDoesNotOverwrite() throws {
        try makeCompleteArtifactSet()
        let first = try StoreRecovery.quarantine(storeURL: storeURL, suffix: "20260804-120000")

        try makeCompleteArtifactSet()
        let second = try StoreRecovery.quarantine(storeURL: storeURL, suffix: "20260804-120000")

        XCTAssertNotEqual(first.quarantinedStoreURL, second.quarantinedStoreURL)
        XCTAssertTrue(exists(first.quarantinedStoreURL), "The first quarantine was clobbered.")
        XCTAssertTrue(exists(second.quarantinedStoreURL))
    }

    /// A collision on the SIDECAR alone must also be detected — an earlier partial quarantine can
    /// leave `.DevgenticSD-quarantined-X_SUPPORT` behind with no matching store file.
    func testQuarantineDetectsACollisionOnTheSupportDirectoryAlone() throws {
        try makeCompleteArtifactSet()
        let squatter = workDirectory.appendingPathComponent(".DevgenticSD-quarantined-20260804-120000_SUPPORT")
        try FileManager.default.createDirectory(at: squatter, withIntermediateDirectories: true)

        let result = try StoreRecovery.quarantine(storeURL: storeURL, suffix: "20260804-120000")

        XCTAssertNotEqual(result.quarantinedStoreURL.lastPathComponent,
                          "DevgenticSD-quarantined-20260804-120000.store",
                          "Picked a base name whose sidecar was already occupied.")
        XCTAssertTrue(exists(squatter), "The pre-existing sidecar must be left alone.")
    }

    func testQuarantineOfAMissingStoreThrows() {
        XCTAssertThrowsError(try StoreRecovery.quarantine(storeURL: storeURL, suffix: "x")) { error in
            guard case StoreRecoveryError.nothingToMove = error else {
                return XCTFail("Expected .nothingToMove, got \(error)")
            }
        }
    }

    /// A stray sidecar from an interrupted earlier quarantine must be treated as a COLLISION, not
    /// walked into. Before the fix this base name looked free (no store, no support directory), so
    /// the `-wal` move failed mid-sequence and forced an avoidable rollback.
    func testQuarantineDetectsACollisionOnAStraySidecarAlone() throws {
        try makeCompleteArtifactSet()
        let strayWAL = workDirectory
            .appendingPathComponent("DevgenticSD-quarantined-20260804-120000.store-wal")
        try Data("leftover from an interrupted quarantine".utf8).write(to: strayWAL)

        let result = try StoreRecovery.quarantine(storeURL: storeURL, suffix: "20260804-120000")

        XCTAssertNotEqual(result.quarantinedStoreURL.lastPathComponent,
                          "DevgenticSD-quarantined-20260804-120000.store",
                          "Chose a base name whose -wal destination was already occupied.")
        XCTAssertEqual(try Data(contentsOf: strayWAL),
                       Data("leftover from an interrupted quarantine".utf8),
                       "The pre-existing sidecar must be left untouched.")
        XCTAssertEqual(result.movedArtifacts.count, 4)
    }

    /// THE safety property. If any artifact cannot move, everything already moved goes back —
    /// because a store split across two names is worse than a store that never moved.
    ///
    /// The failure is injected with the BSD immutable flag on the store file. That is deterministic
    /// and, crucially, invisible to the collision check: the destination name is genuinely free, so
    /// the sidecars all move first and the failure lands on the LAST artifact — exactly the
    /// mid-sequence case rollback exists for.
    func testFailedQuarantineRollsBackCompletely() throws {
        try makeCompleteArtifactSet()
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: storeURL.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: storeURL.path) }

        XCTAssertThrowsError(try StoreRecovery.quarantine(storeURL: storeURL, suffix: "blocked")) { error in
            guard case StoreRecoveryError.moveFailed(let artifact, _, let rolledBack) = error else {
                return XCTFail("Expected .moveFailed, got \(error)")
            }
            XCTAssertEqual(artifact, "DevgenticSD.store", "The store file should be the one that failed.")
            XCTAssertTrue(rolledBack, "Rollback did not complete — the store is split across two names.")
        }

        // Everything must be exactly where it started.
        let restored = StoreRecovery.existingArtifacts(for: storeURL)
        XCTAssertEqual(restored.count, 4,
                       "Rollback left \(restored.count)/4 artifacts: \(restored.map(\.lastPathComponent))")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: storeURL.path + "-wal")),
                       Data("wal contents".utf8))
        XCTAssertTrue(exists(DevgenticSchema.storeArtifactURLs(for: storeURL).support
                                .appendingPathComponent("_EXTERNAL_DATA/blob-0")),
                      "The sidecar must be restored to its original name too.")

        // And nothing may be left under the quarantine name.
        XCTAssertTrue(
            StoreRecovery.existingArtifacts(
                for: workDirectory.appendingPathComponent("DevgenticSD-quarantined-blocked.store")
            ).isEmpty,
            "Artifacts were stranded under the quarantine name."
        )
    }

    // MARK: - Companion stores (G32)

    /// A SwiftData reset does not touch the vector index, media cache or diagnostics database.
    /// They must be enumerable so the confirmation dialog can say so rather than implying a
    /// completeness it does not deliver.
    func testCompanionStoresAreReportedWhenTheyExist() throws {
        let companions = StoreRecovery.companionStores(bundleIdentifier: "app.devgentic.macos")
        // Only existing ones are returned, so on a clean machine this is legitimately empty;
        // assert the contract rather than a machine-specific count.
        for companion in companions {
            XCTAssertTrue(exists(companion.url), "Reported a companion that does not exist: \(companion.url.path)")
            XCTAssertFalse(companion.label.isEmpty)
        }
        XCTAssertEqual(Set(companions.map(\.label)).count, companions.count, "Duplicate labels.")
    }

    func testCompanionStoresToleratesAMissingBundleIdentifier() {
        let companions = StoreRecovery.companionStores(bundleIdentifier: nil)
        XCTAssertFalse(companions.contains { $0.label == "Vector search index" },
                       "Without a bundle id the vector-db path cannot be derived; it must be omitted.")
    }
}

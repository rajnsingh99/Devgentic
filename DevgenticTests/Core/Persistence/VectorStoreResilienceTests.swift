// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  VectorStoreResilienceTests.swift
//  DevgenticTests
//
//  Created on 04/08/26.
//
//  Guards G73 — the SECOND store that could brick launch.
//
//  `VectorStoreService.init` ended in `fatalError("Could not initialize ObjectBox store")`, on the
//  same cold launch path as the SwiftData container. A corrupt or unwritable vector-db therefore
//  KILLED THE APP — no message, no path, no dialog — for a store the app does not need to function.
//  The vector index is semantic-memory retrieval; without it chats, profiles, tools and workflows
//  all work and only RAG recall degrades. That is a feature outage, not grounds for refusing to
//  launch.
//
//  Its `wipeAndStamp` branch was separately the one place in the app that DELETED user data
//  silently and without consent — and this data cannot be rebuilt, because there is no
//  reindex-from-transcripts mechanism. It now quarantines instead.
//

import XCTest
@testable import devgentic

final class VectorStoreResilienceTests: XCTestCase {

    private var workDirectory: URL!
    private let logger = DGLogger(category: "VectorStoreResilienceTests")

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VectorStoreResilience-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
        workDirectory = nil
        try super.tearDownWithError()
    }

    private func makeStoreDirectory(named name: String = "vector-db", fileCount: Int = 3) throws -> URL {
        let url = workDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for index in 0..<fileCount {
            try Data(repeating: UInt8(index), count: 512)
                .write(to: url.appendingPathComponent("data-\(index).mdb"))
        }
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func supersededURL(for store: URL) -> URL {
        store.deletingLastPathComponent()
            .appendingPathComponent(store.lastPathComponent + "-superseded", isDirectory: true)
    }

    // MARK: - The destructive path now quarantines

    /// THE guarantee: nothing is deleted. The old index is moved, not removed.
    func testSupersededStoreIsMovedAsideNotDeleted() throws {
        let store = try makeStoreDirectory()
        VectorStoreService.quarantineSupersededStore(at: store, previousVersion: 1, logger: logger)

        XCTAssertFalse(exists(store), "The old index must be cleared out of the live path.")
        let aside = supersededURL(for: store)
        XCTAssertTrue(exists(aside), "The old index must still exist, moved aside.")
        XCTAssertTrue(exists(aside.appendingPathComponent("data-0.mdb")),
                      "Its contents must travel with it — this data cannot be rebuilt.")
    }

    /// ⚠️ Exactly ONE generation is retained. A timestamped name would accumulate forever, which is
    /// its own bug; keeping zero would be the delete this change exists to remove.
    func testOnlyOneSupersededGenerationIsKept() throws {
        let first = try makeStoreDirectory(fileCount: 1)
        VectorStoreService.quarantineSupersededStore(at: first, previousVersion: 1, logger: logger)

        // A second schema bump, with different contents so we can tell the generations apart.
        let second = try makeStoreDirectory(fileCount: 2)
        try Data("newer".utf8).write(to: second.appendingPathComponent("marker.txt"))
        VectorStoreService.quarantineSupersededStore(at: second, previousVersion: 2, logger: logger)

        let aside = supersededURL(for: second)
        XCTAssertTrue(exists(aside.appendingPathComponent("marker.txt")),
                      "The newest superseded generation must be the one retained.")

        let siblings = try FileManager.default.contentsOfDirectory(atPath: workDirectory.path)
            .filter { $0.contains("superseded") }
        XCTAssertEqual(siblings.count, 1, "Superseded copies must not accumulate: \(siblings)")
    }

    /// A missing store directory is a no-op, not a crash — the first-launch case.
    func testQuarantineOfAMissingStoreIsHarmless() {
        let absent = workDirectory.appendingPathComponent("never-existed", isDirectory: true)
        VectorStoreService.quarantineSupersededStore(at: absent, previousVersion: nil, logger: logger)
        XCTAssertFalse(exists(absent))
        XCTAssertFalse(exists(supersededURL(for: absent)))
    }

    /// ⚠️ If the move fails, the old index must be LEFT IN PLACE — never deleted as a fallback.
    /// Falling back to a delete would reintroduce the exact irreversibility this change removes.
    func testAFailedQuarantineLeavesTheOldIndexIntact() throws {
        let store = try makeStoreDirectory()
        // Make the parent unwritable so the rename cannot succeed.
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: workDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: workDirectory.path)
        }

        VectorStoreService.quarantineSupersededStore(at: store, previousVersion: 1, logger: logger)

        XCTAssertTrue(exists(store), "A failed quarantine must not delete the old index.")
        XCTAssertTrue(exists(store.appendingPathComponent("data-0.mdb")),
                      "Its contents must be untouched.")
    }

    // MARK: - Degradation instead of a launch trap

    /// The singleton constructs without trapping. This is weak on its own — a healthy machine takes
    /// the success path — but every test run boots the app host, so a regression to `fatalError`
    /// would take the whole SUITE down rather than failing one assertion.
    func testServiceConstructsAndReportsAvailability() {
        let service = VectorStoreService.shared
        XCTAssertTrue(service.isAvailable,
                      "The store failed to open on this machine; retrieval is disabled for the run.")
    }

    /// ⚠️ VERIFICATION GAP, stated rather than faked: the DEGRADED path (`isAvailable == false`)
    /// cannot be exercised here. `VectorStoreService` is a singleton that opens a real ObjectBox
    /// store at a fixed Application Support path, with no injection seam, so a test cannot force it
    /// to fail without corrupting the developer's actual vector-db. What IS verified: the guards
    /// exist and compile on every call site, the quarantine is covered above, and `init` no longer
    /// contains a `fatalError`.
    ///
    /// Making the failure path testable means giving the service an injectable directory — worth
    /// doing, out of scope here.
    func testDegradedPathIsDocumentedAsUnverified() throws {
        // ⚠️ SKIP, not `XCTAssertTrue(true)`.
        //
        // The previous placeholder always passed, so the suite counted it toward the green total and
        // reported this path as VERIFIED. It is not verified — that is the entire point of the doc
        // comment above. A skip reports "not checked", which is the truth, and it stays visible in
        // every run instead of blending into the pass count.
        throw XCTSkip(
            "DEGRADED PATH NOT VERIFIED: VectorStoreService is a singleton opening a fixed "
            + "Application Support path with no injection seam, so `isAvailable == false` cannot be "
            + "forced without corrupting the developer's real vector-db. Give the service an "
            + "injectable directory to close this."
        )
    }
}

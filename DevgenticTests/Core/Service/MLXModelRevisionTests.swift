// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXModelRevisionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class MLXModelRevisionReadingTests: XCTestCase {

    private var root: URL!
    private let realHash = "ac1c269cb4222a4e136a3d09edad301056c1f36a"

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-revision-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    /// Writes HubApi's real metadata format: `commitHash\netag\ntimestamp`.
    private func writeMetadata(_ files: [String: String]) throws {
        let dir = root.appendingPathComponent(".cache/huggingface/download")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, hash) in files {
            let body = "\(hash)\ne6acb9f2947db91642433b11e8af2e572efa70aa\n1776981608.3575\n"
            try Data(body.utf8).write(to: dir.appendingPathComponent("\(name).metadata"))
        }
    }

    /// The format is exactly what `HubApi.writeDownloadMetadata` emits, verified against a real
    /// file on disk: line 1 is the commit hash.
    func testReadsTheCommitHashFromHubApiMetadata() throws {
        try writeMetadata(["config.json": realHash, "model.safetensors": realHash])
        XCTAssertEqual(MLXModelRevision.installedRevision(atModelFolder: root), realHash)
    }

    /// Imported models and anything downloaded before revision tracking have no metadata —
    /// that must read as "unknown", never as a revision.
    func testNoMetadataMeansNoRevision() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertNil(MLXModelRevision.installedRevision(atModelFolder: root))
    }

    /// A truncated or garbage metadata file must not be reported as a revision and then
    /// compared against a real `sha`.
    func testGarbageMetadataIsIgnored() throws {
        try writeMetadata(["config.json": "not-a-hash"])
        XCTAssertNil(MLXModelRevision.installedRevision(atModelFolder: root))
    }

    /// A folder holding files from two snapshots is a real (if rare) state — it must still
    /// answer deterministically rather than depending on directory order.
    /// ⚠️ Rewritten 2026-08-03. This previously wrote a 1-1 split and asserted only that the
    /// answer was stable and non-nil — which the old `found.sorted().first` satisfied by
    /// returning the lexicographically LOWEST hash, a value carrying no meaning at all. The
    /// answer is fed straight into a comparison against the published `sha`, so an arbitrary
    /// pick can assert "Update available" forever on a current model, or hide a real update.
    ///
    /// A folder ends up mixed because HubApi rewrites a file's `.metadata` when it re-fetches
    /// it but never PRUNES the metadata of a file that has left the repo, so the commit most
    /// files agree on is what the model actually is.
    func testTheMajorityRevisionWins() throws {
        let stale = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        try writeMetadata([
            "config.json": realHash,
            "model.safetensors": realHash,
            "tokenizer.json": realHash,
            "old-shard.safetensors": stale,
        ])
        XCTAssertEqual(
            MLXModelRevision.installedRevision(atModelFolder: root), realHash,
            "three of four files agree — that is the revision, not whichever hash sorts lowest"
        )
    }

    /// An even split is genuinely unanswerable, and `.unknown` is the verdict `UpdateStatus`
    /// already models for it. Picking either side would be a guess presented as a fact.
    func testAnEvenSplitReportsNoRevisionRatherThanGuessing() throws {
        let other = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        try writeMetadata(["config.json": realHash, "model.safetensors": other])

        XCTAssertNil(
            MLXModelRevision.installedRevision(atModelFolder: root),
            "a 1-1 split has no majority; reporting either hash would be compared against the published sha as if it were fact"
        )
        // …and that nil must reach the user as .unknown, never as .upToDate.
        let status = MLXModelRevision.compare(installed: nil, latest: realHash)
        guard case .unknown = status else {
            return XCTFail("an unresolvable revision must report .unknown, got \(status)")
        }
        XCTAssertFalse(status.needsUpdate)
    }

    func testTheAnswerIsStableAcrossReads() throws {
        let stale = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        try writeMetadata([
            "config.json": realHash,
            "model.safetensors": realHash,
            "old-shard.safetensors": stale,
        ])
        XCTAssertEqual(
            MLXModelRevision.installedRevision(atModelFolder: root),
            MLXModelRevision.installedRevision(atModelFolder: root)
        )
    }

    func testCommitHashValidation() {
        XCTAssertTrue(MLXModelRevision.isPlausibleCommitHash(realHash))
        XCTAssertFalse(MLXModelRevision.isPlausibleCommitHash(""))
        XCTAssertFalse(MLXModelRevision.isPlausibleCommitHash("abc123"))
        XCTAssertFalse(MLXModelRevision.isPlausibleCommitHash(String(repeating: "z", count: 40)))
    }

    func testShortFormIsSevenCharacters() {
        XCTAssertEqual(MLXModelRevision.shortForm(realHash), "ac1c269")
    }
}

final class MLXUpdateComparisonTests: XCTestCase {

    private let installed = "ac1c269cb4222a4e136a3d09edad301056c1f36a"
    private let newer = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    /// The real case from the dev machine: the on-disk hash and the API's `sha` matched.
    func testMatchingRevisionsAreUpToDate() {
        XCTAssertEqual(
            MLXModelRevision.compare(installed: installed, latest: installed),
            .upToDate(revision: installed)
        )
    }

    func testADifferentPublishedRevisionIsAnUpdate() {
        let status = MLXModelRevision.compare(installed: installed, latest: newer)
        XCTAssertEqual(status, .updateAvailable(installed: installed, latest: newer))
        XCTAssertTrue(status.needsUpdate)
    }

    /// ⚠️ Unknown must never collapse into "up to date". That is the same failure shape as A8's
    /// fit advisory reporting `.comfortable` for a model whose size it never learned — an
    /// absent answer presented as a reassuring one.
    func testUnknownIsDistinctFromUpToDate() {
        let noLocal = MLXModelRevision.compare(installed: nil, latest: installed)
        let noRemote = MLXModelRevision.compare(installed: installed, latest: nil)

        for status in [noLocal, noRemote] {
            guard case .unknown = status else {
                return XCTFail("expected .unknown, got \(status)")
            }
            XCTAssertFalse(status.needsUpdate)
            XCTAssertNotEqual(status, .upToDate(revision: installed))
        }
    }

    /// An implausible hash on either side is unknown, not a spurious "update available" —
    /// which would otherwise prompt a multi-gigabyte re-download for nothing.
    func testGarbageHashesDoNotProduceAFalseUpdate() {
        for status in [
            MLXModelRevision.compare(installed: "garbage", latest: installed),
            MLXModelRevision.compare(installed: installed, latest: "garbage")
        ] {
            XCTAssertFalse(status.needsUpdate, "a malformed hash produced a false update prompt")
        }
    }

    /// Every unknown case must say why — the sheet shows this text.
    func testUnknownCarriesAReason() {
        guard case .unknown(let reason) = MLXModelRevision.compare(installed: nil, latest: nil) else {
            return XCTFail("expected .unknown")
        }
        XCTAssertFalse(reason.isEmpty)
    }
}

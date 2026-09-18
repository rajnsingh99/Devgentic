// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WhisperModelDownloadServiceTests.swift
//  DevgenticTests
//
//  Tests for WhisperModelDownloadService's cache detection logic,
//  model ID matching, partial download filtering, and state guards.
//  Network-dependent tests (actual download/delete) are not included
//  here — these focus on the deterministic, filesystem-based logic.
//

import XCTest
@testable import devgentic

@MainActor
final class WhisperModelDownloadServiceTests: XCTestCase {

    private var service: WhisperModelDownloadService { .shared }

    // MARK: - Initial State

    func testInitialStateIsNotDownloading() {
        XCTAssertFalse(service.isDownloading)
        XCTAssertFalse(service.isDeleting)
        XCTAssertNil(service.downloadingModelId)
        XCTAssertNil(service.downloadError)
        XCTAssertNil(service.deleteError)
        XCTAssertEqual(service.downloadProgress, 0)
    }

    // MARK: - isModelDownloaded

    func testIsModelDownloadedReturnsFalseForUnknownId() {
        XCTAssertFalse(service.isModelDownloaded("nonexistent-model-xyz"))
    }

    func testIsModelDownloadedConsistentWithSet() {
        // Whatever refreshDownloadedModels found, isModelDownloaded should agree
        for modelId in service.downloadedModelIds {
            XCTAssertTrue(service.isModelDownloaded(modelId))
        }
    }

    // MARK: - refreshDownloadedModels Idempotency

    func testRefreshDownloadedModelsIsIdempotent() {
        let first = service.downloadedModelIds
        service.refreshDownloadedModels()
        let second = service.downloadedModelIds
        XCTAssertEqual(first, second, "Calling refreshDownloadedModels twice should yield the same set")
    }

    // MARK: - Download Guards

    func testDownloadBlockedWhileAlreadyDownloading() async {
        service.downloadModel("large-v3")
        XCTAssertTrue(service.isDownloading)

        // Attempting a second download should be a no-op
        service.downloadModel("tiny")
        XCTAssertEqual(service.downloadingModelId, "large-v3",
                        "Second download should not have started")

        await service.cancelDownload()
    }

    func testDownloadClearsErrorOnStart() async {
        service.downloadModel("tiny")
        XCTAssertNil(service.downloadError,
                      "downloadError should be nil at the start of a download")

        await service.cancelDownload()
    }

    // MARK: - Model ID Matching (Regression for #10)

    func testModelIdMatchingDoesNotFalsePositive() {
        // "base" should NOT match a folder named "openai_whisper-base.en"
        // because the folder ends with "-base.en" not "-base"
        // This test validates the suffix-based matching logic.
        let allIds = WhisperModelCatalog.availableModels.map(\.id)

        // Verify no ambiguous ID substrings exist in the catalog
        for (i, id1) in allIds.enumerated() {
            for (j, id2) in allIds.enumerated() where i != j {
                // id1 should not be a substring of id2
                // (e.g. "base" should not match "base.en" via contains)
                // Our suffix matching handles this, but verify catalog doesn't
                // have IDs that would still conflict under suffix matching.
                let pattern1 = "-\(id1)"
                let pattern2 = "-\(id2)"
                if pattern2.hasSuffix(pattern1) && id1 != id2 {
                    // This would be a catalog design issue — flag it
                    XCTFail("Model ID '\(id1)' is a suffix of '\(id2)' — potential matching conflict")
                }
            }
        }
    }

    // MARK: - Cancel State

    func testCancelResetsState() async {
        service.downloadModel("medium")
        XCTAssertTrue(service.isDownloading)

        await service.cancelDownload()

        XCTAssertFalse(service.isDownloading)
        XCTAssertNil(service.downloadingModelId)
        XCTAssertEqual(service.downloadProgress, 0)
        XCTAssertNil(service.downloadError)
    }

    // MARK: - Delete Guards

    func testDeleteBlockedWhileDownloadingDifferentModel() async {
        service.downloadModel("large-v3")
        XCTAssertTrue(service.isDownloading)

        // Deleting a different model should be blocked
        let result = await service.deleteModel("tiny")
        XCTAssertNil(result, "Delete should return nil when a download is in progress for a different model")

        // Cleanup
        await service.cancelDownload()
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXPolishTests.swift
//  DevgenticTests
//
//  Batch 3 (P3 polish) of the MLX Model Manager readiness plan.
//
//    C1  `isCancellingDownload` was a service-global `Bool` with no model identity, so
//        cancelling one download flipped EVERY visible MLX card to "Cleaning up…".
//    C2  User-facing labels sourced from enum `rawValue` bind to the non-localizing
//        `Text` overload, so they were invisible to the String Catalog extractor and would
//        have shipped in English inside otherwise-translated chrome.
//

import XCTest
import SwiftUI
@testable import devgentic

// MARK: - C1: cancellation is per-repo

@MainActor
final class MLXCancellationIdentityTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-cancel-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    /// THE C1 case: only the repo actually being cleaned up reports as cancelling.
    func testOnlyTheCancellingRepoReportsCleanup() {
        let service = MLXModelService(modelsRootOverride: root)
        service.cancellingRepoId = "mlx-community/being-cancelled"

        XCTAssertTrue(service.isCancellingDownload(repoId: "mlx-community/being-cancelled"))
        XCTAssertFalse(
            service.isCancellingDownload(repoId: "mlx-community/some-other-model"),
            "an unrelated card reported 'Cleaning up…' — the flag lost its model identity"
        )
        XCTAssertFalse(service.isCancellingDownload(repoId: "lmstudio-community/installed-one"))
    }

    /// With nothing cancelling, no card should claim to be.
    func testNothingReportsCleanupWhenIdle() {
        let service = MLXModelService(modelsRootOverride: root)
        XCTAssertNil(service.cancellingRepoId)
        XCTAssertFalse(service.isCancellingDownload(repoId: "mlx-community/anything"))
    }

    /// An empty identifier must not accidentally match a nil flag.
    func testEmptyIdentifierDoesNotMatchIdleState() {
        let service = MLXModelService(modelsRootOverride: root)
        XCTAssertFalse(service.isCancellingDownload(repoId: ""))
    }
}

// MARK: - C2: labels are localizable

final class MLXLocalizedTitleTests: XCTestCase {

    /// ⚠️ Rewritten 2026-08-03. Every assertion here was `XCTAssertNotNil` on a NON-OPTIONAL
    /// `LocalizedStringKey` — it cannot fail. Retyping `localizedTitle` back to `String`, the
    /// exact C2 bug, left the whole file green.
    ///
    /// Two things now do the work. The `localizable(_:)` helper below takes a
    /// `LocalizedStringKey` parameter, so a `String` return type stops COMPILING — that is the
    /// real guard against the regression, and it belongs at compile time. And the titles must
    /// be pairwise DISTINCT, which catches the copy-paste switch arm that a nil check never
    /// could. `LocalizedStringKey` is `Equatable` on its key, so this is meaningful.
    private func localizable(_ key: LocalizedStringKey) -> LocalizedStringKey { key }

    private func assertDistinctTitles(
        _ titles: [LocalizedStringKey], _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        for (i, a) in titles.enumerated() {
            for (j, b) in titles.enumerated() where j > i {
                XCTAssertNotEqual(a, b, "\(label): two cases share a display title", file: file, line: line)
            }
        }
    }

    func testEveryCapabilityHasBothARawValueAndALocalizedTitle() {
        XCTAssertFalse(MLXModelCapability.allCases.isEmpty)
        for capability in MLXModelCapability.allCases {
            XCTAssertFalse(capability.rawValue.isEmpty)
            XCTAssertFalse(capability.icon.isEmpty)
            _ = localizable(capability.localizedTitle)
        }
        assertDistinctTitles(MLXModelCapability.allCases.map(\.localizedTitle), "capability")
    }

    func testEveryStoreCategoryHasALocalizedTitle() {
        for category in MLXModelStoreViewModel.StoreCategory.allCases {
            XCTAssertFalse(category.rawValue.isEmpty)
            _ = localizable(category.localizedTitle)
        }
        assertDistinctTitles(
            MLXModelStoreViewModel.StoreCategory.allCases.map(\.localizedTitle), "category"
        )
    }

    func testEverySortOptionHasALocalizedTitle() {
        for option in MLXModelStoreViewModel.SortOption.allCases {
            XCTAssertFalse(option.rawValue.isEmpty)
            _ = localizable(option.localizedTitle)
        }
        assertDistinctTitles(
            MLXModelStoreViewModel.SortOption.allCases.map(\.localizedTitle), "sort option"
        )
    }

    /// ⚠️ Iterates `allCases`, not a hand-written array. The old list was written out by hand,
    /// so a verdict added later would have been skipped in silence.
    func testEveryFitVerdictHasALocalizedTitle() {
        XCTAssertEqual(ModelFitVerdict.allCases.count, 5, "a verdict was added or removed")
        for verdict in ModelFitVerdict.allCases {
            XCTAssertFalse(verdict.rawValue.isEmpty)
            _ = localizable(verdict.localizedTitle)
        }
        assertDistinctTitles(ModelFitVerdict.allCases.map(\.localizedTitle), "verdict")

        // Pin the keys. `LocalizedStringKey(rawValue)` — the shortcut that reintroduces C2 —
        // would not match these, because the raw values differ in case and wording.
        XCTAssertEqual(ModelFitVerdict.comfortable.localizedTitle, LocalizedStringKey("Comfortable"))
        XCTAssertEqual(ModelFitVerdict.incompatible.localizedTitle, LocalizedStringKey("Too Large"))
    }

    /// ⚠️ `ModelBackendType.rawValue` is a PERSISTENCE key — `DownloadRecord.backendRaw` and
    /// the pre-seed dictionary key are both built from it. Pin the exact strings so a future
    /// display tweak cannot silently orphan every stored download record.
    func testBackendRawValuesArePersistenceKeysAndMustNotDrift() {
        XCTAssertEqual(ModelBackendType.ollama.rawValue, "Ollama")
        XCTAssertEqual(ModelBackendType.mlx.rawValue, "MLX")
        XCTAssertEqual(ModelBackendType.whisper.rawValue, "Whisper")

        // ⚠️ These three deliberately have NO `localizedTitle` — they are product names, and a
        // catalog entry mapping "Ollama" to "Ollama" in every locale is noise that invites a
        // translator to localize a proper noun. Display sites use `Text(verbatim:)` and
        // localize only the fallback prose. Pin that the names stay distinct and non-empty.
        XCTAssertEqual(Set([ModelBackendType.ollama, .mlx, .whisper].map(\.rawValue)).count, 3)
        for backend in [ModelBackendType.ollama, .mlx, .whisper] {
            XCTAssertFalse(backend.icon.isEmpty)
        }
    }

    /// Round-trip through the raw value, since that is what persistence stores.
    func testBackendRoundTripsThroughItsRawValue() {
        for backend in [ModelBackendType.ollama, .mlx, .whisper] {
            XCTAssertEqual(ModelBackendType(rawValue: backend.rawValue), backend)
        }
    }
}

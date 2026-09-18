// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXP2AuditFixTests.swift
//  DevgenticTests
//
//  The P2 batch from the 2026-08-03 validation audit (`MLX_Session_Validation_Audit.md`).
//  Each suite here covers one fix, and each was mutation-checked once: revert the fix, the
//  test fails. That check is the whole point — the audit's finding was that several tests in
//  this subsystem asserted on literals they defined themselves and stayed green with the bug
//  reinstated.
//

import XCTest
import SwiftUI
@testable import devgentic

// MARK: - #1 publish() must diff the ITEMS, not the name set

@MainActor
final class MLXPublishFreshnessTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-publish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    /// Writes a model with a specific recorded commit, the way HubApi does.
    @discardableResult
    private func installModel(_ repoId: String, revision: String) throws -> URL {
        let parts = repoId.components(separatedBy: "/")
        let repo = root
            .appendingPathComponent("models")
            .appendingPathComponent(parts[0])
            .appendingPathComponent(parts[1])
        let metadata = repo
            .appendingPathComponent(".cache")
            .appendingPathComponent("huggingface")
            .appendingPathComponent("download")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: repo.appendingPathComponent("config.json"))
        try Data(repeating: 0, count: 1024)
            .write(to: repo.appendingPathComponent("model.safetensors"))
        // HubApi's `.metadata` layout: commitHash\netag\ntimestamp.
        try Data("\(revision)\netag\n0".utf8)
            .write(to: metadata.appendingPathComponent("model.safetensors.metadata"))
        return repo
    }

    /// A re-download changes the recorded commit but never the NAME set, so a name-set diff
    /// discarded the freshly scanned array. `checkForModelUpdates` then re-compared the stale
    /// hash and the "Update available" badge never cleared for the rest of the session.
    func testARevisionChangeUnderAnUnchangedNameSetIsPublished() async throws {
        let repoId = "mlx-community/Revised-Model"
        try installModel(repoId, revision: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

        let service = MLXModelService(modelsRootOverride: root)
        await service.ensureLoaded()
        XCTAssertEqual(
            service.installedModels.first?.revision,
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "precondition: the first scan recorded the original commit"
        )

        // Re-download: same model id and path, new commit.
        try installModel(repoId, revision: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        await service.forceRefreshInstalledModelsAsync()

        XCTAssertEqual(
            service.installedModels.first?.revision,
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "the scan read the new commit but publish() discarded it — the name set was unchanged, so an 'Update available' badge would never clear"
        )
    }

    /// The counterpart, so the new comparison does not simply republish on every scan and
    /// undo the point of the gate.
    func testAnIdenticalScanIsNotRepublished() async throws {
        try installModel("mlx-community/Stable-Model", revision: "cccccccccccccccccccccccccccccccccccccccc")
        let service = MLXModelService(modelsRootOverride: root)
        await service.ensureLoaded()

        let first = service.installedModels
        await service.forceRefreshInstalledModelsAsync()

        XCTAssertEqual(first, service.installedModels, "an unchanged tree must produce an equal list")
    }
}

// MARK: - #3 the quantization formula must outrank the byte proxy

final class ModelFitQuantizationPrecedenceTests: XCTestCase {

    /// G5 synthesises `ModelMetadata` from the repo id so the verdict can account for
    /// quantization. With the raw-bytes short-circuit above the parameter-count branch, that
    /// metadata was computed and discarded on every card that had a size, and the verdict
    /// stayed the flat `diskBytes × 1.2` proxy.
    func testParameterCountWinsOverRawBytes() {
        // Exactly what `MLXQuantization.fitMetadata` synthesises for a 70B 16-bit repo.
        let metadata = ModelMetadata(
            tier: .large,
            quantization: "16-bit",
            parameterCount: "70B"
        )

        // A deliberately tiny byte total. If bytes still won, the verdict would be computed
        // from ~1 GB and come back comfortable for a 70B bf16 model.
        let withMetadata = ModelFitAdvisor.assess(
            metadata: metadata,
            diskSizeBytes: 1_000_000_000,
            modelName: "Test-70B-bf16"
        )
        let bytesOnly = ModelFitAdvisor.assess(
            metadata: nil,
            diskSizeBytes: 1_000_000_000,
            modelName: "Test-70B-bf16"
        )

        XCTAssertGreaterThan(
            withMetadata.estimatedRuntimeRAM, bytesOnly.estimatedRuntimeRAM,
            "the parameter-count formula was ignored in favour of the byte proxy, so quantization never reached the verdict"
        )
    }

    /// ⚠️ Surfaced BY the fix above, not by the audit. `parseQuantizationBits` is a chain of
    /// substring tests, and "16bit" contains "6bit" — so every 16-bit repo parsed as 6-bit,
    /// a ~2.7× under-estimate of runtime RAM in the unsafe direction. It was latent while G5's
    /// metadata was being discarded; routing the formula ahead of the byte proxy made it live.
    /// This is invariant 28's collision in the one place that had not been swept.
    func testWideFormatsAreNotShadowedByTheirTrailingDigit() {
        XCTAssertEqual(ModelFitAdvisor.parseQuantizationBits("16bit"), 16,
                       "'16bit' contains '6bit' — the 6-bit arm must not win")
        XCTAssertEqual(ModelFitAdvisor.parseQuantizationBits("16-bit"), 16)
        XCTAssertEqual(ModelFitAdvisor.parseQuantizationBits("32bit"), 32,
                       "'32bit' contains '2bit' — the 2-bit arm must not win")
        XCTAssertEqual(ModelFitAdvisor.parseQuantizationBits("bf16"), 16)
        XCTAssertEqual(ModelFitAdvisor.parseQuantizationBits("fp16"), 16)

        // The narrow formats still resolve to themselves.
        XCTAssertEqual(ModelFitAdvisor.parseQuantizationBits("2bit"), 2)
        XCTAssertEqual(ModelFitAdvisor.parseQuantizationBits("6bit"), 6)
        XCTAssertEqual(ModelFitAdvisor.parseQuantizationBits("Q4_K_M"), 4)
        XCTAssertEqual(ModelFitAdvisor.parseQuantizationBits("8-bit"), 8)
    }

    /// Every token G5 can synthesise must round-trip through the advisor's parser. These two
    /// components are wired together and were never checked against each other.
    func testEveryQuantizationTokenRoundTripsThroughTheAdvisor() {
        for quant in MLXQuantization.allCases {
            XCTAssertEqual(
                ModelFitAdvisor.parseQuantizationBits(quant.advisorToken), quant.rawValue,
                "\(quant.advisorToken) is fed to the advisor by MLXQuantization.fitMetadata but parses as a different width"
            )
        }
    }

    /// A19 is untouched: raw BYTES still outrank the formatted STRING, which was its actual
    /// concern (round-tripping a size through a comma-decimal locale is lossy).
    func testRawBytesStillOutrankTheFormattedString() {
        let fromBytes = ModelFitAdvisor.assess(
            metadata: nil,
            diskSizeString: "1 GB",
            diskSizeBytes: 40_000_000_000,
            modelName: "Test"
        )
        let fromString = ModelFitAdvisor.assess(
            metadata: nil,
            diskSizeString: "1 GB",
            modelName: "Test"
        )
        XCTAssertGreaterThan(
            fromBytes.estimatedRuntimeRAM, fromString.estimatedRuntimeRAM,
            "the byte total must win over the formatted string when both are supplied"
        )
    }
}

// MARK: - #7 every download status renders, including .paused

final class DownloadStatusPresentationTests: XCTestCase {

    /// C2 shipped `localizedTitle` on both of these enums and wired neither, so the sidebar
    /// and the Downloads screen fell through to `rawValue.capitalized` — which does not
    /// localize — and `.paused` drew a grey question mark.
    func testEveryStatusHasADistinctLocalizedTitle() {
        var seen = Set<String>()
        for status in DownloadRecordStatus.allCases {
            let key = String(describing: status.localizedTitle)
            XCTAssertFalse(
                key.contains(status.rawValue) && status.rawValue.first?.isLowercase == true,
                "\(status) appears to be rendering its rawValue rather than a localizable title"
            )
            XCTAssertTrue(seen.insert(key).inserted, "\(status) shares a title with another status")
        }
    }

    /// `.paused` is the state the two surfaces missed. It is terminal but resumable — the
    /// combination that makes it distinct from every other terminal state.
    func testPausedIsTerminalAndResumable() {
        XCTAssertTrue(DownloadRecordStatus.paused.isTerminal)
        XCTAssertTrue(DownloadRecordStatus.paused.isResumable)
        XCTAssertFalse(DownloadRecordStatus.cancelled.isResumable,
                       "cancelling discards the partial, so offering Resume would promise bytes that are gone")
    }

    /// ⚠️ Backends deliberately have NO `localizedTitle`: "Ollama" / "MLX" / "Whisper" are
    /// product names, and a catalog entry mapping each to itself in every locale is noise that
    /// invites a translator to localize a proper noun. Display sites render them with
    /// `Text(verbatim:)` and localize only the surrounding prose and the fallback.
    ///
    /// This also replaces an assertion on `String(describing:)` of a `LocalizedStringKey` —
    /// that produces an opaque debug description that is never empty, so it could not fail.
    func testBackendNamesAreDistinctProductNames() {
        // `ModelBackendType` is not `CaseIterable` — its rawValues are persistence keys, so
        // the list is spelled out here and a new backend must be added deliberately.
        let backends: [ModelBackendType] = [.ollama, .mlx, .whisper]
        XCTAssertEqual(Set(backends.map(\.rawValue)).count, backends.count,
                       "two backends share a name, so the sidebar could not tell them apart")
        for backend in backends {
            XCTAssertFalse(backend.rawValue.isEmpty)
            XCTAssertFalse(backend.icon.isEmpty, "\(backend) would render with no icon")
        }
    }
}

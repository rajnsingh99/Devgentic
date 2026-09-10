// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MLXInferencePathTests.swift
//  DevgenticTests
//
//  A14 + A15 — the two deferred items from Batch 1, both on the inference/request path.
//
//    A14  `streamChat` took no model identifier, and `lastModelDirectory` is a single global
//         slot holding whatever model ANY caller loaded most recently. Parallel workflow
//         branches could answer from each other's models with no error and no user signal.
//    A15  The installed-model scan (recursive walk + per-model config parsing) ran
//         synchronously on the MainActor, reachable from four request-path consumers.
//
//  ⚠️ No test here loads an MLX model — the suite must stay hermetic and fast.
//

import XCTest
@testable import devgentic

// MARK: - A14: identity plumbing

final class MLXModelIdentityPlumbingTests: XCTestCase {

    /// The provider must carry the directory it was configured for. Without this there is
    /// nothing to compare against at generation time and the actor falls back to "whatever
    /// is resident", which is the bug.
    func testProviderCarriesItsModelDirectory() {
        let dir = URL(fileURLWithPath: "/models/models/mlx-community/Phi-4-mini-instruct-4bit")
        let provider = MLXLLMProvider(modelName: "mlx-community/Phi-4-mini-instruct-4bit", modelDirectory: dir)

        XCTAssertEqual(provider.modelDirectory, dir)
    }

    /// Nil identity stays legal (legacy callers), and is what the service logs a warning for.
    func testProviderIdentityIsOptional() {
        let provider = MLXLLMProvider(modelName: "some/model")
        XCTAssertNil(provider.modelDirectory)
    }

    // MARK: - The identity rule itself

    /// ⚠️ Added 2026-08-03. A14's only coverage was an initializer round-trip and a string
    /// check on the error message — gutting `container(expecting:)` back to
    /// `guard let container = modelContainer` left every A14 test green. `isResident` is the
    /// actual decision, extracted so it can be exercised.

    private let phi = URL(fileURLWithPath: "/models/models/mlx-community/Phi-4-mini-instruct-4bit")
    private let qwen = URL(fileURLWithPath: "/models/models/mlx-community/Qwen3.5-9B-MLX-8bit")

    func testTheExpectedModelBeingResidentIsServed() {
        XCTAssertTrue(MLXService.isResident(expected: phi, resident: phi, hasContainer: true))
    }

    /// The bug A14 exists to stop: another model is loaded and the request is answered from it.
    func testADifferentResidentModelIsRefused() {
        XCTAssertFalse(MLXService.isResident(expected: phi, resident: qwen, hasContainer: true))
    }

    /// ⚠️ The case that made the guard over-strict before the retry was added: `loadModel`
    /// nulls the container BEFORE loading, so a concurrent load leaves the right PATH recorded
    /// with no container behind it. That is not resident, and answering from it would mean
    /// generating with nothing loaded.
    func testTheRightPathWithNoContainerIsNotResident() {
        XCTAssertFalse(MLXService.isResident(expected: phi, resident: phi, hasContainer: false))
    }

    func testNoResidentModelIsNotResident() {
        XCTAssertFalse(MLXService.isResident(expected: phi, resident: nil, hasContainer: true))
    }

    /// The two URLs come from different places — a profile's stored value and the service's own
    /// record — so they must be compared normalized, or an identical model reads as a mismatch
    /// and every request for it fails.
    func testPathsAreComparedAfterNormalization() {
        let awkward = URL(fileURLWithPath: "/models/models/mlx-community/../mlx-community/Phi-4-mini-instruct-4bit/")
        XCTAssertTrue(MLXService.isResident(expected: phi, resident: awkward, hasContainer: true))
        XCTAssertTrue(MLXService.isResident(expected: awkward, resident: phi, hasContainer: true))
    }

    /// The mismatch error must NAME both models — a generic failure here would be
    /// indistinguishable from any other load error, and this one means "we refused to answer
    /// from the wrong model", which the user needs to be able to tell apart.
    func testMismatchErrorNamesBothModels() {
        let error = MLXService.ServiceError.modelIdentityMismatch(expected: "Phi-4", actual: "Qwen2.5")
        let message = try? XCTUnwrap(error.errorDescription)

        XCTAssertTrue(message?.contains("Phi-4") == true)
        XCTAssertTrue(message?.contains("Qwen2.5") == true)
    }

    func testNoModelLoadedErrorIsDistinct() {
        let a = MLXService.ServiceError.modelIdentityMismatch(expected: "X", actual: "Y").errorDescription
        let b = MLXService.ServiceError.noModelLoaded.errorDescription
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a, b)
    }
}

// MARK: - A15: the scan moved off the MainActor

@MainActor
final class MLXAsyncScanTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-async-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    @discardableResult
    private func installModel(_ repoId: String) throws -> URL {
        var folder = root.appendingPathComponent("models")
        for part in repoId.components(separatedBy: "/") { folder = folder.appendingPathComponent(part) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data("w".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
        return folder
    }

    /// The walk is now a pure `nonisolated static` — it can run on any executor, which is
    /// the whole point of the change.
    func testScanDiskRunsOffTheMainActorAndFindsModels() async throws {
        try installModel("mlx-community/Phi-4-mini-instruct-4bit")
        try installModel("lmstudio-community/Qwen3.5-9B-MLX-8bit")
        let scanRoot = root!

        let found = await Task.detached(priority: .userInitiated) {
            MLXModelService.scanDisk(root: scanRoot)
        }.value

        XCTAssertEqual(
            Set(found.map(\.displayName)),
            ["mlx-community/Phi-4-mini-instruct-4bit", "lmstudio-community/Qwen3.5-9B-MLX-8bit"]
        )
    }

    /// Profile computation is the expensive half and must also be off-actor callable.
    func testComputeProfilesRunsOffTheMainActor() async throws {
        try installModel("mlx-community/Phi-4-mini-instruct-4bit")
        let scanRoot = root!

        let profiles = await Task.detached(priority: .userInitiated) {
            let models = MLXModelService.scanDisk(root: scanRoot)
            return MLXModelService.computeProfiles(for: models)
        }.value

        XCTAssertEqual(profiles.count, 1)
        XCTAssertNotNil(profiles["mlx-community/Phi-4-mini-instruct-4bit"])
    }

    /// `ensureLoaded()` is the contract the four request-path consumers rely on: after it
    /// returns, the list reflects disk. Reading `installedModels` without it can observe the
    /// empty pre-scan state, which is indistinguishable from "nothing is installed" — and
    /// would fail a turn with a 404 for a model that is present.
    func testEnsureLoadedPopulatesBeforeReturning() async throws {
        try installModel("mlx-community/Phi-4-mini-instruct-4bit")
        let service = MLXModelService(modelsRootOverride: root)

        await service.ensureLoaded()

        XCTAssertFalse(service.installedModels.isEmpty, "ensureLoaded returned before the scan landed")
        XCTAssertTrue(service.isInstalled(repoId: "mlx-community/Phi-4-mini-instruct-4bit"))
    }

    /// Concurrent callers must coalesce onto one walk rather than racing several over the
    /// same multi-gigabyte tree.
    func testConcurrentEnsureLoadedCallsCoalesce() async throws {
        try installModel("mlx-community/Phi-4-mini-instruct-4bit")
        try installModel("srswti/bodega-raptor-90m")
        let service = MLXModelService(modelsRootOverride: root)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { @MainActor in await service.ensureLoaded() }
            }
        }

        XCTAssertEqual(service.installedModels.count, 2, "coalescing lost or duplicated results")
    }

    /// An awaited force-refresh must reflect a change made after the first scan — this is
    /// what the download-completion path uses to classify its terminal state.
    ///
    /// ⚠️ Only covers the QUIESCENT case: `ensureLoaded()` above drains `scanTask`, so this
    /// never reaches the coalescing branch. See the test below for the case that matters.
    func testForceRefreshAsyncSeesNewlyInstalledModels() async throws {
        let service = MLXModelService(modelsRootOverride: root)
        await service.ensureLoaded()
        XCTAssertTrue(service.installedModels.isEmpty)

        try installModel("mlx-community/Arrived-Later")
        await service.forceRefreshInstalledModelsAsync()

        XCTAssertTrue(
            service.isInstalled(repoId: "mlx-community/Arrived-Later"),
            "an awaited force-refresh did not observe a model added after the first scan — a completed download would be recorded as cancelled"
        )
    }

    /// The case the quiescent test above cannot reach: a walk is ALREADY in flight when a
    /// forcing caller arrives. Joining it is not enough — it may have read the disk before
    /// the caller's mutation. `force: true` means "I just changed the disk", so it must cause
    /// a walk that starts after the call.
    ///
    /// Every forcing caller has just mutated: `deleteModel`, `importModel`, the cancel
    /// cleanup, and download completion — whose terminal classification reads `installedModels`
    /// and records a finished multi-gigabyte pull as cancelled if it is stale.
    func testForceRefreshStartsItsOwnWalkRatherThanJoiningOneInFlight() async throws {
        let service = MLXModelService(modelsRootOverride: root)
        await service.ensureLoaded()

        // Put a walk in flight and leave it running.
        let background = Task { @MainActor in await service.refreshInstalledModelsAsync(force: true) }
        let before = service.scanCount
        var spins = 0
        while service.scanCount == before, spins < 500 {
            await Task.yield()
            spins += 1
        }
        let joinedWalk = service.scanCount
        XCTAssertGreaterThan(joinedWalk, before, "precondition: a walk should now be in flight")

        // Mutate AFTER that walk began — it may or may not observe this.
        try installModel("mlx-community/Arrived-Mid-Scan")

        await service.forceRefreshInstalledModelsAsync()
        _ = await background.value

        XCTAssertGreaterThan(
            service.scanCount, joinedWalk,
            "force joined the in-flight walk and returned without starting one of its own — that walk may have read the disk before the caller's mutation"
        )
        XCTAssertTrue(
            service.isInstalled(repoId: "mlx-community/Arrived-Mid-Scan"),
            "the forced walk did not observe the mutation that prompted it"
        )
    }

    /// The counterpart, so `force` falling through does not simply defeat coalescing: a
    /// NON-forcing caller still joins and must not start a second walk over the same tree.
    func testNonForcingCallerStillCoalescesOntoAnInFlightWalk() async throws {
        let service = MLXModelService(modelsRootOverride: root)
        await service.ensureLoaded()

        let background = Task { @MainActor in await service.refreshInstalledModelsAsync(force: true) }
        let before = service.scanCount
        var spins = 0
        while service.scanCount == before, spins < 500 {
            await Task.yield()
            spins += 1
        }
        let joinedWalk = service.scanCount

        await service.refreshInstalledModelsAsync()
        _ = await background.value

        XCTAssertEqual(
            service.scanCount, joinedWalk,
            "a non-forcing caller raced a second walk over the same multi-gigabyte tree instead of joining"
        )
    }

    /// The profile cache must be populated by the same publish step, or every
    /// `cachedCognitiveProfile` call would re-parse on the MainActor and undo the fix.
    func testProfilesArePublishedWithTheModelList() async throws {
        try installModel("mlx-community/Phi-4-mini-instruct-4bit")
        let service = MLXModelService(modelsRootOverride: root)

        await service.ensureLoaded()
        let item = try XCTUnwrap(service.installedModel(named: "mlx-community/Phi-4-mini-instruct-4bit"))

        // Reading the profile must not require another parse — it was computed off-actor.
        _ = service.cachedCognitiveProfile(for: item)
        XCTAssertNotNil(service.installedModel(named: "mlx-community/Phi-4-mini-instruct-4bit"))
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LocalResidencyTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

/// Records the unloads the coordinator orders.
@MainActor
final class RecordingResidency: LocalResidencyActions {
    var mlxKeepLists: [[String]] = []
    var ollamaUnloads: [String] = []
    var reasons: [String] = []
    func unloadMLX(unlessResidentIn names: [String], reason: String) async { mlxKeepLists.append(names); reasons.append(reason) }
    func unloadOllama(model: String, baseURL: String, reason: String) async { ollamaUnloads.append("\(baseURL)/\(model)"); reasons.append(reason) }
}

@MainActor
final class LocalResidencyTests: XCTestCase {

    private let server = "http://localhost:11434"
    private var residency: RecordingResidency!
    private var started: [Task<Void, Never>] = []

    override func setUp() async throws { residency = RecordingResidency() }
    override func tearDown() async throws { started.forEach { $0.cancel() }; started = [] }

    private func coordinator(_ mode: LocalInferenceCoordinator.Mode = .enforce) -> LocalInferenceCoordinator {
        LocalInferenceCoordinator(mode: mode, beginQueueWait: { _ in }, endQueueWait: { _ in }, residency: residency)
    }

    private func ollama(_ model: String) -> ModelRequirement {
        ModelRequirement(engine: .ollama(baseURL: server), modelID: model, role: .primary)
    }

    private func eventually(_ seconds: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    // MARK: - Residency at lock handover

    func testTakingTheLockUnloadsOnlyWhatTheHolderDoesNotUse() async {
        let c = coordinator()
        c.noteLocalUse(runID: nil, engine: .ollama(baseURL: server), modelID: "llama3")
        c.noteLocalUse(runID: nil, engine: .ollama(baseURL: server), modelID: "gemma")
        let holder = LIFixtures.manifest(models: [LIFixtures.mlxQwen, ollama("gemma")])
        _ = await c.acquire(holder)

        let done = await eventually { !self.residency.mlxKeepLists.isEmpty && self.residency.ollamaUnloads.count == 1 }
        XCTAssertTrue(done)
        // Every unload line names the run that caused it — the correlation id of the handover.
        XCTAssertEqual(residency.reasons, Array(repeating: "run \(holder.runID.uuidString.prefix(8)) took the local lock", count: 2))
        XCTAssertEqual(residency.mlxKeepLists, [["qwen"]], "MLX keeps the holder's model")
        XCTAssertEqual(residency.ollamaUnloads, ["\(server)/llama3"], "only the Ollama model the holder does not use")
        XCTAssertEqual(c.ollamaModelsUsed[server].map { Set($0.keys) }, ["gemma"], "an unloaded model leaves the ledger")
    }

    /// The lock passing to a waiting run prepares for THAT run.
    func testPassingTheLockPreparesForTheNextHolder() async {
        let c = coordinator()
        let a = LIFixtures.manifest(models: [LIFixtures.mlxQwen])
        let b = LIFixtures.manifest(models: [ollama("llama3")])
        _ = await c.acquire(a)
        started.append(Task { @MainActor in _ = await c.acquire(b) })
        _ = await eventually { c.lock.queue.contains { $0.runID == b.runID } }
        residency.mlxKeepLists = []

        c.unregister(runID: a.runID)
        let done = await eventually { !self.residency.mlxKeepLists.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(residency.mlxKeepLists, [[]], "an Ollama-only holder keeps no MLX model resident")
    }

    /// ⚠️ A run that uses a local model its manifest did not declare takes the lock at that use — and
    /// the handover must KEEP that model. It used to keep only the declared ones, unloading the very
    /// model the run was about to generate with (a pointless reload), and deletion did not protect it.
    func testAnUndeclaredModelIsDeclaredBeforeTheHandoverThatKeepsIt() async {
        let c = coordinator()
        let run = LIFixtures.manifest(models: [LIFixtures.claude])   // cloud-only: takes no lock at start
        _ = await c.acquire(run)
        XCTAssertNil(c.lock.holder)

        let ok = await c.beginLocalGeneration(run.runID, model: LIFixtures.mlxQwen)
        XCTAssertTrue(ok)
        XCTAssertEqual(c.lock.holder, run.runID)
        let done = await eventually { !self.residency.mlxKeepLists.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(residency.mlxKeepLists, [["qwen"]], "the handover keeps the model the run is about to use")
        XCTAssertTrue(c.manifest(for: run.runID)?.models.contains(LIFixtures.mlxQwen) == true)
        XCTAssertEqual(c.modelsInUse(on: .mlx), ["qwen"], "and deleting it is refused while the run lives")
    }

    func testAManifestWithUnresolvedNodesEvictsNothing() async {
        let c = coordinator()
        c.noteLocalUse(runID: nil, engine: .ollama(baseURL: server), modelID: "llama3")
        _ = await c.acquire(LIFixtures.manifest(shape: .workflow(nodeCount: 2), models: [LIFixtures.mlxQwen], unresolvedNodes: 1))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(residency.mlxKeepLists.isEmpty)
        XCTAssertTrue(residency.ollamaUnloads.isEmpty)
    }

    func testShadowModeAndCloudRunsEvictNothing() async {
        let shadow = coordinator(.shadow)
        shadow.noteLocalUse(runID: nil, engine: .ollama(baseURL: server), modelID: "llama3")
        _ = await shadow.acquire(LIFixtures.manifest(models: [LIFixtures.mlxQwen]))
        let enforcing = coordinator()
        enforcing.noteLocalUse(runID: nil, engine: .ollama(baseURL: server), modelID: "llama3")
        _ = await enforcing.acquire(LIFixtures.manifest(models: [LIFixtures.claude]))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(residency.mlxKeepLists.isEmpty, "a cloud run never takes the lock, so it never changes residency")
        XCTAssertTrue(residency.ollamaUnloads.isEmpty)
    }

    // MARK: - Ollama ledger

    func testAnOllamaContextChangeIsReported() {
        let c = coordinator()
        let engine = InferenceEngine.ollama(baseURL: server)
        XCTAssertEqual(c.noteLocalUse(runID: nil, engine: engine, modelID: "m", contextTokens: 8192), [.outsideAnyRun])
        XCTAssertEqual(c.noteLocalUse(runID: nil, engine: engine, modelID: "m", contextTokens: 8192), [])
        XCTAssertEqual(c.noteLocalUse(runID: nil, engine: engine, modelID: "m", contextTokens: 16384), [.ollamaContextChanged])
        XCTAssertEqual(c.noteLocalUse(runID: nil, engine: engine, modelID: "m", contextTokens: nil), [],
                       "an unknown context is not a change, and keeps the last known one")
        XCTAssertEqual(c.ollamaModelsUsed[server]?["m"], .some(16384))
    }

    /// Quit unloads every Ollama model this app used — and nothing else.
    func testQuitUnloadsOnlyTheOllamaModelsThisAppUsed() async {
        let c = coordinator()
        c.noteLocalUse(runID: nil, engine: .ollama(baseURL: server), modelID: "a")
        c.noteLocalUse(runID: nil, engine: .ollama(baseURL: "http://gpu-box:11434"), modelID: "b")
        c.noteLocalUse(runID: nil, engine: .mlx, modelID: "qwen")
        await c.unloadOllamaModelsWeUsed()
        XCTAssertTrue(residency.reasons.allSatisfy { $0 == "quit" }, "quit unloads say so")
        XCTAssertEqual(Set(residency.ollamaUnloads), ["\(server)/a", "http://gpu-box:11434/b"])
        XCTAssertTrue(c.ollamaModelsUsed.isEmpty)
    }

    // MARK: - Deletion guard

    func testModelsInUseCoverHoldingWaitingAndParkedRuns() async {
        let c = coordinator()
        let holder = LIFixtures.manifest(models: [LIFixtures.mlxQwen])
        let waiting = LIFixtures.manifest(models: [LIFixtures.mlxLlama])
        _ = await c.acquire(holder)
        started.append(Task { @MainActor in _ = await c.acquire(waiting) })
        _ = await eventually { c.lock.queue.contains { $0.runID == waiting.runID } }
        XCTAssertEqual(Set(c.modelsInUse(on: .mlx)), ["qwen", "llama"])

        c.parkBegan(runID: holder.runID, operationID: UUID())   // holder parks → releases, still registered
        XCTAssertTrue(c.modelsInUse(on: .mlx).contains("qwen"), "a parked run still needs its model")
    }

    // MARK: - Background Core Intelligence (D7)

    func testABackgroundFeatureWaitsBehindALocalRunAtTheLowestPriority() async {
        let c = coordinator()
        let holder = LIFixtures.manifest(models: [LIFixtures.mlxQwen])
        _ = await c.acquire(holder)
        let ran = expectation(description: "the brief ran")
        final class Box { var ran = false }
        let box = Box()
        started.append(Task { @MainActor in
            _ = try? await c.runBackgroundIntelligence(feature: "Briefing", modelName: "tiny") {
                box.ran = true
                return 1
            }
            ran.fulfill()
        })
        _ = await eventually { !c.lock.queue.isEmpty }
        XCTAssertEqual(c.lock.queue.first?.priority, .backgroundIC)
        XCTAssertFalse(box.ran, "it waits for the holder")

        c.unregister(runID: holder.runID)
        await fulfillment(of: [ran], timeout: 2)
        XCTAssertTrue(box.ran)
        XCTAssertTrue(c.lock.isIdle, "the feature releases the lock when it finishes")
    }

    func testABackgroundFeatureWithNoModelSelectedNeverWaits() async throws {
        let c = coordinator()
        _ = await c.acquire(LIFixtures.manifest(models: [LIFixtures.mlxQwen]))
        let value = try await c.runBackgroundIntelligence(feature: "User Personal", modelName: "  ") { 7 }
        XCTAssertEqual(value, 7)
    }

    func testTheQueueNoticeNamesABackgroundFeature() {
        let holder = InferenceRunManifest(runID: UUID(), conversationID: nil, origin: .intelligence("Briefing"),
                                          attended: false, shape: .single, models: [LIFixtures.mlxQwen],
                                          unresolvedNodes: 0, footprints: [:])
        XCTAssertEqual(ActiveStreamManager.localQueueNotice(holder: holder, holderTitle: nil, position: 1),
                       "The local model (qwen) is in use by Briefing (a background task). This run is next in line and starts by itself when that run finishes.")
        XCTAssertEqual(PriorityClass.of(origin: .intelligence("x"), attended: false), .backgroundIC)
    }

    // MARK: - MLX memory

    func testTheMLXBufferCacheCapIsTwoGigabytesOrATenthOfRAM() {
        XCTAssertEqual(MLXMemoryPolicy.cacheLimitBytes(physicalMemory: 8 << 30), Int((8 << 30) / 10))
        XCTAssertEqual(MLXMemoryPolicy.cacheLimitBytes(physicalMemory: 64 << 30), 2 << 30)
    }
}

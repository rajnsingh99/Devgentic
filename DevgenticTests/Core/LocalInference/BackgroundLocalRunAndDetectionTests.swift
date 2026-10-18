// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundLocalRunAndDetectionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class BackgroundLocalRunTests: XCTestCase {

    private var started: [Task<Void, Never>] = []
    override func tearDown() async throws { started.forEach { $0.cancel() }; started = [] }

    private func coordinator() -> LocalInferenceCoordinator {
        LocalInferenceCoordinator(mode: .enforce, beginQueueWait: { _ in }, endQueueWait: { _ in })
    }

    private func eventually(_ seconds: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private let localModel = ProviderConfig(apiProvider: .mlx, modelName: "qwen-small")

    /// ⚠️⚠️ THE CR-9 PROPERTY: background work on a local model WAITS for the lock and runs as a
    /// registered run of its own — never alongside the holder, never under a finished run's id.
    func testBackgroundWorkWaitsForTheLockAndRunsAsItsOwnRun() async {
        let c = coordinator()
        let holder = LIFixtures.manifest(models: [LIFixtures.mlxQwen])
        _ = await c.acquire(holder)

        final class Box { var ranUnder: UUID??; var registeredWhileRunning = false }
        let box = Box()
        let done = expectation(description: "compaction ran")
        let staleRunID = UUID()   // the finished turn whose identity the old code borrowed
        started.append(Task { @MainActor in
            await LocalInferenceScope.$runID.withValue(staleRunID) {
                _ = try? await c.runBackgroundLocal(feature: "Compaction", conversationID: UUID(), config: self.localModel) {
                    let id = LocalInferenceScope.runID
                    box.ranUnder = .some(id)
                    box.registeredWhileRunning = id.flatMap { c.manifest(for: $0) } != nil
                    return 1
                }
            }
            done.fulfill()
        })

        _ = await eventually { !c.lock.queue.isEmpty }
        XCTAssertNil(box.ranUnder, "it must WAIT while another local run holds the lock")
        XCTAssertEqual(c.lock.queue.first?.priority, .backgroundIC, "at the lowest priority")

        c.unregister(runID: holder.runID)
        await fulfillment(of: [done], timeout: 2)
        let ranUnder = box.ranUnder.flatMap { $0 }
        XCTAssertNotNil(ranUnder)
        XCTAssertNotEqual(ranUnder, staleRunID, "the finished run's identity was borrowed")
        XCTAssertTrue(box.registeredWhileRunning, "the scope's run must be a REGISTERED run, or ensureHeld waves it through")
        XCTAssertTrue(c.lock.isIdle, "and it releases the lock when done")
    }

    /// A cloud model takes no lock — and still never borrows the stale id.
    func testCloudBackgroundWorkTakesNoLockAndClearsTheStaleID() async throws {
        let c = coordinator()
        _ = await c.acquire(LIFixtures.manifest(models: [LIFixtures.mlxQwen]))   // someone holds the lock
        let stale = UUID()
        let observed: UUID? = try await LocalInferenceScope.$runID.withValue(stale) {
            try await c.runBackgroundLocal(feature: "Compaction", conversationID: nil,
                                           config: ProviderConfig(apiProvider: .anthropic, modelName: "claude-opus-5")) {
                LocalInferenceScope.runID
            }
        }
        XCTAssertNil(observed, "cloud work runs immediately, with no run id at all")
    }

    /// Every background generator goes through the coordinator — the method is useless uncalled.
    func testEveryBackgroundGeneratorIsWrapped() throws {
        let compaction = try Self.read("Devgentic/Core/Service/HistoryCompactionService.swift")
        XCTAssertEqual(compaction.components(separatedBy: "LocalInferenceCoordinator.shared.runBackgroundLocal(").count - 1, 2,
                       "automatic and manual compaction on the conversation model")
        XCTAssertEqual(compaction.components(separatedBy: "LocalInferenceCoordinator.shared.runBackgroundIntelligence(").count - 1, 2,
                       "automatic and manual compaction on Intelligence Core")
        XCTAssertFalse(compaction.contains("result = try await execute(plan: plan, conversationID: conversationID)\n"),
                       "an unwrapped Intelligence Core compaction came back")
        let agent = try Self.read("Devgentic/Core/Backends/TextGen/AgentConnect.swift")
        XCTAssertTrue(agent.contains("feature: \"Project memory suggestions\""), "the memory suggester must run on the lock too")
    }

    static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return try String(contentsOf: candidate, encoding: .utf8) }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath)")
    }
}

@MainActor
final class OllamaColdLaunchDetectionTests: XCTestCase {

    private var savedModels: [LocalModel] = []
    private var savedURL = ""

    override func setUp() {
        super.setUp()
        savedModels = OllamaService.shared.localModels
        savedURL = OllamaService.shared.ollamaBaseURL
        LiveModelDetection.resetForTesting()
    }

    override func tearDown() {
        OllamaService.shared.localModels = savedModels
        OllamaService.shared.ollamaBaseURL = savedURL
        LiveModelDetection.resetForTesting()
        super.tearDown()
    }

    /// ⚠️⚠️ THE CR-8 DEFECT: on a cold launch the server was never probed, so nothing loaded. An
    /// unprobed server must be PROBED, not skipped.
    func testAnUnprobedServerIsProbedAndLoaded() {
        let now = Date()
        XCTAssertEqual(LiveModelDetection.ollamaLoadAction(serverConnected: false, hasModels: false, lastAttempt: nil, now: now),
                       .probeAndLoad)
        XCTAssertEqual(LiveModelDetection.ollamaLoadAction(serverConnected: true, hasModels: false, lastAttempt: nil, now: now),
                       .loadOnly)
        XCTAssertEqual(LiveModelDetection.ollamaLoadAction(serverConnected: false, hasModels: true, lastAttempt: nil, now: now),
                       .none, "already loaded")
        XCTAssertEqual(LiveModelDetection.ollamaLoadAction(serverConnected: false, hasModels: false,
                                                           lastAttempt: now.addingTimeInterval(-5), now: now),
                       .none, "the throttle still holds an offline server off")
    }

    func testTheProbePathCallsTheFullStatusCheck() throws {
        let source = try BackgroundLocalRunTests.read("Devgentic/Core/Service/LiveModelDetection.swift")
        XCTAssertTrue(source.contains("case .probeAndLoad: await service.checkServerStatusAndUpdateModels()"),
                      "a probe must go through the call that SETS `.connected` and then loads")
    }

    /// A profile on ANOTHER Ollama server is not resolved against the default server's models.
    func testAnotherServersProfileIsNotResolvedAgainstThisServersModels() {
        OllamaService.shared.ollamaBaseURL = "http://localhost:11434"
        OllamaService.shared.localModels = [LocalModel(name: "llama3.1:8b", response: OllamaShowResponse(
            license: nil, modelfile: nil, parameters: nil, template: nil, details: nil,
            capabilities: ["completion", "tools"], modelInfo: nil))]

        let local = ProviderConfig(apiProvider: .ollama, modelName: "llama3.1:8b")
        XCTAssertNotNil(LiveModelDetection.detectedFromCache(local), "the control: the default server's own profile resolves")

        var remote = local
        remote.baseURL = "http://gpu-box.lan:11434"
        XCTAssertNil(LiveModelDetection.detectedFromCache(remote), "a same-named model on another server is not this one")

        var trailing = local
        trailing.baseURL = "http://localhost:11434/"
        XCTAssertNotNil(LiveModelDetection.detectedFromCache(trailing), "a trailing slash is the same server")
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OllamaLockDownloadBatchTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

// MARK: - A stub Ollama server on URLSession.shared

private final class OllamaStub: URLProtocol {
    static let host = "ollama-batch4.test"
    static var baseURL: String { "http://\(host)" }

    enum Tags { case ok([String]), status(Int), unreachable }
    nonisolated(unsafe) static var tags: Tags = .ok([])
    nonisolated(unsafe) static var versionStatus = 200
    nonisolated(unsafe) static var versionRequests = 0

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        var status = 200
        var body = Data("{}".utf8)
        switch path {
        case "/api/version":
            Self.versionRequests += 1
            status = Self.versionStatus
            body = Data(#"{"version":"0.9.0"}"#.utf8)
        case "/api/tags":
            switch Self.tags {
            case .ok(let names):
                let models = names.map { ["name": $0, "digest": "sha-\($0)"] }
                body = (try? JSONSerialization.data(withJSONObject: ["models": models])) ?? Data()
            case .status(let code):
                status = code
                body = Data(#"{"error":"boom"}"#.utf8)
            case .unreachable:
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
        default: break   // /api/show → {}
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class OllamaLockDownloadBatchTests: XCTestCase {

    // `OllamaService` is the app's singleton: every field a test touches is restored.
    private var saved: (url: String, status: OllamaServerStatus, models: [LocalModel], error: String?, pullError: String?)!

    override func setUp() async throws {
        URLProtocol.registerClass(OllamaStub.self)
        OllamaStub.tags = .ok([]); OllamaStub.versionStatus = 200; OllamaStub.versionRequests = 0
        let s = OllamaService.shared
        saved = (s.ollamaBaseURL, s.serverStatus, s.localModels, s.modelLoadingError, s.modelPullError)
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(OllamaStub.self)
        let s = OllamaService.shared
        s.ollamaBaseURL = saved.url; s.serverStatus = saved.status; s.localModels = saved.models
        s.modelLoadingError = saved.error; s.modelPullError = saved.pullError
    }

    private func model(_ name: String) -> LocalModel {
        LocalModel(name: name, digest: "sha-\(name)", response: OllamaShowResponse(
            license: nil, modelfile: nil, parameters: nil, template: nil, details: nil, capabilities: nil, modelInfo: nil))
    }

    // MARK: - CR-33: reuse is not a cycle

    private func resolve(_ profile: BackendProfileModel, layouts: [UUID: WorkflowLayout],
                         profiles: [BackendProfileModel]) -> ManifestModelResolver.Result {
        let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return ManifestModelResolver.models(for: profile, layout: { layouts[$0] },
                                            profiles: { ids in ids.compactMap { byID[$0] } })
    }

    /// Mutation that must turn this red: one global visited set again.
    func testASubWorkflowUsedTwiceIsResolved() {
        let outer = LIFixtures.workflow()
        let shared = LIFixtures.workflow()
        let cloud = LIFixtures.bot(.anthropic, "claude")
        let result = resolve(outer,
                             layouts: [outer.id: LIFixtures.layout([LIFixtures.node(shared), LIFixtures.node(shared)]),
                                       shared.id: LIFixtures.layout([LIFixtures.node(cloud)])],
                             profiles: [shared, cloud])
        XCTAssertEqual(result.unresolvedNodes, 0, "a reused sub-workflow made a cloud workflow take the local lock")
        XCTAssertFalse(result.models.contains { $0.engine.isLocal })
    }

    func testAGenuineCycleIsStillUnresolved() {
        let a = LIFixtures.workflow()
        let b = LIFixtures.workflow()
        let result = resolve(a, layouts: [a.id: LIFixtures.layout([LIFixtures.node(b)]),
                                          b.id: LIFixtures.layout([LIFixtures.node(a)])],
                             profiles: [a, b])
        XCTAssertEqual(result.unresolvedNodes, 1, "a workflow that contains itself must stay conservative")
    }

    // MARK: - CR-34: one pull slot, claimed before any await

    func testTheSlotCanBeClaimedOnce() {
        let service = OllamaService.shared
        guard let token = service.reservePull() else { return XCTFail("the slot was already taken") }
        defer { service.releasePullReservation(token) }
        XCTAssertNil(service.reservePull(), "a second claim must fail while the first holds the slot")
        XCTAssertTrue(service.isPullSlotTaken)
    }

    /// THE CALL SITE: a pull that has not claimed the slot is refused BEFORE its server probe.
    /// Mutation that must turn this red: guard on `isPullingModel` alone again.
    func testAPullIsRefusedWhileAnotherHasClaimedTheSlot() async throws {
        let service = OllamaService.shared
        let token = try XCTUnwrap(service.reservePull())
        defer { service.releasePullReservation(token) }
        await service.pullModel(name: "cr34-second", baseURL: OllamaStub.baseURL)
        XCTAssertEqual(OllamaStub.versionRequests, 0, "the second pull got past the guard and probed the server")
        XCTAssertFalse(service.isPullingModel)
    }

    /// The claimant's own pull proceeds, and the slot is free again however it ends.
    func testTheClaimantPullsAndTheSlotIsReleased() async throws {
        let service = OllamaService.shared
        OllamaStub.versionStatus = 500   // the probe fails → the pull ends before starting
        let token = try XCTUnwrap(service.reservePull())
        await service.pullModel(name: "cr34-first", baseURL: OllamaStub.baseURL, reservation: token)
        XCTAssertEqual(OllamaStub.versionRequests, 1, "the claimant must be let through")
        XCTAssertFalse(service.isPullSlotTaken, "an early return leaked the slot — no pull could ever start again")
    }

    /// Source pin: the coordinator claims the slot before its support lookup's await, and gives it
    /// back when it refuses. Mutation that must turn this red: claim after the await.
    func testTheCoordinatorClaimsBeforeItsAwait() throws {
        let source = try Self.read("Devgentic/Core/Service/DownloadCoordinator.swift")
        let claim = try XCTUnwrap(source.range(of: "guard let reservation = ollama.reservePull()"))
        let lookup = try XCTUnwrap(source.range(of: "await MLXModelService.shared.unsupportedReason(forRepo: repoId)"))
        XCTAssertLessThan(claim.lowerBound, lookup.lowerBound)
        XCTAssertNotNil(source.range(of: #"unsupportedReason\(forRepo: repoId\) \{\s*ollama\.releasePullReservation\(reservation\)"#, options: .regularExpression))
        XCTAssertTrue(source.contains("pullModel(name: trimmed, baseURL: ollama.ollamaBaseURL, reservation: reservation)"))
    }

    // MARK: - CR-35: a pull's outcome is its terminal state, never its percentage

    func testACancelledPullIsRecordedCancelled() {
        XCTAssertEqual(DownloadManager.classifyOllamaPull(terminalState: .cancelled, errorMessage: nil, isInstalledNow: false), .cancelled)
        XCTAssertEqual(DownloadManager.classifyOllamaPull(terminalState: .succeeded(model: "m"), errorMessage: nil, isInstalledNow: false), .completed)
        XCTAssertEqual(DownloadManager.classifyOllamaPull(terminalState: .failed(model: "m"), errorMessage: nil, isInstalledNow: false), .failed)
        XCTAssertEqual(DownloadManager.classifyOllamaPull(terminalState: nil, errorMessage: nil, isInstalledNow: false), .cancelled,
                       "without a terminal state, a model that is not installed was not downloaded")
    }

    /// Source pin: the bridge reads the terminal state and the classifier, and the per-layer
    /// percentage no longer decides. Mutation that must turn this red: put `progress >= 0.99` back.
    func testTheOllamaBridgeUsesTheTerminalState() throws {
        let source = try Self.read("Devgentic/Core/Service/DownloadManager.swift")
        let start = try XCTUnwrap(source.range(of: "private func reconcileOllama("))
        let end = try XCTUnwrap(source.range(of: "/// How a finished Ollama pull is recorded."))
        let body = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(body.contains("Self.classifyOllamaPull(terminalState: terminalState"))
        XCTAssertFalse(body.contains("progress >= 0.99"), "Ollama progress is per layer — it cannot say a pull finished")
        XCTAssertTrue(source.contains("_ = service.pullTerminalState"), "the observer must track the terminal state")
        XCTAssertTrue(source.contains("terminalState: service.pullTerminalState"))
    }

    // MARK: - CR-37 / CR-38: refresh errors and duplicate names

    /// THE CALL SITE: a server that answers but fails `/api/tags` keeps the installed list.
    /// Mutation that must turn this red: clear `localModels` on every error again.
    func testATransientRefreshErrorKeepsTheInstalledModels() async {
        let service = OllamaService.shared
        service.ollamaBaseURL = OllamaStub.baseURL
        service.serverStatus = .connected
        service.localModels = [model("qwen3:8b")]
        OllamaStub.tags = .status(500)
        await service.loadLocalModels()
        XCTAssertEqual(service.localModels.map(\.name), ["qwen3:8b"], "installed models were reported missing after one bad response")
        XCTAssertEqual(service.serverStatus, .connected)
        XCTAssertNotNil(service.modelLoadingError)
    }

    func testAnUnreachableServerStillClearsTheListAndSaysSo() async {
        let service = OllamaService.shared
        service.ollamaBaseURL = OllamaStub.baseURL
        service.serverStatus = .connected
        service.localModels = [model("qwen3:8b")]
        OllamaStub.tags = .unreachable
        await service.loadLocalModels()
        XCTAssertTrue(service.localModels.isEmpty)
        XCTAssertEqual(service.serverStatus, .disconnected, "an empty list must come with a status that explains it")
    }

    /// Duplicate names from a proxy used to TRAP. Mutation that must turn this red (by crashing):
    /// key the dictionaries with `uniqueKeysWithValues` again.
    func testDuplicateTagNamesDoNotCrashTheRefresh() async throws {
        OllamaStub.tags = .ok(["llama3:8b", "llama3:8b", "qwen3:8b"])
        let result = try await LocalModelRefresher.refresh(
            baseURL: OllamaStub.baseURL, cached: [model("qwen3:8b"), model("qwen3:8b")], cachedDaemonVersion: "0.9.0")
        XCTAssertEqual(result.models.map(\.name).sorted(), ["llama3:8b", "qwen3:8b"])
    }

    // MARK: - CR-36: an admission is re-checked after the last suspension

    /// Run R gave the lock up while parked; its branch B2 waits to take it back. The lock passes to R
    /// — and, inside B2's `endQueueWait`, another branch of R parks again, which passes the lock on to
    /// D. B2 must not start generating while D holds the lock.
    /// Mutation that must turn this red: trust `.admitted` without re-checking the holder.
    func testAStaleAdmissionWaitsForTheLockAgain() async throws {
        let clock = LIClock()
        final class Hook { var fire: (() -> Void)? }
        let hook = Hook()
        let coordinator = LocalInferenceCoordinator(
            mode: .enforce, now: { clock.now }, budgetBytes: { 16 << 30 }, agingInterval: 300,
            beginQueueWait: { _ in }, endQueueWait: { _ in await MainActor.run { let f = hook.fire; hook.fire = nil; f?() } })
        let r = LIFixtures.manifest(origin: .composer, attended: true, models: [LIFixtures.mlxQwen])
        let c = LIFixtures.manifest(origin: .composer, attended: true, models: [LIFixtures.mlxQwen])
        let d = LIFixtures.manifest(origin: .composer, attended: true, models: [LIFixtures.mlxQwen])

        _ = await coordinator.acquire(r)
        var tasks: [Task<Void, Never>] = []
        defer { tasks.forEach { $0.cancel() } }
        tasks.append(Task { @MainActor in _ = await coordinator.acquire(c) })
        try await until { coordinator.lock.queue.contains { $0.runID == c.runID } }

        let park1 = UUID()
        coordinator.parkBegan(runID: r.runID, operationID: park1)      // R releases → C holds
        try await until { coordinator.lock.holder == c.runID }
        coordinator.parkEnded(runID: r.runID, operationID: park1)

        final class Box { var returned: Bool?; var holderAtReturn: UUID? }
        let box = Box()
        tasks.append(Task { @MainActor in
            box.returned = await coordinator.beginLocalGeneration(r.runID)       // branch B2
            box.holderAtReturn = coordinator.lock.holder
        })
        try await until { coordinator.lock.queue.contains { $0.runID == r.runID } }
        tasks.append(Task { @MainActor in _ = await coordinator.acquire(d) })
        try await until { coordinator.lock.queue.contains { $0.runID == d.runID } }

        // When B2 wakes admitted, branch B1 of R parks before B2 resumes: the lock goes to D.
        hook.fire = { coordinator.parkBegan(runID: r.runID, operationID: UUID()) }
        coordinator.unregister(runID: c.runID)                          // C ends → lock to R (B2 settles)
        try await until { coordinator.lock.holder == d.runID || box.returned != nil }

        if box.returned == true {
            XCTAssertEqual(box.holderAtReturn, r.runID, "a branch started generating while another run held the local lock")
        }
        XCTAssertEqual(coordinator.lock.holder, d.runID)

        coordinator.unregister(runID: d.runID)                          // D ends → B2 really gets it
        try await until { box.returned != nil }
        XCTAssertEqual(box.returned, true)
        XCTAssertEqual(box.holderAtReturn, r.runID)
    }

    struct TimedOut: Error {}

    /// Waits for STATE (bounded). A timeout FAILS — never a skip, which would hide a broken lock.
    private func until(_ seconds: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
                       _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not reached within \(seconds)s", file: file, line: line)
                throw TimedOut()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return try String(contentsOf: candidate, encoding: .utf8) }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath)")
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ICModelResidencyTests.swift
//  DevgenticTests
//
//  READINESS CR-32: the Intelligence Core model loaded twice when two features overlapped, and kept
//  answering with the OLD model after the selection changed. These drive the real `ICModelResidency`
//  with a fake model and a gated loader — no MLX.
//

import XCTest
@testable import devgentic

final class ICModelResidencyTests: XCTestCase {

    final class FakeModel: Sendable {
        let name: String
        init(name: String) { self.name = name }
    }

    /// The selected model — what `UserDefaults` holds in the app.
    final class Selection: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String
        init(_ value: String) { self.value = value }
        var current: String { lock.withLock { value } }
        func set(_ newValue: String) { lock.withLock { value = newValue } }
    }

    /// Records loads and frees; a load of a gated name blocks until `open(_:)`.
    actor Harness {
        private(set) var loads: [String] = []
        private(set) var frees: [String] = []
        private var gated: Set<String> = []
        private var gateWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

        func gate(_ name: String) { gated.insert(name) }

        func open(_ name: String) {
            gated.remove(name)
            gateWaiters.removeValue(forKey: name)?.forEach { $0.resume() }
        }

        func load(_ name: String) async throws -> FakeModel {
            loads.append(name)
            if name.isEmpty { throw NSError(domain: "test", code: 400) }
            if gated.contains(name) {
                await withCheckedContinuation { gateWaiters[name, default: []].append($0) }
            }
            return FakeModel(name: name)
        }

        func didFree(_ name: String) { frees.append(name) }
    }

    private func makeResidency(_ selection: Selection, _ harness: Harness) -> ICModelResidency<FakeModel> {
        ICModelResidency<FakeModel>(
            selection: { selection.current },
            idleReleaseSeconds: 3600,
            loader: { name, _, _ in try await harness.load(name) },
            onFree: { name, _, _ in Task { await harness.didFree(name) } }
        )
    }

    /// Waits — by STATE, never a stopwatch — until `condition` holds.
    private func eventually(_ what: String, _ condition: @escaping () async -> Bool) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for: \(what)")
    }

    // MARK: - Coalescing

    /// Two features asking while the model is still loading share ONE load and ONE instance.
    /// Mutation that must turn this red: start a fresh load instead of joining the in-flight one.
    func testOverlappingRequestsShareOneLoad() async throws {
        let selection = Selection("ic-a")
        let harness = Harness()
        await harness.gate("ic-a")
        let residency = makeResidency(selection, harness)

        let first = Task { try await residency.beginGeneration(caller: .ragRewriting) }
        await eventually("the first load starts") { await harness.loads.count == 1 }
        let second = Task { try await residency.beginGeneration(caller: .historyCompaction) }
        await eventually("the second request joins") { await residency.joinedLoads == 1 }

        await harness.open("ic-a")
        let a = try await first.value
        let b = try await second.value

        let loads = await harness.loads
        XCTAssertEqual(loads, ["ic-a"], "the overlapping request must join the load, not start a second one")
        XCTAssertTrue(a === b, "both features must get the same resident model")
        let leases = await residency.activeLeases
        XCTAssertEqual(leases, 2)
    }

    // MARK: - Selection changes

    /// A changed selection is honoured on the next request even though nobody unloaded — the
    /// Model Store's "Set as IC" only writes the setting.
    /// Mutation that must turn this red: reuse any resident model without comparing its name.
    func testASelectionChangeSwapsTheResidentModel() async throws {
        let selection = Selection("ic-a")
        let harness = Harness()
        let residency = makeResidency(selection, harness)

        let a = try await residency.prepare(caller: .morningBrief)
        XCTAssertEqual(a.name, "ic-a")

        selection.set("ic-b")
        let b = try await residency.prepare(caller: .ragRewriting)

        XCTAssertEqual(b.name, "ic-b", "the old model must not answer after the selection changed")
        let loads = await harness.loads
        XCTAssertEqual(loads, ["ic-a", "ic-b"])
        await eventually("the old model is freed") { await harness.frees == ["ic-a"] }
        let resident = await residency.residentName
        XCTAssertEqual(resident, "ic-b")
    }

    /// The selection changes while the old model is still loading: that load finishes (MLX loads
    /// can't be interrupted), but the request is served by the NEW model and the old one is freed.
    func testASelectionChangeDuringALoadEndsOnTheNewModel() async throws {
        let selection = Selection("ic-a")
        let harness = Harness()
        await harness.gate("ic-a")
        let residency = makeResidency(selection, harness)

        let request = Task { try await residency.beginGeneration(caller: .responseSynthesis) }
        await eventually("the load of the old selection starts") { await harness.loads.count == 1 }
        selection.set("ic-b")
        await harness.open("ic-a")

        let model = try await request.value
        XCTAssertEqual(model.name, "ic-b")
        await eventually("the stale load is freed") { await harness.frees == ["ic-a"] }
        let leases = await residency.activeLeases
        XCTAssertEqual(leases, 1, "the lease belongs to the model actually returned")
    }

    /// The swap never frees the old model under a running generation: it waits for it.
    /// Mutation that must turn this red: skip the drain wait and free immediately.
    func testTheSwapWaitsForAnInFlightGenerationOnTheOldModel() async throws {
        let selection = Selection("ic-a")
        let harness = Harness()
        let residency = makeResidency(selection, harness)

        _ = try await residency.beginGeneration(caller: .historyCompaction)   // generating on ic-a
        selection.set("ic-b")
        let next = Task { try await residency.beginGeneration(caller: .ragRewriting) }
        await eventually("the swap waits for the generation") { await residency.waitingForGenerationsToDrain == 1 }

        var frees = await harness.frees
        XCTAssertEqual(frees, [], "the old model must not be freed while a generation still uses it")
        var loads = await harness.loads
        XCTAssertEqual(loads, ["ic-a"], "the new model must not load alongside the busy old one")

        await residency.endGeneration(caller: .historyCompaction)
        let model = try await next.value

        XCTAssertEqual(model.name, "ic-b")
        loads = await harness.loads
        XCTAssertEqual(loads, ["ic-a", "ic-b"])
        await eventually("the old model is freed after the generation") { await harness.frees == ["ic-a"] }
        frees = await harness.frees
        XCTAssertEqual(frees, ["ic-a"])
    }

    /// The selection is cleared (its model was deleted): the resident model is freed and the
    /// request fails, rather than running on a model nobody selected.
    func testAClearedSelectionFreesTheModelAndFails() async throws {
        let selection = Selection("ic-a")
        let harness = Harness()
        let residency = makeResidency(selection, harness)
        _ = try await residency.prepare(caller: .morningBrief)

        selection.set("")
        do {
            _ = try await residency.prepare(caller: .ragRewriting)
            XCTFail("a request with nothing selected must fail")
        } catch {}
        await eventually("the unselected model is freed") { await harness.frees == ["ic-a"] }
        let resident = await residency.residentName
        XCTAssertNil(resident)
    }

    // MARK: - Teardown during a load

    /// Core Intelligence is switched off while its model is loading. The teardown used to free
    /// "nothing" and clear the request, and the load then left the model resident. Now it is freed
    /// as soon as the work that load serves finishes.
    /// Mutation that must turn this red: treat `.freeNow` with nothing resident as done.
    func testAnImmediateTeardownDuringALoadIsHonouredAfterTheWork() async throws {
        let selection = Selection("ic-a")
        let harness = Harness()
        await harness.gate("ic-a")
        let residency = makeResidency(selection, harness)

        let request = Task { try await residency.beginGeneration(caller: .historyCompaction) }
        await eventually("the load starts") { await harness.loads.count == 1 }
        await residency.requestImmediateRelease(caller: .unknown)
        await harness.open("ic-a")
        _ = try await request.value

        var resident = await residency.residentName
        XCTAssertEqual(resident, "ic-a", "the request that started the load is still served")
        await residency.endGeneration(caller: .historyCompaction)

        resident = await residency.residentName
        XCTAssertNil(resident, "the teardown must be honoured once the work finishes")
        await eventually("the model is freed") { await harness.frees == ["ic-a"] }
    }

    // MARK: - Wiring

    /// The service must go through the residency — not hold a container of its own, which is how
    /// both halves of CR-32 happened.
    /// Mutation that must turn this red: reintroduce a `modelContainer` stored property, or
    /// generate without `residency.beginGeneration`.
    func testTheServiceLoadsOnlyThroughTheResidency() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Devgentic/Core/Service/IntelligenceCoreService.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(code.contains("private let residency: ICModelResidency<ModelContainer>"))
        XCTAssertFalse(code.contains("var modelContainer"), "the service must not cache a container outside the residency")
        XCTAssertNotNil(code.range(of: #"func generate\(messages:[\s\S]{0,400}?let container = try await residency\.beginGeneration\(caller: caller\)"#,
                                   options: .regularExpression),
                        "generate must take its container AND lease from the residency in one step")
        XCTAssertNotNil(code.range(of: #"func load\(caller: ICCallerFeature = \.unknown\) async throws \{\s*_ = try await residency\.prepare\(caller: caller\)"#,
                                   options: .regularExpression))
        XCTAssertNotNil(code.range(of: #"selection: \{ Self\.selectedModelName \}"#, options: .regularExpression),
                        "the residency must read the live setting, not a cached name")
    }
}

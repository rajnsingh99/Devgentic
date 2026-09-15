// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillLaunchSequenceTests.swift
//  devgenticTests
//
//  That the skill library is prepared at launch, in the right order, and that the app still asks.
//
//  ⚠️⚠️ BOTH PROPERTIES HERE HAVE ALREADY FAILED IN PRODUCTION AND NEITHER HAD A TEST. The order
//  broke when `configureContainer` deferred its assignment behind the sweep (every store call
//  returned `.containerUnavailable`, on every launch, forever). The presence is the one call that
//  carries a pre-V6 user's skills into the library at all — delete it and they get a permanently
//  empty Skills library with no error anywhere.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class SkillLaunchSequenceTests: XCTestCase {

    private var container: ModelContainer!
    private let logger = DGLogger(category: "SkillLaunchSequenceTests")

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(for: DevgenticSchema.schema,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        container = nil
        try await super.tearDown()
    }

    /// ⚠️ THE ORDER BUG, pinned. `configure` must COMPLETE before `sweep` begins — the sweep's very
    /// first act is a store call, and a container that arrives afterwards arrives too late.
    ///
    /// **Mutation check:** call `sweep` before `configure` in `SkillLaunchSequence.run` and this
    /// goes red.
    func testTheStoreIsConfiguredBeforeTheSweepRuns() {
        var order: [String] = []
        SkillLaunchSequence.run(
            container: container,
            logger: logger,
            permits: { _, _ in true },
            configure: { _ in order.append("configure") },
            sweep: { _ in order.append("sweep") })

        XCTAssertEqual(order, ["configure", "sweep"],
                       "a container that arrives after the sweep has already started arrives too late")
    }

    /// ⚠️ THE PRESENCE BUG. Without this, removing the sweep call is a silent, permanent empty
    /// library for every upgrading user.
    func testTheSweepActuallyRuns() {
        var swept = false
        SkillLaunchSequence.run(container: container, logger: logger,
                                permits: { _, _ in true },
                                configure: { _ in }, sweep: { _ in swept = true })
        XCTAssertTrue(swept)
    }

    /// ⚠️ And it is REFUSED in the test host — the control that makes the test above honest. The
    /// sweep reads real skill folders and writes the real failure record; an ordinary
    /// `test-without-building` run must not consume the developer's own pending import.
    func testTheSweepIsRefusedWhenTheHostSaysNo() {
        var swept = false
        var configured = false
        SkillLaunchSequence.run(container: container, logger: logger,
                                permits: { _, _ in false },
                                configure: { _ in configured = true },
                                sweep: { _ in swept = true })

        XCTAssertFalse(swept, "the test host must never run the real sweep")
        XCTAssertTrue(configured,
                      "but the store is still configured — refusing an outward effect must not disable the app")
    }

    /// ⚠️⚠️ THE ORPHAN GUARD. Everything above tests a function; this tests that the APP STILL CALLS
    /// IT. Extracting a sequence to make it testable and then leaving it uncalled is the exact
    /// defect shape this feature has already shipped four times — correct code, no caller, green
    /// suite. Asserted on the source because the call happens inside `DevgenticApp`'s init closure,
    /// which has no observable seam.
    func testDevgenticAppStillRunsTheLaunchSequence() throws {
        let source = try Self.read("Devgentic/DevgenticApp.swift")
        XCTAssertTrue(source.contains("SkillLaunchSequence.run(container: container"),
                      "DevgenticApp must call the launch sequence — without it the skill library is never prepared")
    }

    /// The sweep must stay OUTSIDE the launch-sweep gate: that gate defers on `.deferSchemaChanged`,
    /// which is precisely the launch this has to run on — the first one after the schema changed.
    func testTheLaunchSequenceIsNotInsideTheDeferrableSweepGate() throws {
        let source = try Self.read("Devgentic/DevgenticApp.swift")
        // ⚠️ Anchored on the GATE ITSELF (`switch launchSweepDecision`), not on the first mention of
        // the value — which is its `let` binding near the top of the closure, long before anything
        // it gates. My first version of this test compared against that binding and failed on
        // correct code.
        let call = try XCTUnwrap(source.range(of: "SkillLaunchSequence.run(container: container"))
        let gate = try XCTUnwrap(source.range(of: "switch launchSweepDecision"))
        XCTAssertTrue(call.lowerBound < gate.lowerBound,
                      "the skills launch sequence must precede the deferrable sweep gate, not sit inside it")
    }

    private static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath) from \(#filePath) — source-reading tests need the checkout present.")
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  LocalModelRefresherTests.swift
//  DevgenticTests
//
//  Tests for LocalModelRefresher.planRefresh — the pure digest diff that decides
//  which cached LocalModels survive a refresh and which need a fresh /api/show
//  detection pass.
//

import XCTest
@testable import devgentic

final class LocalModelRefresherTests: XCTestCase {

    // MARK: - Helpers

    private func makeModel(_ name: String, digest: String?) -> LocalModel {
        let empty = OllamaShowResponse(
            license: nil, modelfile: nil, parameters: nil, template: nil,
            details: nil, capabilities: nil, modelInfo: nil
        )
        return LocalModel(name: name, digest: digest, response: empty)
    }

    private func entry(_ name: String, _ digest: String?) -> OllamaConnect.OllamaTagEntry {
        OllamaConnect.OllamaTagEntry(name: name, digest: digest)
    }

    // MARK: - Digest diff

    func testUnchangedDigests_AllReused_NothingFetched() {
        let plan = LocalModelRefresher.planRefresh(
            cached: [makeModel("a", digest: "d1"), makeModel("b", digest: "d2")],
            fresh: [entry("a", "d1"), entry("b", "d2")],
            daemonVersionChanged: false
        )
        XCTAssertEqual(Set(plan.reusableNames), ["a", "b"])
        XCTAssertTrue(plan.namesToFetch.isEmpty)
    }

    func testNewModel_Fetched_OthersReused() {
        // The gemma4 scenario: model pulled via CLI after the cache was built.
        let plan = LocalModelRefresher.planRefresh(
            cached: [makeModel("a", digest: "d1")],
            fresh: [entry("a", "d1"), entry("gemma4:latest", "d9")],
            daemonVersionChanged: false
        )
        XCTAssertEqual(plan.reusableNames, ["a"])
        XCTAssertEqual(plan.namesToFetch, ["gemma4:latest"])
    }

    func testChangedDigest_Refetched() {
        // Same tag re-pulled (e.g. `ollama pull model` picking up a new build).
        let plan = LocalModelRefresher.planRefresh(
            cached: [makeModel("a", digest: "old")],
            fresh: [entry("a", "new")],
            daemonVersionChanged: false
        )
        XCTAssertTrue(plan.reusableNames.isEmpty)
        XCTAssertEqual(plan.namesToFetch, ["a"])
    }

    func testRemovedModel_DroppedFromBothLists() {
        let plan = LocalModelRefresher.planRefresh(
            cached: [makeModel("a", digest: "d1"), makeModel("gone", digest: "d2")],
            fresh: [entry("a", "d1")],
            daemonVersionChanged: false
        )
        XCTAssertEqual(plan.reusableNames, ["a"])
        XCTAssertTrue(plan.namesToFetch.isEmpty)
        XCTAssertFalse(plan.reusableNames.contains("gone"))
    }

    func testDaemonVersionChanged_EverythingRefetched() {
        // A daemon upgrade can change /api/show output (capabilities, template)
        // for the SAME blob — digest reuse must be bypassed wholesale.
        let plan = LocalModelRefresher.planRefresh(
            cached: [makeModel("a", digest: "d1"), makeModel("b", digest: "d2")],
            fresh: [entry("a", "d1"), entry("b", "d2")],
            daemonVersionChanged: true
        )
        XCTAssertTrue(plan.reusableNames.isEmpty)
        XCTAssertEqual(Set(plan.namesToFetch), ["a", "b"])
    }

    func testNilCachedDigest_Refetched() {
        // Legacy cache entries (pre-digest builds) and failed detail fetches carry
        // nil digests — they must heal on the next pass, not be reused forever.
        let plan = LocalModelRefresher.planRefresh(
            cached: [makeModel("a", digest: nil)],
            fresh: [entry("a", "d1")],
            daemonVersionChanged: false
        )
        XCTAssertTrue(plan.reusableNames.isEmpty)
        XCTAssertEqual(plan.namesToFetch, ["a"])
    }

    func testNilFreshDigest_Refetched() {
        // A daemon that doesn't report digests can never prove "unchanged" —
        // conservative refetch.
        let plan = LocalModelRefresher.planRefresh(
            cached: [makeModel("a", digest: "d1")],
            fresh: [entry("a", nil)],
            daemonVersionChanged: false
        )
        XCTAssertTrue(plan.reusableNames.isEmpty)
        XCTAssertEqual(plan.namesToFetch, ["a"])
    }
}

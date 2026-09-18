// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeModelPickerReachabilityTests.swift
//  devgenticTests
//
//  The Code model picker's reachability invariant: EVERY installed model the provider reports is
//  reachable in the list, whatever its parameter count. Ordering may rank; only the user's own
//  search text may narrow.
//
//  ⚠️ These assert the INVARIANT, not today's implementation. They deliberately say nothing about
//  `rank`'s formula, tier names, or how search matches — a future change to any of those should
//  leave every test here green. What must fail is a model becoming UNREACHABLE.
//
//  History: a 14B floor filtered sub-threshold Ollama models out of the only rendered list, so
//  "too small" was indistinguishable from "not installed" — unsearchable, uncounted, and blamed on
//  the user's model library by the empty state. Two comments in the picker asserted the opposite of
//  what the code did for as long as it shipped. Parameter count is a quality proxy that decays with
//  every model generation, and it gated exactly one of four providers (Ollama; MLX passed nil,
//  cloud never built an entry). If a size floor is ever reintroduced, these fail.
//

import XCTest
@testable import devgentic

final class CodeModelPickerReachabilityTests: XCTestCase {

    // MARK: - Fixtures

    private func entry(
        _ name: String,
        size: Double,
        capability: ModelCognitiveCapability = .parallelActions,
        supportsThinking: Bool = false
    ) -> CodeModelEntry {
        CodeModelEntry(
            name: name,
            parameterSize: size > 0 ? "\(Int(size))B" : nil,
            parameterSizeValue: size,
            cognitiveProfile: CognitiveProfile(capability: capability, dialect: .heuristicJson),
            supportsThinking: supportsThinking
        )
    }

    /// Deliberately spans the retired 14B boundary on both sides, plus the unknown-size case that
    /// the old floor scored as 0 and therefore treated as "too small".
    private var mixedSizes: [CodeModelEntry] {
        [
            entry("tiny-0.5b", size: 0.5),
            entry("small-3b", size: 3),
            entry("under-7b", size: 7),
            entry("boundary-13b", size: 13),
            entry("at-14b", size: 14),
            entry("over-32b", size: 32),
            entry("unknown-size", size: 0),
        ]
    }

    // MARK: - The invariant

    func testEveryModelIsReachableRegardlessOfParameterCount() {
        let input = mixedSizes
        let listed = CodeModelListing.ordered(input, searchText: "")

        XCTAssertEqual(
            Set(listed.map(\.name)),
            Set(input.map(\.name)),
            "Ordering dropped a model. It may rank, never filter — a model absent from this list is "
            + "unreachable: unsearchable, uncounted in the provider tab, and reported by the empty "
            + "state as though it were not installed."
        )
        XCTAssertEqual(listed.count, input.count, "Ordering must be a permutation, not a subset.")
    }

    func testSubThresholdModelsSurviveIndividually() {
        // Each asserted by name so a failure says WHICH size band was dropped.
        for model in mixedSizes {
            let listed = CodeModelListing.ordered(mixedSizes, searchText: "")
            XCTAssertTrue(
                listed.contains(where: { $0.name == model.name }),
                "'\(model.name)' (\(model.parameterSizeValue)B) is not reachable in the picker."
            )
        }
    }

    func testAModelTooSmallForTheOldFloorIsStillSearchable() {
        // The sharpest form of the old defect: the user knows the model is installed and types its
        // name, and the picker still insists it does not exist.
        let listed = CodeModelListing.ordered(mixedSizes, searchText: "small-3b")

        XCTAssertEqual(listed.map(\.name), ["small-3b"],
                       "A sub-14B model must be findable by typing its name.")
    }

    func testUnknownParameterSizeIsReachable() {
        // `parameterSizeValue` is 0 when the daemon reports no `parameter_size`. The old floor
        // failed CLOSED on that, reading "we could not measure it" as "it is too small".
        let listed = CodeModelListing.ordered(mixedSizes, searchText: "")

        XCTAssertTrue(listed.contains(where: { $0.name == "unknown-size" }),
                      "An unreadable parameter count must never be treated as a small one.")
    }

    func testLowCapabilityModelIsRankedNotRemoved() {
        // Capability is the signal that replaced size. It must annotate and sort — never gate.
        // ⚠️ Deliberately sub-14B. With a 20B fixture this test survived BOTH size-filter mutants
        // while every sibling died — it was asserting capability-is-not-a-gate on a model no size
        // floor would have touched. A small single-action model is the realistic case anyway, and
        // it now fails for either reason it should.
        let input = mixedSizes + [entry("single-action-6b", size: 6, capability: .singleAction)]
        let listed = CodeModelListing.ordered(input, searchText: "")

        XCTAssertTrue(listed.contains(where: { $0.name == "single-action-6b" }),
                      "A single-action model runs in Code mode via the Markdown/ReAct generator; "
                      + "it must be selectable.")
        XCTAssertEqual(listed.last?.name, "single-action-6b",
                       "Lower tool capability should sort last — ranked, not removed.")
    }

    // MARK: - Search is the only permitted narrowing

    func testEmptySearchNarrowsNothing() {
        XCTAssertEqual(CodeModelListing.ordered(mixedSizes, searchText: "").count, mixedSizes.count)
        XCTAssertEqual(CodeModelListing.ordered(mixedSizes, searchText: "   ").count, mixedSizes.count,
                       "Whitespace is not a query — it must not empty the list.")
    }

    func testSearchIsCaseInsensitiveAndRecoverable() {
        XCTAssertEqual(CodeModelListing.ordered(mixedSizes, searchText: "BOUNDARY").map(\.name),
                       ["boundary-13b"])
        // Clearing the box restores everything: the narrowing was the user's and is undoable.
        XCTAssertEqual(CodeModelListing.ordered(mixedSizes, searchText: "").count, mixedSizes.count)
    }

    // MARK: - Detection is recorded, not discarded

    func testThinkingSupportIsCarriedOnTheEntry() {
        // Code still selects with thinking OFF — the loop pays that cost per iteration. But the
        // capability must survive detection so the choice is visible and can be offered later.
        // Previously it was dropped at entry construction and nothing downstream could see it.
        let thinker = entry("qwen3-8b", size: 8, supportsThinking: true)
        let plain = entry("llama-8b", size: 8, supportsThinking: false)

        let listed = CodeModelListing.ordered([thinker, plain], searchText: "")

        XCTAssertEqual(listed.first(where: { $0.name == "qwen3-8b" })?.supportsThinking, true)
        XCTAssertEqual(listed.first(where: { $0.name == "llama-8b" })?.supportsThinking, false)
    }

    func testThinkingSupportDoesNotAffectReachabilityOrOrder() {
        // It is metadata, not a ranking term — the same trap parameter count fell into.
        let thinker = entry("aaa-thinker", size: 8, supportsThinking: true)
        let plain = entry("bbb-plain", size: 8, supportsThinking: false)

        XCTAssertEqual(CodeModelListing.ordered([plain, thinker], searchText: "").map(\.name),
                       ["aaa-thinker", "bbb-plain"],
                       "Order must stay alphabetical within a capability rank; thinking support "
                       + "must not promote or demote a model.")
    }
}

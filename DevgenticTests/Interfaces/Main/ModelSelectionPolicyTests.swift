//
//  ModelSelectionPolicyTests.swift
//  DevgenticTests
//
//  Created on 08/08/26.
//
//  Register A37 — the Ollama picker silently rewrote the profile's persisted `modelName` on appear
//  when the stored model was absent from the daemon's list.
//
//  ⚠️ This rule has been broken and re-fixed FOUR times across the model pickers (G95 OpenRouter,
//  MP-01 cloud, A37 Ollama), because each picker owned its own copy of it. `ModelSelectionPolicy`
//  is now the single implementation and all four pickers route through it — so these tests cover
//  every picker at once, which is the whole point of extracting it.
//

import XCTest
@testable import devgentic

final class ModelSelectionPolicyTests: XCTestCase {

    private let catalogue = ["llama3:8b", "qwen2.5:14b", "mistral:7b"]

    // MARK: - The rule the pickers kept getting wrong

    /// ⚠️ THE A37 case. `ollama rm` on one model — or a daemon still starting — used to repoint the
    /// profile at a different model, on `.onAppear`, with no notice and no undo.
    func testASavedModelMissingFromTheListIsKept() {
        let resolution = ModelSelectionPolicy.resolve(saved: "deepseek-r1:32b", available: catalogue)

        XCTAssertEqual(resolution, .keptUnlisted("deepseek-r1:32b"),
                       "an unlisted model is not a wrong model — never rewrite what the user chose")
    }

    /// ⚠️ The least safe moment to conclude a saved model is invalid: the fetch returned nothing, so
    /// the daemon is probably down. Rewriting here would be worst of all.
    func testAnEmptyListNeverInvalidatesASavedModel() {
        XCTAssertEqual(ModelSelectionPolicy.resolve(saved: "llama3:8b", available: []),
                       .keptUnlisted("llama3:8b"))
    }

    func testASavedModelPresentInTheListIsLeftAlone() {
        XCTAssertEqual(ModelSelectionPolicy.resolve(saved: "qwen2.5:14b", available: catalogue), .keep)
    }

    // MARK: - Filling is only ever for an empty selection

    /// A new profile has nothing to preserve, so filling it is correct — and is the ONLY case where
    /// the policy writes.
    func testAnEmptySelectionIsFilledWithTheFirstModel() {
        XCTAssertEqual(ModelSelectionPolicy.resolve(saved: "", available: catalogue),
                       .fill("llama3:8b"))
    }

    /// The agent picker prefers a tool-capable model when filling; the policy takes that choice as
    /// a parameter rather than reimplementing capability ranking.
    func testAnEmptySelectionPrefersTheSuppliedCandidate() {
        XCTAssertEqual(
            ModelSelectionPolicy.resolve(saved: "", available: catalogue, fillCandidate: "qwen2.5:14b"),
            .fill("qwen2.5:14b"))
    }

    /// ⚠️ A fill candidate must NOT override a saved selection — that would reintroduce the exact
    /// rewrite this policy exists to prevent, just by a different route.
    func testAFillCandidateIsIgnoredWhenSomethingIsAlreadySelected() {
        XCTAssertEqual(
            ModelSelectionPolicy.resolve(saved: "mistral:7b", available: catalogue, fillCandidate: "llama3:8b"),
            .keep)
    }

    func testNothingToFillWithIsReportedRatherThanBlanked() {
        XCTAssertEqual(ModelSelectionPolicy.resolve(saved: "", available: []), .nothingAvailable,
                       "an empty fetch must not resolve to writing an empty model name")
    }

    // MARK: - The policy never writes except to fill

    /// The load-bearing invariant, stated as one assertion over the whole input space the pickers
    /// see: a non-empty saved model is NEVER replaced, whatever the fetch returned.
    func testANonEmptySelectionIsNeverReplaced() {
        let savedValues = ["llama3:8b", "deepseek-r1:32b", "hand-typed/model:latest"]
        let lists = [[], catalogue, ["something-else"]] as [[String]]

        for saved in savedValues {
            for list in lists {
                for candidate in [nil, "llama3:8b"] as [String?] {
                    let resolution = ModelSelectionPolicy.resolve(
                        saved: saved, available: list, fillCandidate: candidate)

                    if case .fill(let replacement) = resolution {
                        XCTFail("saved '\(saved)' was replaced with '\(replacement)' "
                                + "(list: \(list), candidate: \(candidate ?? "nil")) — "
                                + "fill is only ever for an EMPTY selection")
                    }
                }
            }
        }
    }
}

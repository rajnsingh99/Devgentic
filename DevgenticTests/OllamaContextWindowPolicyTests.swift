//
//  OllamaContextWindowPolicyTests.swift
//  devgenticTests
//
//  Created on 12/07/26.
//
//  Covers the shared num_ctx resolution used by BOTH the Ollama request factory
//  (what gets sent) and the retrieval budget (what gets assumed) — the pair must
//  never disagree, or retrieval sizes itself for a window the request doesn't have.
//

import XCTest
@testable import devgentic

final class OllamaContextWindowPolicyTests: XCTestCase {

    // MARK: - configuredNumCtx extraction

    func testConfiguredNumCtx_ReadsNumberOption() {
        let options: [String: JSONValue] = ["numCtx": .number(16384)]
        XCTAssertEqual(OllamaContextWindowPolicy.configuredNumCtx(in: options), 16_384)
    }

    func testConfiguredNumCtx_NilForMissingOrInvalid() {
        XCTAssertNil(OllamaContextWindowPolicy.configuredNumCtx(in: nil))
        XCTAssertNil(OllamaContextWindowPolicy.configuredNumCtx(in: [:]))
        XCTAssertNil(OllamaContextWindowPolicy.configuredNumCtx(in: ["numCtx": .string("big")]))
        XCTAssertNil(OllamaContextWindowPolicy.configuredNumCtx(in: ["numCtx": .number(0)]))
        XCTAssertNil(OllamaContextWindowPolicy.configuredNumCtx(in: ["temperature": .number(0.7)]))
    }

    // MARK: - autoNumCtx (what the factory sends when the user set nothing)

    func testAutoNumCtx_UsesTrainedMax_WhenUnderCap() {
        XCTAssertEqual(OllamaContextWindowPolicy.autoNumCtx(trainedContextWindow: 8_192), 8_192)
    }

    func testAutoNumCtx_MemoryCapsLargeTrainedWindows() {
        // Llama-3.1-class (128K trained): allocate the cap, not 128K of KV cache.
        XCTAssertEqual(
            OllamaContextWindowPolicy.autoNumCtx(trainedContextWindow: 131_072),
            OllamaContextWindowPolicy.autoDefaultCap
        )
    }

    func testAutoNumCtx_NilWhenTrainedUnknown() {
        // Unknown model: send nothing rather than guess — server default applies.
        XCTAssertNil(OllamaContextWindowPolicy.autoNumCtx(trainedContextWindow: nil))
        XCTAssertNil(OllamaContextWindowPolicy.autoNumCtx(trainedContextWindow: 0))
    }

    // MARK: - effectiveTokens (what the budget assumes)

    func testEffectiveTokens_ConfiguredValueWins() {
        // Explicit user choice is the allocation — even when it disagrees with
        // the trained size in either direction.
        XCTAssertEqual(OllamaContextWindowPolicy.effectiveTokens(configuredNumCtx: 2_048, trainedContextWindow: 8_192), 2_048)
        XCTAssertEqual(OllamaContextWindowPolicy.effectiveTokens(configuredNumCtx: 32_768, trainedContextWindow: 8_192), 32_768)
    }

    func testEffectiveTokens_FallsBackToAutoDefault() {
        // Mirrors the factory: unset numCtx + known trained max → the auto value.
        XCTAssertEqual(OllamaContextWindowPolicy.effectiveTokens(configuredNumCtx: nil, trainedContextWindow: 8_192), 8_192)
        XCTAssertEqual(
            OllamaContextWindowPolicy.effectiveTokens(configuredNumCtx: nil, trainedContextWindow: 131_072),
            OllamaContextWindowPolicy.autoDefaultCap
        )
    }

    func testEffectiveTokens_AssumesServerDefaultWhenNothingKnown() {
        XCTAssertEqual(
            OllamaContextWindowPolicy.effectiveTokens(configuredNumCtx: nil, trainedContextWindow: nil),
            OllamaContextWindowPolicy.assumedServerDefault
        )
    }

    // MARK: - Budget integration sanity

    func testRetrievalBudget_ShrinksUnderServerDefaultAssumption() {
        // The gemma-unset case end-to-end: unknown trained size → 4,096 assumed
        // → retrieval injection stays well inside a default Ollama allocation.
        let window = OllamaContextWindowPolicy.effectiveTokens(configuredNumCtx: nil, trainedContextWindow: nil)
        let budget = RAGRetrievalBudget.budgets(forContextWindowTokens: window)
        XCTAssertLessThanOrEqual(budget.total, 2_000, "retrieval must not dominate a 4K-token allocation")
        XCTAssertGreaterThanOrEqual(budget.total, RAGRetrievalBudget.minTotal)
    }
}

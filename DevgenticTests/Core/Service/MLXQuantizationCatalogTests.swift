// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXQuantizationCatalogTests.swift
//  DevgenticTests
//
//  G5 (quantization awareness) and G7 (curated first run + non-LLM filtering).
//

import XCTest
@testable import devgentic

final class MLXQuantizationParsingTests: XCTestCase {

    /// Real repo ids from the live listing this app calls.
    func testParsesTheSuffixesPublishersActuallyUse() {
        XCTAssertEqual(MLXQuantization.parse(fromRepoId: "mlx-community/Qwen2.5-3B-Instruct-4bit"), .fourBit)
        XCTAssertEqual(MLXQuantization.parse(fromRepoId: "lmstudio-community/gemma-4-E4B-it-MLX-5bit"), .fiveBit)
        XCTAssertEqual(MLXQuantization.parse(fromRepoId: "lmstudio-community/Qwen3.5-9B-MLX-8bit"), .eightBit)
        XCTAssertEqual(MLXQuantization.parse(fromRepoId: "badmadrad/Devstral-Small-2-24B-Instruct-2512-MLX-3bit"), .threeBit)
        XCTAssertEqual(MLXQuantization.parse(fromRepoId: "mlx-community/SomeModel-bf16"), .sixteenBit)
    }

    /// ⚠️ THE trap. `Devstral-Small-2-24B-…-3bit` contains the substring "4bit" inside "24B";
    /// a naive `contains` would report 4-bit for a 3-bit model and the RAM estimate would be
    /// wrong in the unsafe direction.
    func testAParameterCountIsNeverMistakenForAQuantization() {
        // 24B must not read as 4-bit — the real quantization here is 3-bit.
        XCTAssertEqual(
            MLXQuantization.parse(fromRepoId: "badmadrad/Devstral-Small-2-24B-Instruct-2512-MLX-3bit"),
            .threeBit
        )
        // A model with no quantization suffix at all must report none, not one inferred from
        // its parameter count.
        XCTAssertNil(MLXQuantization.parse(fromRepoId: "mlx-community/Meta-Llama-3.1-8B-Instruct"))
        XCTAssertNil(MLXQuantization.parse(fromRepoId: "mlx-community/Qwen2.5-3B-Instruct"))
    }

    func testUnquantizedNamesReportNothing() {
        XCTAssertNil(MLXQuantization.parse(fromRepoId: "mlx-community/SmolVLM2-2.2B-Instruct-mlx"))
        XCTAssertNil(MLXQuantization.parse(fromRepoId: "srswti/bodega-raptor-90m"))
    }

    func testParameterCountRequiresABSuffix() {
        XCTAssertEqual(MLXQuantization.parameterCount(fromRepoId: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"), "8B")
        XCTAssertEqual(MLXQuantization.parameterCount(fromRepoId: "mlx-community/Qwen2.5-3B-Instruct-4bit"), "3B")
        XCTAssertEqual(MLXQuantization.parameterCount(fromRepoId: "lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-4bit"), "30B")
        // No parameter count present.
        XCTAssertNil(MLXQuantization.parameterCount(fromRepoId: "mlx-community/Phi-4-mini-instruct-4bit"))
    }

    /// The fit advisor needs a parameter count to run its formula; quantization alone can't
    /// drive it, and a synthesised `tier` would preempt the honest `.unknown` verdict.
    func testFitMetadataIsOnlyProducedWhenAParameterCountExists() {
        let withParams = MLXQuantization.fitMetadata(forRepoId: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit")
        XCTAssertEqual(withParams?.parameterCount, "8B")
        XCTAssertEqual(withParams?.quantization, "4bit")

        XCTAssertNil(
            MLXQuantization.fitMetadata(forRepoId: "mlx-community/Phi-4-mini-instruct-4bit"),
            "without a parameter count the advisor's disk-size path must answer instead"
        )
    }

    /// Feeding real bits-per-weight must actually change the verdict versus the disk proxy —
    /// otherwise the whole G5 fit change is inert.
    func testQuantizationChangesTheFitEstimate() {
        let fourBit = ModelFitAdvisor.assess(
            metadata: MLXQuantization.fitMetadata(forRepoId: "org/Model-70B-4bit"), modelName: "org/Model-70B-4bit"
        )
        let eightBit = ModelFitAdvisor.assess(
            metadata: MLXQuantization.fitMetadata(forRepoId: "org/Model-70B-8bit"), modelName: "org/Model-70B-8bit"
        )
        XCTAssertGreaterThan(eightBit.estimatedRuntimeRAM, fourBit.estimatedRuntimeRAM,
                             "8-bit must estimate more memory than 4-bit for the same model")
    }
}

final class CuratedCatalogTests: XCTestCase {

    /// ⚠️ Every entry must be a well-formed `author/name` repo id. A typo here is a 404 on a
    /// brand-new user's very first action.
    func testEveryCuratedEntryIsAWellFormedRepoId() {
        XCTAssertFalse(CuratedMLXCatalog.models.isEmpty)
        for model in CuratedMLXCatalog.models {
            let parts = model.id.components(separatedBy: "/")
            XCTAssertEqual(parts.count, 2, "\(model.id) is not author/name")
            XCTAssertFalse(parts[0].isEmpty)
            XCTAssertFalse(parts[1].isEmpty)
            XCTAssertFalse(model.rationale.isEmpty, "\(model.id) has no rationale")
            XCTAssertGreaterThan(model.approximateBytes, 0)
        }
    }

    func testCuratedEntriesAreUnique() {
        let ids = CuratedMLXCatalog.models.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// Ordering only — nothing is hidden. A user on a small machine must still be able to
    /// reach every entry, per the standing describe-don't-gate directive.
    func testRAMOrderingNeverDropsModels() {
        for ram in [8, 16, 24, 32, 64] {
            let ordered = CuratedMLXCatalog.recommended(forSystemRAMGB: ram)
            XCTAssertEqual(ordered.count, CuratedMLXCatalog.models.count,
                           "RAM ordering dropped entries at \(ram) GB — it must sort, not filter")
        }
    }

    /// On a small machine the models it can actually run come first.
    func testModelsThatFitComeFirst() {
        let ordered = CuratedMLXCatalog.recommended(forSystemRAMGB: 8)
        let firstOversized = ordered.firstIndex { $0.recommendedMinimumRAMGB > 8 }
        let lastFitting = ordered.lastIndex { $0.recommendedMinimumRAMGB <= 8 }
        if let firstOversized, let lastFitting {
            XCTAssertLessThan(lastFitting, firstOversized)
        }
    }
}

final class MLXPipelineFilterTests: XCTestCase {

    /// The concrete case from the live listing: results 1, 2 and 29 of the top 30 were
    /// speech-recognition models rendered with a "Chat" badge.
    func testSpeechRecognitionModelsAreExcluded() {
        XCTAssertTrue(MLXPipelineFilter.shouldExclude(pipelineTag: "automatic-speech-recognition"))
        XCTAssertTrue(MLXPipelineFilter.shouldExclude(pipelineTag: "text-to-speech"))
        XCTAssertTrue(MLXPipelineFilter.shouldExclude(pipelineTag: "feature-extraction"))
    }

    /// ⚠️ `any-to-any` accounts for 8 of the live top 30 — the gemma-4 multimodal models,
    /// which ARE usable LLMs. An allowlist built from the obvious tags would have hidden all
    /// of them, which is why this is a denylist.
    func testUsableModelsAreNotExcluded() {
        XCTAssertFalse(MLXPipelineFilter.shouldExclude(pipelineTag: "text-generation"))
        XCTAssertFalse(MLXPipelineFilter.shouldExclude(pipelineTag: "image-text-to-text"))
        XCTAssertFalse(MLXPipelineFilter.shouldExclude(pipelineTag: "any-to-any"))
    }

    /// An unfamiliar or missing tag must stay visible — the vocabulary moves, and hiding
    /// unknown models would make the store look broken.
    func testUnknownAndMissingTagsStayVisible() {
        XCTAssertFalse(MLXPipelineFilter.shouldExclude(pipelineTag: nil))
        XCTAssertFalse(MLXPipelineFilter.shouldExclude(pipelineTag: "some-future-tag"))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(MLXPipelineFilter.shouldExclude(pipelineTag: "Automatic-Speech-Recognition"))
    }
}

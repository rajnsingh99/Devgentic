// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXModelDetailTests.swift
//  DevgenticTests
//
//  G6 — the model detail sheet. The parsing is what can break silently: HuggingFace's schema
//  is loose (fields present on some repos and absent on others, and `gated`/`base_model`
//  change TYPE between repos), so a strict decode would fail for real models in the store.
//
//  Fixtures below are trimmed from real API responses.
//

import XCTest
@testable import devgentic

final class MLXModelDetailDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> HFModelDetail {
        try JSONDecoder().decode(HFModelDetail.self, from: Data(json.utf8))
    }

    /// A fully-populated repo (mlx-community/Phi-4-mini-instruct-4bit shape).
    func testDecodesARichResponse() throws {
        let response = try decode("""
        {
          "id": "mlx-community/Phi-4-mini-instruct-4bit",
          "author": "mlx-community",
          "downloads": 2282, "likes": 3,
          "tags": ["transformers", "phi3", "text-generation"],
          "lastModified": "2025-03-05T05:17:13.000Z",
          "gated": false,
          "usedStorage": 2173624891,
          "cardData": { "license": "mit", "license_link": "https://example.com/LICENSE" },
          "config": { "architectures": ["Phi3ForCausalLM"], "model_type": "phi3",
                      "quantization_config": { "bits": 4 } },
          "safetensors": { "total": 599546880 },
          "siblings": [ { "rfilename": "config.json" }, { "rfilename": "model.safetensors" } ]
        }
        """)
        let detail = MLXModelDetail(repoId: "mlx-community/Phi-4-mini-instruct-4bit", response: response)

        XCTAssertEqual(detail.license, "mit")
        XCTAssertEqual(detail.licenseURL?.absoluteString, "https://example.com/LICENSE")
        XCTAssertEqual(detail.quantizationBits, 4)
        XCTAssertEqual(detail.quantizationSummary, "4-bit")
        XCTAssertEqual(detail.architecture, "Phi3ForCausalLM")
        XCTAssertEqual(detail.totalBytes, 2_173_624_891)
        XCTAssertEqual(detail.fileCount, 2)
        XCTAssertEqual(detail.weightFileCount, 1)
        XCTAssertFalse(detail.isGated)
        XCTAssertNotNil(detail.lastModified)
    }

    /// ⚠️ Roughly half of real MLX repos omit `quantization_config`, `cardData` and
    /// `safetensors`. A strict decode would throw and the sheet would show an error for a
    /// perfectly ordinary model.
    func testDecodesASparseResponseWithoutFailing() throws {
        let response = try decode("""
        { "id": "mlx-community/Sparse", "siblings": [],
          "config": { "architectures": ["Qwen2ForCausalLM"], "model_type": "qwen2" } }
        """)
        let detail = MLXModelDetail(repoId: "mlx-community/Sparse", response: response)

        XCTAssertNil(detail.license)
        XCTAssertNil(detail.quantizationBits)
        XCTAssertNil(detail.totalBytes)
        XCTAssertEqual(detail.architecture, "Qwen2ForCausalLM")
        XCTAssertEqual(detail.fileCount, 0)
        XCTAssertFalse(detail.isGated)
    }

    /// `gated` is `false` on open repos and a STRING ("auto"/"manual") on gated ones. Decoding
    /// it as `Bool` would throw on exactly the repos the warning is for.
    func testGatedDecodesFromBothBoolAndString() throws {
        let open = try decode(#"{ "siblings": [], "gated": false }"#)
        XCTAssertFalse(MLXModelDetail(repoId: "a/b", response: open).isGated)

        for kind in ["auto", "manual"] {
            let gated = try decode(#"{ "siblings": [], "gated": "\#(kind)" }"#)
            XCTAssertTrue(MLXModelDetail(repoId: "a/b", response: gated).isGated,
                          "gated:\"\(kind)\" must surface the token warning")
        }
    }

    /// `base_model` is a string for some publishers and an array for others.
    func testBaseModelDecodesFromBothShapes() throws {
        let single = try decode(#"{ "siblings": [], "cardData": { "base_model": "microsoft/phi-4" } }"#)
        XCTAssertEqual(MLXModelDetail(repoId: "a/b", response: single).baseModels, ["microsoft/phi-4"])

        let many = try decode(#"{ "siblings": [], "cardData": { "base_model": ["a/one", "b/two"] } }"#)
        XCTAssertEqual(MLXModelDetail(repoId: "a/b", response: many).baseModels, ["a/one", "b/two"])
    }

    /// When the API omits the quantization config, fall back to the model name — that is where
    /// MLX publishers actually encode it.
    func testQuantizationFallsBackToTheModelName() throws {
        let response = try decode(#"{ "siblings": [] }"#)
        let detail = MLXModelDetail(repoId: "mlx-community/Qwen2.5-3B-Instruct-4bit", response: response)
        XCTAssertEqual(detail.quantizationSummary, "4-bit (from the model name)")

        let eight = MLXModelDetail(repoId: "lmstudio-community/Qwen3.5-9B-MLX-8bit", response: response)
        XCTAssertEqual(eight.quantizationSummary, "8-bit (from the model name)")
    }

    /// ⚠️ Verified against the live API across four MLX repos: `max_position_embeddings` is
    /// never published. The sheet says "Not published" rather than inventing a number, and
    /// this pins that we haven't quietly started claiming otherwise.
    func testContextWindowIsNeverClaimedPreDownload() throws {
        let response = try decode(#"{ "siblings": [], "config": { "model_type": "phi3" } }"#)
        XCTAssertNil(MLXModelDetail(repoId: "a/b", response: response).contextWindow)
    }
}

final class HFModelCardExcerptTests: XCTestCase {

    /// Every HF model card opens with YAML front matter duplicating the structured fields the
    /// sheet already shows above the prose.
    func testFrontMatterIsStripped() {
        let excerpt = HFModelCard.excerpt(from: """
        ---
        license: mit
        tags: [mlx]
        ---
        # Phi-4-mini

        This model was converted to MLX format.
        """)
        XCTAssertFalse(excerpt.contains("license: mit"))
        XCTAssertTrue(excerpt.hasPrefix("# Phi-4-mini"))
    }

    func testCardWithoutFrontMatterIsUntouched() {
        XCTAssertEqual(HFModelCard.excerpt(from: "# Plain\n\nNo front matter."), "# Plain\n\nNo front matter.")
    }

    /// A full card can run to tens of thousands of characters; the sheet is a decision aid.
    func testLongCardsAreTruncated() {
        let long = String(repeating: "word word word\n", count: 2000)
        let excerpt = HFModelCard.excerpt(from: long)
        XCTAssertLessThanOrEqual(excerpt.count, HFModelCard.excerptLimit + 8)
        XCTAssertTrue(excerpt.hasSuffix("…"))
    }

    func testEmptyCardStaysEmpty() {
        XCTAssertTrue(HFModelCard.excerpt(from: "---\nlicense: mit\n---\n").isEmpty)
    }
}

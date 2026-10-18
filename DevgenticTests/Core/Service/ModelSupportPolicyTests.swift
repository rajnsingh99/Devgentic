// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModelSupportPolicyTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ModelSupportPolicyTests: XCTestCase {

    private func decode(_ json: String) throws -> HFModelDetail {
        try JSONDecoder().decode(HFModelDetail.self, from: Data(json.utf8))
    }

    // MARK: - Real repo shapes, through the real decode → detail path

    func testLayaIsUnsupportedDespiteHavingNoArchitectures() throws {
        let response = try decode("""
        { "id": "convaiinnovations/laya", "pipeline_tag": "text-classification",
          "library_name": "transformers",
          "tags": ["transformers", "safetensors", "laya", "system-one", "calibrated-decisions",
                   "text-classification", "license:apache-2.0"],
          "config": {}, "siblings": [ { "rfilename": "model.safetensors" } ] }
        """)
        let detail = MLXModelDetail(repoId: "convaiinnovations/laya", response: response)
        XCTAssertNil(detail.architecture, "fixture must keep the empty config that defeats an architecture check")
        XCTAssertNotNil(detail.unsupportedReason)
    }

    func testGLiNERDecideIsUnsupported() throws {
        let response = try decode("""
        { "id": "fastino/GLiNER2.5-Decide", "pipeline_tag": "token-classification",
          "library_name": "gliner2",
          "tags": ["gliner2", "safetensors", "extractor", "token-classification"],
          "config": { "architectures": ["SpanExtractor"], "model_type": "extractor" },
          "siblings": [ { "rfilename": "model.safetensors" } ] }
        """)
        let detail = MLXModelDetail(repoId: "fastino/GLiNER2.5-Decide", response: response)
        XCTAssertNotNil(detail.unsupportedReason)
    }

    func testOrdinaryChatModelIsSupported() throws {
        let response = try decode("""
        { "id": "mlx-community/Qwen3-8B-4bit", "pipeline_tag": "text-generation",
          "tags": ["mlx", "safetensors", "qwen3", "text-generation"],
          "config": { "architectures": ["Qwen3ForCausalLM"], "model_type": "qwen3" },
          "siblings": [ { "rfilename": "model.safetensors" } ] }
        """)
        XCTAssertNil(MLXModelDetail(repoId: "mlx-community/Qwen3-8B-4bit", response: response).unsupportedReason)
    }

    // MARK: - Policy rules

    func testDecisionPipelinesAreUnsupportedAndNameTheDecisionModelKind() {
        for tag in ["text-classification", "token-classification", "zero-shot-classification"] {
            let reason = ModelSupportPolicy.unsupportedReason(pipelineTag: tag, tags: [])
            XCTAssertNotNil(reason, tag)
            XCTAssertTrue(reason?.contains("decision") == true, "\(tag): reason should say decision/classifier — got \(reason ?? "nil")")
        }
    }

    func testSystemOneTagAloneMakesAModelUnsupported() {
        XCTAssertNotNil(ModelSupportPolicy.unsupportedReason(pipelineTag: "other", tags: ["System-One"]),
                        "a repo can carry the category's own tag under an unfamiliar pipeline")
    }

    func testUntaggedStaysSupported() {
        XCTAssertNil(ModelSupportPolicy.unsupportedReason(pipelineTag: nil, tags: []),
                     "the same stance MLXPipelineFilter takes: unknown stays visible")
        XCTAssertNil(ModelSupportPolicy.unsupportedReason(pipelineTag: "any-to-any", tags: ["mlx"]),
                     "gemma-4 multimodal LLMs ride `any-to-any` and must stay downloadable")
    }

    /// The invariant that keeps the LISTING and the BUTTON in agreement: whatever the search
    /// filter's denylist hides, the policy must also refuse. Written from that invariant, not from
    /// today's contents of the set — a tag added to the denylist is covered automatically.
    func testEveryExcludedPipelineTagIsUnsupported() {
        for tag in MLXPipelineFilter.excludedPipelineTags {
            XCTAssertNotNil(ModelSupportPolicy.unsupportedReason(pipelineTag: tag, tags: []),
                            "'\(tag)' is hidden from the store listing but the policy would still offer a Download button")
        }
    }

    func testPipelineMatchIsCaseInsensitive() {
        XCTAssertNotNil(ModelSupportPolicy.unsupportedReason(pipelineTag: "Text-Classification", tags: []))
    }

    // MARK: - Card wiring

    func testDisplayModelReadsThePolicy() {
        let blocked = MLXDisplayModel(id: "a/b", pipelineTag: "text-classification",
                                      capabilities: [.textGeneration], tags: [], downloads: 0, likes: 0, description: nil)
        let fine = MLXDisplayModel(id: "a/c", pipelineTag: "text-generation",
                                   capabilities: [.textGeneration], tags: [], downloads: 0, likes: 0, description: nil)
        XCTAssertNotNil(blocked.unsupportedReason)
        XCTAssertNil(fine.unsupportedReason)
    }

    // MARK: - Ollama pull names

    func testHuggingFaceRepoIdFromOllamaName() {
        XCTAssertEqual(ModelSupportPolicy.huggingFaceRepoId(fromOllamaName: "hf.co/bartowski/Llama-3.2-3B-GGUF:Q4_K_M"),
                       "bartowski/Llama-3.2-3B-GGUF")
        XCTAssertEqual(ModelSupportPolicy.huggingFaceRepoId(fromOllamaName: "  HF.CO/a/b  "), "a/b")
        XCTAssertEqual(ModelSupportPolicy.huggingFaceRepoId(fromOllamaName: "huggingface.co/a/b"), "a/b")
    }

    func testLibraryAndMalformedNamesHaveNoRepoId() {
        for name in ["llama3.2:3b", "qwen3", "hf.co/onlyowner", "hf.co/a/b/c", "hf.co/../b", "hf.co//b", ""] {
            XCTAssertNil(ModelSupportPolicy.huggingFaceRepoId(fromOllamaName: name), name)
        }
    }
}

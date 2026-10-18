// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXContextWindowTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class MLXContextWindowTests: XCTestCase {

    func testReadsMaxPositionEmbeddings() {
        XCTAssertEqual(MLXTokenizerAnalyzer.contextWindow(fromConfig: ["max_position_embeddings": 32_768]), 32_768)
    }

    func testMaxPositionEmbeddingsWinsOverOtherKeys() {
        let json: [String: Any] = ["max_position_embeddings": 8_192, "n_positions": 2_048, "max_seq_len": 4_096]
        XCTAssertEqual(MLXTokenizerAnalyzer.contextWindow(fromConfig: json), 8_192)
    }

    func testFallbackKeysAreRead() {
        XCTAssertEqual(MLXTokenizerAnalyzer.contextWindow(fromConfig: ["n_positions": 2_048]), 2_048)
        XCTAssertEqual(MLXTokenizerAnalyzer.contextWindow(fromConfig: ["max_seq_len": 4_096]), 4_096)
        XCTAssertEqual(MLXTokenizerAnalyzer.contextWindow(fromConfig: ["max_sequence_length": 8_192]), 8_192)
        XCTAssertEqual(MLXTokenizerAnalyzer.contextWindow(fromConfig: ["seq_length": 16_384]), 16_384)
        XCTAssertEqual(MLXTokenizerAnalyzer.contextWindow(fromConfig: ["n_ctx": 131_072]), 131_072)
    }

    func testNestedTextConfigForMultimodal() {
        // Multimodal configs nest the language-model window under text_config.
        let json: [String: Any] = ["text_config": ["max_position_embeddings": 131_072]]
        XCTAssertEqual(MLXTokenizerAnalyzer.contextWindow(fromConfig: json), 131_072)
    }

    func testTopLevelWinsOverNested() {
        let json: [String: Any] = ["max_position_embeddings": 4_096,
                                   "text_config": ["max_position_embeddings": 131_072]]
        XCTAssertEqual(MLXTokenizerAnalyzer.contextWindow(fromConfig: json), 4_096)
    }

    func testCoercesStringAndDoubleNumbers() {
        XCTAssertEqual(MLXTokenizerAnalyzer.contextWindow(fromConfig: ["max_position_embeddings": "32768"]), 32_768)
        XCTAssertEqual(MLXTokenizerAnalyzer.contextWindow(fromConfig: ["max_position_embeddings": 32_768.0]), 32_768)
    }

    func testRejectsZeroNegativeMissingAndSlidingWindow() {
        XCTAssertNil(MLXTokenizerAnalyzer.contextWindow(fromConfig: ["max_position_embeddings": 0]))
        XCTAssertNil(MLXTokenizerAnalyzer.contextWindow(fromConfig: ["max_position_embeddings": -1]))
        XCTAssertNil(MLXTokenizerAnalyzer.contextWindow(fromConfig: [:]))
        // sliding_window is an attention span, not a context length — must be ignored.
        XCTAssertNil(MLXTokenizerAnalyzer.contextWindow(fromConfig: ["sliding_window": 4_096]))
    }
}

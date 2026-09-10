// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  VectorMathSafetyTests.swift
//  DevgenticTests
//
//  TDD: RAG Tier 1 — VectorMath Defensive Safety (R1 + R2)
//
//  R1: dotProduct silently returns 0.0 on dimension mismatch → should return nil or signal error
//  R2: l2Normalize returns zero vector unchanged → violates HNSW unit-vector contract
//

import XCTest
@testable import devgentic

final class VectorMathSafetyTests: XCTestCase {

    private let tolerance: Float = 1e-6

    // MARK: - R1: Dimension Mismatch Safety

    /// dotProduct currently returns 0.0 for mismatched vectors — identical to
    /// the value for orthogonal same-dimension vectors. This masks bugs where
    /// a 384-dim embedding is accidentally compared with a 768-dim embedding.
    /// After the fix, dotProduct should return nil for mismatched dimensions.
    func testDotProduct_DimensionMismatch_ReturnsNil() {
        let result = VectorMath.safeDotProduct([1, 2, 3], [4, 5])
        XCTAssertNil(result, "Dimension mismatch should return nil, not a silent 0.0")
    }

    func testDotProduct_DimensionMatch_ReturnsValue() {
        let result = VectorMath.safeDotProduct([1, 2, 3], [4, 5, 6])
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 32.0, accuracy: tolerance)
    }

    func testDotProduct_BothEmpty_ReturnsZero() {
        let result = VectorMath.safeDotProduct([], [])
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 0.0, accuracy: tolerance)
    }

    /// cosineSimilarity delegates to dotProduct — should also signal dimension errors
    func testCosineSimilarity_DimensionMismatch_ReturnsNil() {
        let result = VectorMath.safeCosineSimilarity(between: [1, 0, 0], and: [0, 1])
        XCTAssertNil(result, "Mismatched vector dimensions should return nil")
    }

    func testCosineSimilarity_DimensionMatch_ReturnsValue() {
        let result = VectorMath.safeCosineSimilarity(between: [1, 0], and: [0, 1])
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 0.0, accuracy: tolerance, "Orthogonal vectors → 0")
    }

    func testCosineSimilarity_384vs768_ReturnsNil() {
        // Real-world bug scenario: mixing model output dimensions
        let vec384 = [Float](repeating: 0.01, count: 384)
        let vec768 = [Float](repeating: 0.01, count: 768)
        let result = VectorMath.safeCosineSimilarity(between: vec384, and: vec768)
        XCTAssertNil(result, "384 vs 768 dimension mismatch must be caught")
    }

    // MARK: - R2: Zero-Vector L2 Normalization Safety

    /// l2Normalize currently returns [0,0,0] unchanged for zero vectors.
    /// HNSW cosine distance assumes unit vectors (magnitude=1). A zero vector
    /// breaks this contract and corrupts the graph.
    /// After the fix, l2Normalize should return nil for zero vectors.
    func testL2Normalize_ZeroVector_ReturnsNil() {
        let result = VectorMath.safeL2Normalize([0, 0, 0])
        XCTAssertNil(result, "Zero vector cannot be L2-normalized — should return nil, not [0,0,0]")
    }

    func testL2Normalize_NonZeroVector_ReturnsNormalized() {
        let result = VectorMath.safeL2Normalize([3, 4])
        XCTAssertNotNil(result)
        XCTAssertEqual(result![0], 0.6, accuracy: tolerance)
        XCTAssertEqual(result![1], 0.8, accuracy: tolerance)
    }

    func testL2Normalize_AlreadyUnit_ReturnsUnchanged() {
        let result = VectorMath.safeL2Normalize([1, 0, 0])
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, [1, 0, 0])
    }

    func testL2Normalize_EmptyVector_ReturnsNil() {
        let result = VectorMath.safeL2Normalize([])
        XCTAssertNil(result, "Empty vector cannot be normalized")
    }

    func testL2Normalize_NearZeroVector_ReturnsNormalized() {
        // Very small but non-zero — should still normalize
        let result = VectorMath.safeL2Normalize([1e-10, 1e-10])
        XCTAssertNotNil(result, "Near-zero but non-zero vector should normalize")
        if let normalized = result {
            let mag = VectorMath.magnitude(of: normalized)
            XCTAssertEqual(mag, 1.0, accuracy: 1e-4)
        }
    }

    func testL2Normalize_384D_ZeroVector_ReturnsNil() {
        let zeroVec = [Float](repeating: 0, count: 384)
        let result = VectorMath.safeL2Normalize(zeroVec)
        XCTAssertNil(result, "384-dim zero vector should not be stored in HNSW")
    }

    // MARK: - Integration: Safe methods used together

    func testSafePipeline_NormalizeAndCompare() {
        guard let a = VectorMath.safeL2Normalize([1, 2, 3]),
              let b = VectorMath.safeL2Normalize([1, 2, 3]),
              let sim = VectorMath.safeCosineSimilarity(between: a, and: b) else {
            XCTFail("Safe pipeline should succeed for valid inputs")
            return
        }
        XCTAssertEqual(sim, 1.0, accuracy: tolerance, "Identical normalized vectors → similarity 1.0")
    }

    func testSafePipeline_ZeroVectorBlocked_BeforeComparison() {
        let result = VectorMath.safeL2Normalize([0, 0, 0])
        XCTAssertNil(result, "Zero vector should be blocked before it reaches HNSW")
    }
}

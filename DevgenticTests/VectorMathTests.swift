//
//  VectorMathTests.swift
//  devgenticTests
//
//  Created by Raj Singh on 02/03/26.
//

import XCTest
@testable import devgentic

final class VectorMathTests: XCTestCase {

    private let tolerance: Float = 1e-6

    // MARK: - Dot Product

    func testDotProduct_KnownVectors() {
        // [1,2,3] · [4,5,6] = 1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32
        let result = VectorMath.dotProduct([1, 2, 3], [4, 5, 6])
        XCTAssertEqual(result, 32.0, accuracy: tolerance)
    }

    func testDotProduct_OrthogonalVectors() {
        let result = VectorMath.dotProduct([1, 0], [0, 1])
        XCTAssertEqual(result, 0.0, accuracy: tolerance)
    }

    func testDotProduct_ParallelVectors() {
        // [2,3] · [2,3] = 4 + 9 = 13
        let result = VectorMath.dotProduct([2, 3], [2, 3])
        XCTAssertEqual(result, 13.0, accuracy: tolerance)
    }

    func testDotProduct_NegativeComponents() {
        // [-1,2] · [3,-4] = -3 + (-8) = -11
        let result = VectorMath.dotProduct([-1, 2], [3, -4])
        XCTAssertEqual(result, -11.0, accuracy: tolerance)
    }

    func testDotProduct_DifferentLengths_ReturnsZero() {
        let result = VectorMath.dotProduct([1, 2], [1, 2, 3])
        XCTAssertEqual(result, 0.0, accuracy: tolerance)
    }

    func testDotProduct_EmptyVectors() {
        let result = VectorMath.dotProduct([], [])
        XCTAssertEqual(result, 0.0, accuracy: tolerance)
    }

    func testDotProduct_ZeroVectors() {
        let result = VectorMath.dotProduct([0, 0, 0], [1, 2, 3])
        XCTAssertEqual(result, 0.0, accuracy: tolerance)
    }

    // MARK: - Magnitude

    func testMagnitude_KnownVector_3_4_5_Triangle() {
        // sqrt(9 + 16) = sqrt(25) = 5
        let result = VectorMath.magnitude(of: [3, 4])
        XCTAssertEqual(result, 5.0, accuracy: tolerance)
    }

    func testMagnitude_UnitVector() {
        let result = VectorMath.magnitude(of: [1, 0, 0])
        XCTAssertEqual(result, 1.0, accuracy: tolerance)
    }

    func testMagnitude_ZeroVector() {
        let result = VectorMath.magnitude(of: [0, 0, 0])
        XCTAssertEqual(result, 0.0, accuracy: tolerance)
    }

    func testMagnitude_NegativeComponents() {
        // sqrt(9 + 16) = 5 regardless of sign
        let result = VectorMath.magnitude(of: [-3, 4])
        XCTAssertEqual(result, 5.0, accuracy: tolerance)
    }

    func testMagnitude_SingleElement() {
        let result = VectorMath.magnitude(of: [7])
        XCTAssertEqual(result, 7.0, accuracy: tolerance)
    }

    func testMagnitude_EmptyVector() {
        let result = VectorMath.magnitude(of: [])
        XCTAssertEqual(result, 0.0, accuracy: tolerance)
    }

    // MARK: - Cosine Similarity

    func testCosineSimilarity_IdenticalVectors() {
        let result = VectorMath.cosineSimilarity(between: [1, 2, 3], and: [1, 2, 3])
        XCTAssertEqual(result, 1.0, accuracy: tolerance)
    }

    func testCosineSimilarity_OppositeVectors() {
        let result = VectorMath.cosineSimilarity(between: [1, 0], and: [-1, 0])
        XCTAssertEqual(result, -1.0, accuracy: tolerance)
    }

    func testCosineSimilarity_OrthogonalVectors() {
        let result = VectorMath.cosineSimilarity(between: [1, 0], and: [0, 1])
        XCTAssertEqual(result, 0.0, accuracy: tolerance)
    }

    func testCosineSimilarity_ScaledVectors_SameDirection() {
        // [1,2] and [2,4] are parallel → similarity = 1.0
        let result = VectorMath.cosineSimilarity(between: [1, 2], and: [2, 4])
        XCTAssertEqual(result, 1.0, accuracy: tolerance)
    }

    func testCosineSimilarity_KnownAngle_45Degrees() {
        // [1,0] vs [1,1]: cos(45°) = 1/sqrt(2) ≈ 0.7071
        let result = VectorMath.cosineSimilarity(between: [1, 0], and: [1, 1])
        XCTAssertEqual(result, 1.0 / sqrt(2.0), accuracy: tolerance)
    }

    func testCosineSimilarity_ZeroVectorA_ReturnsZero() {
        let result = VectorMath.cosineSimilarity(between: [0, 0], and: [1, 2])
        XCTAssertEqual(result, 0.0, accuracy: tolerance)
    }

    func testCosineSimilarity_ZeroVectorB_ReturnsZero() {
        let result = VectorMath.cosineSimilarity(between: [1, 2], and: [0, 0])
        XCTAssertEqual(result, 0.0, accuracy: tolerance)
    }

    func testCosineSimilarity_BothZeroVectors_ReturnsZero() {
        let result = VectorMath.cosineSimilarity(between: [0, 0], and: [0, 0])
        XCTAssertEqual(result, 0.0, accuracy: tolerance)
    }

    // MARK: - L2 Normalization

    func testL2Normalize_KnownVector() {
        // [3,4] → magnitude 5 → [0.6, 0.8]
        let result = VectorMath.l2Normalize([3, 4])
        XCTAssertEqual(result[0], 0.6, accuracy: tolerance)
        XCTAssertEqual(result[1], 0.8, accuracy: tolerance)
    }

    func testL2Normalize_AlreadyNormalized() {
        let result = VectorMath.l2Normalize([1, 0, 0])
        XCTAssertEqual(result, [1, 0, 0])
    }

    func testL2Normalize_ZeroVector_ReturnsUnmodified() {
        let result = VectorMath.l2Normalize([0, 0, 0])
        XCTAssertEqual(result, [0, 0, 0])
    }

    func testL2Normalize_NegativeComponents() {
        // [-3,4] → magnitude 5 → [-0.6, 0.8]
        let result = VectorMath.l2Normalize([-3, 4])
        XCTAssertEqual(result[0], -0.6, accuracy: tolerance)
        XCTAssertEqual(result[1], 0.8, accuracy: tolerance)
    }

    func testL2Normalize_MagnitudeBecomesOne() {
        let vector: [Float] = [2, 3, 6]
        let normalized = VectorMath.l2Normalize(vector)
        let magnitude = VectorMath.magnitude(of: normalized)
        XCTAssertEqual(magnitude, 1.0, accuracy: tolerance)
    }

    func testL2Normalize_HighDimensional_384D() {
        // Create a 384-element vector (the embedding dimension of All-MiniLM-L6-v2)
        var vector = (0..<384).map { Float($0) * 0.01 }
        vector[0] = 1.0 // Ensure non-zero

        let normalized = VectorMath.l2Normalize(vector)
        let magnitude = VectorMath.magnitude(of: normalized)

        XCTAssertEqual(normalized.count, 384)
        XCTAssertEqual(magnitude, 1.0, accuracy: 1e-4)
    }

    // MARK: - Retrieval Simulation

    func testSimilarityRanking_RelatedVsUnrelated() {
        // Simulate query and candidates with synthetic vectors
        let query: [Float] = [1.0, 0.5, 0.3, 0.0]
        let related: [Float] = [0.9, 0.6, 0.2, 0.1]   // Close to query
        let orthogonal: [Float] = [0.0, 0.0, 0.0, 1.0] // Perpendicular
        let opposite: [Float] = [-1.0, -0.5, -0.3, 0.0] // Opposite direction

        let scoreRelated = VectorMath.cosineSimilarity(between: query, and: related)
        let scoreOrthogonal = VectorMath.cosineSimilarity(between: query, and: orthogonal)
        let scoreOpposite = VectorMath.cosineSimilarity(between: query, and: opposite)

        XCTAssertGreaterThan(scoreRelated, scoreOrthogonal,
                             "Related vector should rank higher than orthogonal")
        XCTAssertGreaterThan(scoreOrthogonal, scoreOpposite,
                             "Orthogonal vector should rank higher than opposite")
        XCTAssertGreaterThan(scoreRelated, 0.9,
                             "Related vector should have very high similarity")
        XCTAssertLessThan(scoreOpposite, 0,
                          "Opposite vector should have negative similarity")
    }

    func testSimilarityThreshold_FiltersBelowMinimum() {
        let threshold: Float = 0.3

        let query: [Float] = [1, 0, 0]
        let highSim: [Float] = [0.9, 0.1, 0.0]  // Close to query
        let lowSim: [Float] = [0.1, 0.9, 0.3]   // Mostly perpendicular
        let veryLow: [Float] = [0, 1, 0]          // Orthogonal

        let scores = [
            ("high", VectorMath.cosineSimilarity(between: query, and: highSim)),
            ("low", VectorMath.cosineSimilarity(between: query, and: lowSim)),
            ("veryLow", VectorMath.cosineSimilarity(between: query, and: veryLow))
        ]

        let qualified = scores.filter { $0.1 >= threshold }
        let disqualified = scores.filter { $0.1 < threshold }

        XCTAssertFalse(qualified.isEmpty, "At least one vector should pass the 0.3 threshold")
        XCTAssertFalse(disqualified.isEmpty, "At least one vector should fail the 0.3 threshold")

        // The orthogonal vector (cosine = 0) should definitely be filtered out
        XCTAssertTrue(disqualified.contains(where: { $0.0 == "veryLow" }),
                      "Orthogonal vector should be below threshold")
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  VectorMath.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import Accelerate

/// A namespace for pure vector math used across the RAG pipeline.
/// Provides cosine similarity, dot product, magnitude and L2 normalization for nearest-neighbor search.
enum VectorMath {

    /// Calculates the dot product of two vectors.
    /// - Returns: The scalar dot product, or `0` if vectors have different lengths.
    static func dotProduct(_ vectorA: [Float], _ vectorB: [Float]) -> Float {
        guard vectorA.count == vectorB.count else { return 0.0 }
        // vDSP, not `zip(...).map(*).reduce(+)`, which allocates an intermediate array per call;
        // the retrieval scan calls this once per chunk on every send.
        var result: Float = 0
        vDSP_dotpr(vectorA, 1, vectorB, 1, &result, vDSP_Length(vectorA.count))
        return result
    }

    /// Calculates the L2 magnitude (Euclidean norm) of a vector.
    /// - Returns: `sqrt(sum(x_i^2))`, or `0` for an empty/zero vector.
    static func magnitude(of vector: [Float]) -> Float {
        return sqrt(vector.map { $0 * $0 }.reduce(0, +))
    }

    /// Calculates the cosine similarity between two vectors.
    /// - Returns: A value between `-1` (opposite) and `1` (identical direction).
    ///   Returns `0` if either vector has zero magnitude.
    static func cosineSimilarity(between vectorA: [Float], and vectorB: [Float]) -> Float {
        let dot = dotProduct(vectorA, vectorB)
        let magA = magnitude(of: vectorA)
        let magB = magnitude(of: vectorB)
        guard magA > 0, magB > 0 else { return 0.0 }
        return dot / (magA * magB)
    }

    /// L2-normalizes a vector to unit length (magnitude = 1).
    /// - Returns: The normalized vector. Returns the original vector unmodified if its norm is `0`.
    static func l2Normalize(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    // MARK: - Safe Variants (Dimension & Zero-Vector Validation)

    /// Safe dot product that returns `nil` on dimension mismatch instead of a silent `0.0`.
    /// Use this at pipeline boundaries (e.g., comparing embeddings from different models).
    static func safeDotProduct(_ vectorA: [Float], _ vectorB: [Float]) -> Float? {
        guard vectorA.count == vectorB.count else { return nil }
        return zip(vectorA, vectorB).map(*).reduce(0, +)
    }

    /// Safe cosine similarity that returns `nil` on dimension mismatch or zero-magnitude vectors.
    static func safeCosineSimilarity(between vectorA: [Float], and vectorB: [Float]) -> Float? {
        guard vectorA.count == vectorB.count else { return nil }
        let dot = dotProduct(vectorA, vectorB)
        let magA = magnitude(of: vectorA)
        let magB = magnitude(of: vectorB)
        guard magA > 0, magB > 0 else { return 0.0 }
        return dot / (magA * magB)
    }

    /// Safe L2 normalization that returns `nil` for zero or empty vectors.
    /// HNSW cosine distance requires unit vectors — storing a zero vector corrupts the graph.
    static func safeL2Normalize(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty else { return nil }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return vector.map { $0 / norm }
    }
}

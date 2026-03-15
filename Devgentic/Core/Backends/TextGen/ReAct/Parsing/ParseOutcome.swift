//
//  ParseOutcome.swift
//  Devgentic
//
//  The confidence-signal enum used internally by CognitiveParsePipeline
//  to decide whether fallback stages should fire.
//
//  Created by Raj Singh on 10/03/26.
//

import Foundation

// MARK: - Parse Outcome

/// The result of a parse pipeline stage, carrying both the parsed step
/// and a confidence signal that determines whether fallback stages fire.
/// Internal to the pipeline — external callers always receive a `ModernCognitiveStep`.
enum ParseOutcome: Sendable {

    /// Parser handled the response with high confidence.
    case confident(ModernCognitiveStep)

    /// Parsed something, but tool extraction likely incomplete.
    /// The pipeline will attempt drift detection and fallback parsing.
    case degraded(ModernCognitiveStep)

    /// Could not extract any meaningful structure.
    case failed

    /// Extracts the `ModernCognitiveStep` regardless of confidence tier.
    var step: ModernCognitiveStep? {
        switch self {
        case .confident(let s), .degraded(let s): return s
        case .failed: return nil
        }
    }

    var isConfident: Bool {
        if case .confident = self { return true }
        return false
    }
}

// MARK: - Parse Route (Telemetry)

/// Metadata about how a parse result was achieved — used for observability only.
struct ParseRoute: Sendable {
    /// Which pipeline stage produced the result ("primary", "drift-fallback", "heuristic").
    let stage: String
    /// The concrete parser class that produced the result.
    let parserUsed: String
    /// Whether drift detection fired.
    let driftDetected: Bool
    /// The detected drift format, if any.
    let detectedFormat: String?
}

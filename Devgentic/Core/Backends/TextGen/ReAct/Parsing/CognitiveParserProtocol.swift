// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CognitiveParserProtocol.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The single contract every concrete parser must satisfy.
/// Parsers are stateless value types — safe to instantiate per-call.
protocol CognitiveParserProtocol {

    /// Converts a raw LLM text response into a structured cognitive step.
    /// Never throws — malformed input degrades gracefully to a no-tool step.
    ///
    /// - Parameter rawResponse: The unmodified text string returned by the model.
    /// - Returns: A `ModernCognitiveStep` with zero or more pending tool calls.
    func parse(rawResponse: String) -> ModernCognitiveStep
}

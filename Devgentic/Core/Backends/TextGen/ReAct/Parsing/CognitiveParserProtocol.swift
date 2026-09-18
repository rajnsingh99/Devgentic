// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CognitiveParserProtocol.swift
//  Devgentic
//
//  Step 3: Protocol contract for dialect-specific response parsers.
//  Each concrete parser handles one ModelDialect and converts raw LLM text
//  into a fully-structured ModernCognitiveStep.
//
//  Created by Raj Singh on 06/03/26.
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

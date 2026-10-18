// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LongTermMemoryStrategy.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Defines how pre-fetched long-term grounding is exposed to the prompt.
protocol LongTermMemoryStrategy: Sendable {
    /// The pre-fetched static facts injected into the prompt (RAG output, or empty).
    func getStaticGrounding() -> String
}

// MARK: - Concrete Implementations

/// Grounding is pre-fetched and injected; the agent has no tool with which to query history
/// itself. This is the only strategy — every model tier uses it.
struct StaticGroundingMemory: LongTermMemoryStrategy {
    let ragContext: String

    func getStaticGrounding() -> String { return ragContext }
}

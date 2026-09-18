// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LongTermMemoryStrategy.swift
//  Devgentic
//
//  Created by Raj Singh on 11/03/26.
//
//  How pre-fetched long-term grounding reaches the prompt.
//
//  This file used to expose a second axis — "deep memory TOOLS" the model could call to search
//  history itself — via a `memoryCapabilities` protocol member and a `ToolAugmentedMemory`
//  strategy that carried them for capable models. Both were removed 2026-07-31 along with the
//  only tool that ever populated them, `read_session_history`, which could not do what it
//  advertised: it promised "raw logs for COMPLETED tasks" but the session graph has no
//  tool-output field (results are deliberately never retained) and its `logs` array was never
//  written by either construction site.
//
//  What was left behind is the thing worth naming: a protocol member that every implementation
//  answered with `[]`, appended to the tool list by a caller that could only ever append nothing.
//  Machinery that reads as working and does nothing is worse than its absence — it is why
//  `LocalToolManager.execute` and `ScratchpadTool` were deleted in the same pass. Re-adding a
//  capabilities axis when a deep-memory tool actually exists is a few lines; keeping an empty
//  hook alive costs a reader every time they trace it.
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

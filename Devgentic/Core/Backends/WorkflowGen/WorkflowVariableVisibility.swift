// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowVariableVisibility.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// Why: do not serialise the level, share state or auto-insert edges: that trades determinism for completion-order races
/// When a variable written by a Code node becomes visible to a node that reads it. A same-level write is never visible:
/// each node in a level gets one pre-level `WorkflowState` snapshot, and updates fold back only after the level finishes.
enum WorkflowVariableVisibility: Equatable {
    /// No Code node on this canvas writes the variable at all.
    case neverWritten
    /// Some writer runs on a strictly earlier level, so the reader can see it.
    case visible(fromLevel: Int)
    /// Every writer runs on the reader's own level or later, so the read resolves to nothing —
    /// every run, deterministically.
    case writtenTooLate(earliestWriterLevel: Int)

    /// Whether a read at `readerLevel` can ever observe a write from `writerLevels`; strictly earlier (`<`), not `<=`.
    /// A cyclic layout (callers pass -1) reports `.writtenTooLate`; inert, since cycles are refused earlier.
    nonisolated static func resolve(readerLevel: Int, writerLevels: [Int]) -> Self {
        guard let earliest = writerLevels.min() else { return .neverWritten }
        return earliest < readerLevel
            ? .visible(fromLevel: earliest)
            : .writtenTooLate(earliestWriterLevel: earliest)
    }
}

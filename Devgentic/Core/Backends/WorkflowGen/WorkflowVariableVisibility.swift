// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  WorkflowVariableVisibility.swift
//  Devgentic
//
//  WHEN a workflow variable written by a Code node becomes visible to a node that reads it.
//  Register EXA-5.
//
//  ⚠️ THIS IS A SCHEDULING FACT, NOT A RACE — and the register row, which called it one, was wrong
//  in the direction that matters. Levels run strictly in sequence, but every node WITHIN a level is
//  handed ONE `WorkflowState` snapshot taken before any of them starts
//  (`WorkflowExecutor`: `let snapshotState = state`), and each node's `variableUpdates` are folded
//  back into the live state only in the parent's serial drain AFTER the whole level has finished.
//  `WorkflowState` is a struct, so every concurrent node holds its own copy and a sibling's write
//  cannot reach it by any path.
//
//  The consequence is stronger than "sometimes races": a same-level write is NEVER visible, on every
//  run, deterministically. That is why the treatment is a design-time WARNING and a runtime LOG
//  rather than a scheduler change — there is nothing flaky to stabilise, only something invisible to
//  make visible.
//
//  ⚠️ WHAT MUST NOT BE DONE ABOUT IT, recorded because each option looks reasonable in isolation:
//    • Do NOT serialise the level or re-snapshot per node. It destroys the parallelism levelling
//      exists for, and it REPLACES today's determinism with genuine nondeterminism — the reader's
//      value would become a function of task completion order, which is exactly the failure the
//      writer/writer validation rule already calls out.
//    • Do NOT move `variables` to a shared actor, for the same reason.
//    • Do NOT auto-insert an ordering edge from writer to reader. That mutates the user's DAG behind
//      their back and can create a cycle, turning a warning into a refused run.
//  `WorkflowStructuralLaneStateIsolationTests` locks the current semantics deliberately; a "fix"
//  that requires deleting that guard is the wrong fix.
//

import Foundation

enum WorkflowVariableVisibility: Equatable {
    /// No Code node on this canvas writes the variable at all.
    case neverWritten
    /// Some writer runs on a strictly earlier level, so the reader can see it.
    case visible(fromLevel: Int)
    /// Every writer runs on the reader's own level or later, so the read resolves to nothing —
    /// every run, deterministically.
    case writtenTooLate(earliestWriterLevel: Int)

    /// Whether a read at `readerLevel` can ever observe a write from `writerLevels`.
    ///
    /// ⚠️ STRICTLY earlier (`<`), not `<=`. Same-level is the whole defect.
    ///
    /// A cyclic layout falls out correctly without a special case: `computeExecutionLevels()`
    /// returns nil, callers substitute the -1 sentinel for every node, so `earliest < readerLevel`
    /// is false and this reports `.writtenTooLate`. Inert in practice — a cycle is refused at
    /// pre-flight before any of this is consulted.
    nonisolated static func resolve(readerLevel: Int, writerLevels: [Int]) -> Self {
        guard let earliest = writerLevels.min() else { return .neverWritten }
        return earliest < readerLevel
            ? .visible(fromLevel: earliest)
            : .writtenTooLate(earliestWriterLevel: earliest)
    }
}

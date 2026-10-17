// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolRowMatcher.swift
//  Devgentic
//
//  Which executing timeline row a finished tool call belongs to.
//

import Foundation

/// Finds the executing `.toolExecution` row a tool result completes.
///
/// ⚠️⚠️ READINESS CR-41 (2026-10-12). Every completion site took the LAST executing row with the
/// tool's NAME. Autonomous calls run in parallel, so two same-name calls (two `read_file`s) finish
/// in either order: A's output landed on B's row, B's result then found no executing row and
/// vanished, and a stale row could show both succeeded and cancelled.
///
/// A row is matched by name AND params: identical calls are de-duplicated before they run, so
/// within one step the params pick out exactly one row. Where a run changes a call's params
/// between its row and its result (a banner edit), the output carries the row's params as
/// `ToolOutput.rowParams`. There is deliberately NO name-only fallback: a result whose row was
/// never created (a call refused before it started) would otherwise complete the one OTHER
/// same-name row still running.
enum ToolRowMatcher {

    static func index(in events: [TimelineEvent], toolName: String, params: String) -> Int? {
        events.lastIndex {
            guard case .toolExecution(let data) = $0 else { return false }
            return data.isExecuting && data.name == toolName && data.params == params
        }
    }

    static func index(in events: [TimelineEvent], for output: ToolOutput) -> Int? {
        index(in: events, toolName: output.toolName, params: output.matchingParams)
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolRowMatcher.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// Why: no name-only fallback: a result whose row was never created would complete another same-name row still running,
// and parallel same-name calls finish in either order.
/// Finds the executing `.toolExecution` row a tool result completes.
/// A row is matched by name AND params: identical calls are de-duplicated before they run, so params pick out one row.
/// If params change between row and result (a banner edit), the output carries them as `ToolOutput.rowParams`.
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

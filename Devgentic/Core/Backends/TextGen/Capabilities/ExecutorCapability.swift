// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ExecutorCapability.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// A composable decorator that wraps an Executor with additional behavior.
/// Capabilities stack cleanly: `Reflection( Planning( ReAct ) )`
protocol ExecutorCapability: Sendable {
    /// Wraps the given executor with this capability's behavior.
    func wrap(_ executor: any Executor) -> any Executor
}

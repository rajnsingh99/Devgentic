//
//  ExecutorCapability.swift
//  Devgentic
//
//  Protocol for composable executor capabilities (Planning, Self-Reflection, Delegation).
//  Each capability wraps an inner executor, adding behavior before/after execution.
//

import Foundation

/// A composable decorator that wraps an Executor with additional behavior.
/// Capabilities stack cleanly: `Reflection( Planning( ReAct ) )`
protocol ExecutorCapability: Sendable {
    /// Wraps the given executor with this capability's behavior.
    func wrap(_ executor: any Executor) -> any Executor
}

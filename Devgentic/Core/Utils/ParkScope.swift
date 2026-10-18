// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ParkScope.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// Why: the chain is inherited by `Task { }` created inside it, NOT by `Task.detached`; credited work must be created
// inside `withScope` (or `bind`), not merely awaited there.
/// The chain of time bounds the current task runs inside (run, turn, node, tool call), carried as a TaskLocal
/// so a HITL park pauses only the clocks of the task that raised it. A park raised outside any chain (e.g. an MCP
/// elicitation on the transport's own task) falls back to every bound open in its conversation.
enum ParkScope {

    @TaskLocal static var chain: [UUID] = []

    /// Runs `operation` inside a new bound `id`, registered so an out-of-chain park in the same
    /// conversation can still credit it, and unregistered afterwards.
    static func withScope<T: Sendable>(
        _ id: UUID,
        conversationID: UUID,
        operation: () async throws -> T
    ) async rethrows -> T {
        await ExecutionSuspensionService.shared.registerScope(id, conversationID: conversationID)
        do {
            let value = try await $chain.withValue(chain + [id]) { try await operation() }
            await ExecutionSuspensionService.shared.unregisterScope(id)
            return value
        } catch {
            await ExecutionSuspensionService.shared.unregisterScope(id)
            throw error
        }
    }

    /// Synchronous binding for work that is CREATED here and runs elsewhere — a stream whose
    /// producer task is spawned inside `operation`. The caller owns `register`/`unregister`.
    static func bind<T>(_ id: UUID, _ operation: () throws -> T) rethrows -> T {
        try $chain.withValue(chain + [id]) { try operation() }
    }
}

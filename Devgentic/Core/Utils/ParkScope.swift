// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ParkScope.swift
//  Devgentic
//
//  Owner-chain park credit (HITL Waiting Contract §6.2, decision A).
//

import Foundation

/// The chain of TIME BOUNDS the current task is running inside — a run, a turn, a node, a tool
/// call — carried as a TaskLocal so a HITL park knows exactly whose clocks it pauses.
///
/// ⚠️⚠️ WHY. Park credit used to be keyed by CONVERSATION: any open banner anywhere in the
/// conversation paused every clock in it. A hung node beside an unanswered gate, a run next to an
/// earlier run's banner, a turn during an MCP question — all of them stopped timing out for as long
/// as the unrelated banner stayed open (Timeout inventory D-18). A park now pauses only the bounds
/// in the chain of the task that raised it.
///
/// A park is attributed by reading this TaskLocal inside `ExecutionSuspensionService` — an actor
/// call runs on the CALLER's task, the same mechanism `WorkflowRunScope.token` already relies on.
/// A park raised OUTSIDE any chain (an MCP elicitation or sampling request arrives on the MCP
/// transport's own task, not the tool call's) falls back to every bound currently open in its
/// conversation — the one case where the owner cannot be known, credited the old way.
///
/// ⚠️ The chain is inherited by `Task { }` created inside it, NOT by `Task.detached`. Work that must
/// be credited — a tool's run, an executor's stream task — has to be CREATED inside `withScope`
/// (or `bind`), not merely awaited there.
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

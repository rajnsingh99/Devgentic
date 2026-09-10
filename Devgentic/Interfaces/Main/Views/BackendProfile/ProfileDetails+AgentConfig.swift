// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ProfileDetails+AgentConfig.swift
//  Devgentic
//
//  Created on 09/08/26.
//
//  THE accessor for "does this profile carry an `AgentConfig`, and which one?" — register B44.
//
//  ⚠️ WHY THIS EXISTS. `.code` reuses `AgentConfig` exactly as `.agent` does, and five separate
//  sites in `AgentConnect` unpacked it with `if case .agent(let c) = profile.details { … } else {
//  <defaults> }`. `.code` fell into every one of those `else` arms, so a Code session ran with
//  fabricated defaults in place of the values `CodeSessionManager` had just configured — silently,
//  because an `else` arm has nothing to log.
//
//  This is the THIRD time the module has recorded this exact trap:
//    • register A7  — `executionTimeout` dropped for `.code`, so Code runs had no wall-clock bound.
//      Fixed with an exhaustive `switch` at the one site the row named.
//    • `Executor.swift` — carries a standing comment about `.code` falling through for
//      `maxIterations`.
//    • register B44 — the resilience triple, the history strategy and the capabilities, at four
//      more sites, one of them 85 lines below A7's own fix and in the same function.
//
//  A per-site `switch` is why the trap survived twice: it fixes the site, not the class. This
//  extension is the single exhaustive match, so a case added to `ProfileDetails` later is a compile
//  error here and nowhere else, and no call site has to remember that `.code` is agent-shaped.
//
//  ⚠️ Every accessor below MUST derive from `agentConfig`. Re-deriving one with its own `if case`
//  re-creates the defect this file exists to close.
//

import Foundation

extension ProfileDetails {

    /// The `AgentConfig` this profile carries, or nil for profile types that have none.
    ///
    /// ⚠️ **`.code` is included deliberately** — it is documented as "Code mode reuses AgentConfig
    /// internally", and every consumer of an agent setting must treat it as an agent. The
    /// exhaustive `switch` (rather than `if case`) is the load-bearing part: it is what makes a
    /// sixth `ProfileDetails` case fail to compile instead of silently inheriting the nil arm.
    var agentConfig: AgentConfig? {
        switch self {
        case .agent(let config), .code(let config):
            return config
        case .bot, .workflow, .imageGen:
            return nil
        }
    }

    /// Wall-clock bound for a run, or nil when the profile type has none.
    ///
    /// ⚠️ Register A7 fixed this inline at its one call site; register B37 then observed that the
    /// test suite had grown a private copy of that same switch, so reverting the production one
    /// left every test green. Deriving it here gives both a single definition to point at.
    var executionTimeout: TimeInterval? {
        agentConfig?.executionTimeout
    }

    /// Retry policy, falling back to the type's default when unset.
    ///
    /// ⚠️ The fallback is for an *unset* field on a profile that HAS an `AgentConfig`. It is not a
    /// stand-in for "this profile type has no resilience config" — that distinction is what the
    /// old `else` arm erased.
    var retryPolicy: RetryPolicy {
        agentConfig?.retryPolicy ?? RetryPolicy()
    }

    /// Error-recovery policy, falling back to the type's default when unset.
    ///
    /// ⚠️ The default `ErrorRecovery()` is `onToolFailure: .abort`, and `CodeSessionManager`
    /// configures `.fallbackPrompt`. That gap is the whole of B44's user-visible harm: every
    /// Code-mode tool failure aborted the run instead of recovering.
    var errorRecovery: ErrorRecovery {
        agentConfig?.errorRecovery ?? ErrorRecovery()
    }

    /// Loop-safety overrides, or nil when none are configured.
    var resilienceOverrides: ResilienceOverrides? {
        agentConfig?.resilienceOverrides
    }

    /// History strategy, falling back to `.recentHistory` when unset.
    var historyStrategy: HistoryStrategy {
        agentConfig?.historyStrategy ?? .recentHistory
    }

    /// Planning / reflection / delegation capabilities, or nil when the type has none.
    var agentCapabilities: AgentCapabilities? {
        agentConfig?.capabilities
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileDetails+AgentConfig.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The accessor for "does this profile carry an `AgentConfig`, and which one?". `.code` reuses `AgentConfig` as `.agent`
/// does, so consumers read it here instead of unpacking `.agent` themselves.
extension ProfileDetails {

    // Why: keep the switch exhaustive (not `if case`) so a new `ProfileDetails` case fails to compile instead of inheriting nil
    /// The `AgentConfig` this profile carries, or nil for profile types that have none; `.code` is included deliberately.
    var agentConfig: AgentConfig? {
        switch self {
        case .agent(let config), .code(let config):
            return config
        case .bot, .workflow, .imageGen:
            return nil
        }
    }

    /// Wall-clock bound for a run, or nil when the profile type has none.
    var executionTimeout: TimeInterval? {
        agentConfig?.executionTimeout
    }

    /// Retry policy, falling back to the type's default when unset.
    /// The fallback is for an unset field on a profile that has an `AgentConfig`, not for a type with no resilience config.
    var retryPolicy: RetryPolicy {
        agentConfig?.retryPolicy ?? RetryPolicy()
    }

    /// Error-recovery policy, falling back to the type's default when unset.
    /// The default `ErrorRecovery()` aborts on tool failure, while Code sessions configure `.fallbackPrompt`.
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

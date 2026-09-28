// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AgentExecutionDefaults.swift
//  Devgentic
//
//  Created on 08/08/26.
//
//  What an agent's execution limits fall back to when the profile leaves them on Auto.
//
//  ⚠️ Register A38. The iteration cap's default was a bare `15` written at four separate sites —
//  `Executor` twice, `ExecutionLimitsSection`'s "Auto" label, and `TraceConfigSnapshot` — and they
//  had already drifted: `BackendProfileService.logProfileSelection` printed `?? 20`. So the
//  configuration dump a support engineer reads stated a cap of 20 for a run the executor bounded at
//  15. A number that decides when a run stops must have exactly one definition.
//
//  Same shape as `ResolvedResiliencePolicy.autoDefault(legacy:)`, which fixed the identical class of
//  drift for the per-tier breaker caps (register A70).
//

import Foundation

enum AgentExecutionDefaults {

    /// Think-act-observe cycles allowed when the profile does not specify a cap.
    ///
    /// ⚠️ Changing this changes when runs terminate — it is not a display value. `ExecutionLimitsSection`
    /// renders it as the "Auto (N)" label, so the panel follows automatically.
    static let maxIterations = 15

    /// "No iteration cap" (2026-09-25, the Code interface's default).
    ///
    /// ⚠️ A real value, not `nil`: `nil` on `AgentConfig.maxIterations` already means "use
    /// `maxIterations` above", and three readers resolve it that way. `Int.max` needs no change in
    /// the executor — its loop is `while currentIteration < maxIterations` — and cannot be reached.
    /// Such a run is still stopped by the compute timeout, and by `CognitiveCircuitBreaker` only when
    /// the profile's `onToolFailure` is `.abort` — Code's `.fallbackPrompt` makes it warn (D-15).
    static let uncapped = Int.max

    /// For logs and traces: "no cap" rather than a 19-digit number.
    static func describe(_ maxIterations: Int?) -> String {
        guard let maxIterations else { return "\(Self.maxIterations) (default)" }
        return maxIterations == uncapped ? "no cap" : "\(maxIterations)"
    }
}

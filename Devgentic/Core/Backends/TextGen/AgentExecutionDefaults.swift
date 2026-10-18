// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AgentExecutionDefaults.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// What an agent's execution limits fall back to when the profile leaves them on Auto.
/// Each limit has a single definition here, shared by the executor, the settings panel and the trace snapshot.
enum AgentExecutionDefaults {

    /// Think-act-observe cycles allowed when the profile does not specify a cap.
    /// Changing it changes when runs terminate; `ExecutionLimitsSection` renders it as the "Auto (N)" label.
    static let maxIterations = 15

    /// "No iteration cap" (the Code interface's default): a real value rather than `nil`, which already means
    /// "use `maxIterations`". Such runs still stop on the compute timeout, and on `CognitiveCircuitBreaker` only when
    /// the profile's `onToolFailure` is `.abort`.
    static let uncapped = Int.max

    /// For logs and traces: "no cap" rather than a 19-digit number.
    static func describe(_ maxIterations: Int?) -> String {
        guard let maxIterations else { return "\(Self.maxIterations) (default)" }
        return maxIterations == uncapped ? "no cap" : "\(maxIterations)"
    }
}

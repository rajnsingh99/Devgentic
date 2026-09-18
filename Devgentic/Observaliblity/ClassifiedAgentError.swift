// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ClassifiedAgentError.swift
//  Devgentic
//
//  Renamed from AgentExecutionError to avoid a collision with the pre-existing
//  throwing error in AgentModel.swift (which wraps AgentFailureReason). This type
//  is the observability-carrier — every failure site classifies a raw Error into
//  a ClassifiedAgentError via `.classify(...)` before emitting telemetry.
//
//  Structured error wrapper that preserves the full diagnostic chain from where an
//  error is first caught through every handler that re-emits or propagates it.
//
//  Problem this solves:
//    Swift errors traveling through the agent pipeline get stringified ~20 times
//    (mostly `error.localizedDescription`), losing:
//      - NSError domain + code
//      - NSError.userInfo keys
//      - the original Error object (for `as?` re-classification later)
//      - the causal chain ("this timeout caused that abort which triggered this
//        synthesis-best-effort")
//    By the time analytics see it, we have a sanitized string and no way to tell
//    whether "File not found" was from our ReadFileTool guard or an underlying NSError.
//
//  Design:
//    - `ClassifiedAgentError` is THE carrier type. Every failure site catching a raw
//      Error classifies it with `.classify(as:phase:origin:)` and wraps it.
//    - Every re-emission in a higher layer reuses the original `chainID` so analytics
//      can collapse propagation duplicates via `GROUP BY error_chain_id`.
//    - `diagnostics` holds the forensic data: NSError domain/code, userInfo keys,
//      top-of-stack signature. Only populated when developer mode is on — keeps
//      production-mode memory overhead near zero.
//    - `underlying` preserves the original Error for callers that want to downcast
//      (e.g., `if case let cpe as CloudProviderError = agentErr.underlying`).
//

import Foundation

/// A classified, chainable error carrier used throughout the agent pipeline.
///
/// Every failure site should wrap its raw `Error` via `error.classify(...)` before
/// emitting a SpanEvent or rethrowing. Handlers higher in the stack that observe an
/// `ClassifiedAgentError` should reuse its `chainID` when emitting their own events,
/// letting analytics treat the full propagation as a single incident.
struct ClassifiedAgentError: Error, Sendable, CustomStringConvertible {

    /// Stable ID linking every event emitted about this underlying incident.
    /// Reused across layers — origin site generates it, propagation sites reuse.
    let chainID: UUID

    /// Canonical classification. Drives dashboards, severity tinting, retryability.
    let category: AgentErrorCategory

    /// Coarse phase where the error originated. Redundant with `category.phase` but
    /// cached so callers can filter without round-tripping through the category enum.
    let phase: ExecutionPhase

    /// Short identifier of the site that classified the error. Convention:
    ///   - semantic: `"ToolExecutionMediator.toolTimeout"` (preferred)
    ///   - fallback: `"\(#fileID):\(#line)"`
    /// Used by analytics to group errors by site, not just by category.
    let origin: String

    /// Human-readable summary. May be rendered in UI.
    let message: String

    /// The original Error. Preserved so higher-up handlers can do type-specific
    /// introspection (e.g., `as? CloudProviderError` to get `statusCode`).
    let underlying: (any Error)?

    /// Site-specific key-value context. Expected keys (non-exhaustive):
    /// `tool_name`, `iteration`, `trial`, `subtask_id`, `params_hash`, `model_name`,
    /// `provider`, `status_code`, `retry_count`.
    /// Values are short strings — JSON-stringify complex structures before insertion.
    let context: [String: String]

    /// When the error was classified.
    let timestamp: Date

    /// Whether the agent can reasonably retry. Usually copied from `category.isRetryable`
    /// but can be overridden at the call site (e.g., retry count exhausted).
    let isRecoverable: Bool

    /// Forensic details captured only when developer mode is on. Nil in production
    /// keeps memory overhead ~zero.
    let diagnostics: Diagnostics?

    // MARK: Diagnostics

    struct Diagnostics: Codable, Sendable {
        /// NSError.domain (only populated if underlying is an NSError).
        let errorDomain: String?

        /// NSError.code.
        let errorCode: Int?

        /// NSError.userInfo keys. Values NOT captured (may contain user data).
        /// Keys alone tell us what domain-specific context was available.
        let userInfoKeys: [String]?

        /// First ~5 frames of the current backtrace, symbolicated on a best-effort
        /// basis. Useful for identifying the call path when debugging crash-like flows.
        let stackSignature: String?
    }

    // MARK: CustomStringConvertible

    var description: String {
        "ClassifiedAgentError[\(category.rawValue) chain=\(chainID.uuidString.prefix(8)) origin=\(origin)]: \(message)"
    }

    // MARK: - Synthetic factory (no caught Error)

    /// Constructs a classified error from scratch — for origin sites that DETECT
    /// a failure condition without catching an actual `Error` (preflight permission
    /// checks, schema validation, circuit-breaker trip decisions, etc.).
    ///
    /// Use this when "we decided this is an error" rather than "we caught an error."
    /// For catch blocks, use `error.classify(...)` so the underlying Error + forensic
    /// diagnostics are preserved.
    static func synthetic(
        category: AgentErrorCategory,
        origin: String,
        message: String,
        context: [String: String] = [:],
        isRecoverable: Bool? = nil
    ) -> ClassifiedAgentError {
        ClassifiedAgentError(
            chainID: UUID(),
            category: category,
            phase: category.phase,
            origin: origin,
            message: message,
            underlying: nil,
            context: context,
            timestamp: Date(),
            isRecoverable: isRecoverable ?? category.isRetryable,
            diagnostics: nil
        )
    }
}

// MARK: - Error.classify(...)

/// Devgentic's canonical entry point for turning a raw Swift `Error` into a
/// classified `ClassifiedAgentError`. Called at every failure site before emitting
/// telemetry or rethrowing.
///
/// If the receiver is already an `ClassifiedAgentError`, this preserves the existing
/// `chainID` so the propagation path stays linked. Otherwise it starts a new chain.
extension Error {

    /// Wrap this error in an `ClassifiedAgentError` with the given classification.
    ///
    /// - Parameters:
    ///   - category: the canonical failure class
    ///   - origin: short identifier of the site catching the error (semantic or file:line)
    ///   - context: key-value metadata useful for triage. Values should be short.
    ///   - phase: override the phase (defaults to `category.phase`)
    ///   - message: override the message (defaults to a summary built from the underlying error)
    ///   - isRecoverable: override retryability (defaults to `category.isRetryable`)
    /// - Returns: a fully-classified `ClassifiedAgentError`. If `self` is already one,
    ///   its `chainID` is preserved; a new one is generated otherwise.
    func classify(
        as category: AgentErrorCategory,
        origin: String,
        context: [String: String] = [:],
        phase: ExecutionPhase? = nil,
        message: String? = nil,
        isRecoverable: Bool? = nil
    ) -> ClassifiedAgentError {

        // Preserve chain if we're re-wrapping an already-classified error.
        let chainID: UUID
        let underlying: (any Error)?
        let inheritedContext: [String: String]

        if let existing = self as? ClassifiedAgentError {
            chainID = existing.chainID
            underlying = existing.underlying ?? existing
            inheritedContext = existing.context
        } else {
            chainID = UUID()
            underlying = self
            inheritedContext = [:]
        }

        // Merge inherited context with new context. New keys win on collision.
        var mergedContext = inheritedContext
        for (k, v) in context { mergedContext[k] = v }

        let finalMessage = message ?? Self.defaultMessage(for: self)
        let diagnostics = Self.captureDiagnostics(for: underlying ?? self)

        return ClassifiedAgentError(
            chainID: chainID,
            category: category,
            phase: phase ?? category.phase,
            origin: origin,
            message: finalMessage,
            underlying: underlying,
            context: mergedContext,
            timestamp: Date(),
            isRecoverable: isRecoverable ?? category.isRetryable,
            diagnostics: diagnostics
        )
    }

    // MARK: - Helpers

    /// Best-effort short summary. Uses `ClassifiedAgentError.message` if already wrapped,
    /// otherwise `localizedDescription`.
    private static func defaultMessage(for error: any Error) -> String {
        if let agentErr = error as? ClassifiedAgentError {
            return agentErr.message
        }
        return error.localizedDescription
    }

    /// Captures forensic details when developer mode is on. Returns nil otherwise
    /// to minimize overhead on production builds.
    ///
    /// Gate is at `UserDefaults.standard.bool(forKey: AppSettings.developerModeKey)`.
    /// Reading UserDefaults per classification is cheap (cached in-memory by the system).
    private static func captureDiagnostics(for error: any Error) -> ClassifiedAgentError.Diagnostics? {
        guard UserDefaults.standard.bool(forKey: AppSettings.developerModeKey) else {
            return nil
        }

        let nsError = error as NSError
        let domain = nsError.domain.isEmpty ? nil : nsError.domain
        let code = nsError.code == 0 ? nil : nsError.code
        let userInfoKeys = nsError.userInfo.keys.isEmpty ? nil : Array(nsError.userInfo.keys)
        let stack = Self.topStackFrames(limit: 5)

        // All-nil → no meaningful diagnostics. Return nil so SpanEvent can skip the column.
        if domain == nil && code == nil && userInfoKeys == nil && stack == nil {
            return nil
        }

        return ClassifiedAgentError.Diagnostics(
            errorDomain: domain,
            errorCode: code,
            userInfoKeys: userInfoKeys,
            stackSignature: stack
        )
    }

    /// Captures a short backtrace for context. Symbols aren't mangled — this is a
    /// signature, not a full trace. Useful for spotting the call-path pattern, not
    /// for debugging individual frames.
    private static func topStackFrames(limit: Int) -> String? {
        let symbols = Thread.callStackSymbols.dropFirst(3).prefix(limit)  // drop this helper + classify + caller wrapper
        guard !symbols.isEmpty else { return nil }
        return symbols.joined(separator: "\n")
    }
}

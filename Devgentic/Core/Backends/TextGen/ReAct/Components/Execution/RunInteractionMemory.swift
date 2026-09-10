// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RunInteractionMemory.swift
//  Devgentic
//
//  [Loop Safety] Per-run memory of human interactions — the PREVENTION half of loop safety.
//  Created fresh for each executor run (same lifetime as the circuit breaker) and consulted
//  before raising HITL banners:
//
//    • Clarifications: an identical re-ask replays the user's earlier response instead of
//      re-raising the banner. The replayed observation is byte-identical to the original, so
//      a stuck ask-loop becomes deterministic and the repetition fingerprint's normal
//      warn → stop ladder governs it. Distinct questions always reach the user.
//    • Denied confirmations: an identical previously-denied request is auto-denied without a
//      banner; the consecutive-denial cap then ends persistent hammering quickly.
//
//  On a G1 resume the maps are re-primed from the reconstructed timeline (question/answer and
//  denial facts are all in the persisted observations), so prevention survives a park → resume.
//

import Foundation

actor RunInteractionMemory {

    /// Stored user response per normalized question. Inner `nil` = the user skipped —
    /// a skip is also replayed (the user declined to answer; don't ask again).
    private var answers: [String: String?] = [:]

    /// Canonical `tool|params` keys of requests the user denied this run.
    private var deniedRequests: Set<String> = []

    // MARK: - Clarifications

    func recordAnswer(question: String, response: String?) {
        // `updateValue` (not subscript assignment) so a skipped answer stores `.some(nil)`
        // instead of removing the key.
        answers.updateValue(response, forKey: Self.questionKey(question))
    }

    /// Double optional by design: outer `nil` = never asked; `.some(nil)` = asked, user skipped.
    func storedResponse(forQuestion question: String) -> String?? {
        answers[Self.questionKey(question)]
    }

    // MARK: - Denials

    func recordDenial(toolName: String, params: String) {
        deniedRequests.insert(Self.requestKey(toolName: toolName, params: params))
    }

    func isDenied(toolName: String, params: String) -> Bool {
        deniedRequests.contains(Self.requestKey(toolName: toolName, params: params))
    }

    // MARK: - Keys

    /// Whitespace-collapsed, case-folded question identity — wording must match, but
    /// incidental formatting must not defeat the replay.
    static func questionKey(_ question: String) -> String {
        question.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `params` is the canonical serialized argument JSON (sorted keys via
    /// `serializeToolParams`), so identical logical requests produce identical keys.
    static func requestKey(toolName: String, params: String) -> String {
        "\(toolName)|\(params)"
    }
}

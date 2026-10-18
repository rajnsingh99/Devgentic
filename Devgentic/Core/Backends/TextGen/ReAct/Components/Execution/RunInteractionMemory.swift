// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RunInteractionMemory.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Per-run memory of human interactions: the prevention half of loop safety, created fresh for each executor run.
/// An identical re-asked clarification replays the earlier answer; an identical denied confirmation is auto-denied.
/// On resume the maps are re-primed from the reconstructed timeline.
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

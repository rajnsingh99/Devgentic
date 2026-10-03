// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RetryMessageButton.swift
//  Devgentic
//
//  P1: Retry button for failed agent messages.
//

import SwiftUI

struct RetryMessageButton: View {
    let action: () -> Void
    /// Why the retry is unavailable, or nil when it may run. Defaulted so existing call sites are
    /// unaffected. Surfaced as a tooltip AND in the accessibility label — a dead control with no
    /// explanation reads as a bug, and a tooltip is mouse-only (CF-42).
    var refusal: RunAdmissionPolicy.Refusal? = nil
    var body: some View {
        TactileButton(
            title: "Retry",
            icon: "arrow.clockwise",
            variant: .secondary,
            size: .compact,
            isDisabled: refusal != nil,
            tooltip: refusal?.userFacingReason ?? String(localized: "Generate a new response")
        ) {
            action()
        }
        .accessibilityLabel(Self.spokenLabel(for: refusal))
    }

    /// What VoiceOver is told (CF-42).
    ///
    /// The refusal is the entire reason the control is dead, and `.help` delivers it only to a
    /// mouse pointer. `.disabled(refusal != nil)` already takes the button out of the actionable
    /// set, so a constant "Retry generating response" left a screen-reader user with a control
    /// that will not respond and no way to find out why — the same defect as XUI-10's mouse-only
    /// "Needs your input". Folded into the LABEL rather than a hint: VoiceOver reads hints last,
    /// after a delay, and can be configured not to read them at all.
    ///
    /// `nonisolated static` and pure so the wording is testable — the modifier it feeds cannot be
    /// read back from a hosted view.
    nonisolated static func spokenLabel(for refusal: RunAdmissionPolicy.Refusal?) -> String {
        guard let refusal else { return String(localized: "Retry generating response") }
        return String(localized: "Retry generating response, unavailable. \(refusal.userFacingReason)")
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RetryMessageButton.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

struct RetryMessageButton: View {
    let action: () -> Void
    /// Why the retry is unavailable, or nil when it may run. Defaulted so existing call sites are unaffected.
    /// Shown as a tooltip and in the accessibility label, since a tooltip is mouse-only.
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

    /// What VoiceOver is told: the refusal reason, which `.help` delivers only to a mouse pointer.
    /// Folded into the label rather than a hint, which VoiceOver reads last or not at all.
    /// `nonisolated static` and pure so the wording is testable.
    nonisolated static func spokenLabel(for refusal: RunAdmissionPolicy.Refusal?) -> String {
        guard let refusal else { return String(localized: "Retry generating response") }
        return String(localized: "Retry generating response, unavailable. \(refusal.userFacingReason)")
    }
}

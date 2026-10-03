// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SaveAdvisoryBanner.swift
//  Devgentic
//
//  Created on 08/08/26.
//
//  The product half of `ProfileValidationError.Severity.advisory`.
//
//  ⚠️ Register A34. The severity existed, the rules were evaluated on every save, and the result
//  went nowhere but a log line — so an advisory could only reach the user if someone hand-built a
//  bespoke view for that specific rule. Both rules that exist today did exactly that
//  (`ModelPickerView`'s alert for tool capability, the endpoint field's inline warning for A52),
//  which is the tell: the severity had no surface of its own, only workarounds.
//
//  ⚠️ Shown AFTER A SAVE, not continuously. That distinction is the whole design:
//
//  • An advisory describes likely-degraded behaviour, not a fault. A permanent banner would nag the
//    user about a choice they already made — and the standing project rule is that classification
//    metadata may describe but must never gate or badger.
//  • Appearing in response to the save the user just performed makes it solicited: they acted, and
//    this is what the app noticed. It is dismissible, and it clears on the next save.
//
//  ⚠️ It must never look like a failure. A save that produced advisories SUCCEEDED — the profile is
//  on disk. Warning colour, not error colour, and the copy says what may not work rather than what
//  went wrong.
//

import SwiftUI

struct SaveAdvisoryBanner: View {
    let advisories: [ProfileValidationError]
    let onDismiss: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        if !advisories.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.warningColor)
                        .accessibilityHidden(true)

                    Text(advisories.count == 1
                         ? "Saved — one thing worth knowing"
                         : "Saved — \(advisories.count) things worth knowing")
                        .font(theme.fontSubheadline.weight(.medium))
                        .foregroundColor(theme.primaryText)

                    Spacer()

                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }

                ForEach(advisories) { advisory in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(theme.fontCaption)
                            .foregroundColor(theme.secondaryText)
                            .accessibilityHidden(true)
                        Text(advisory.message)
                            .font(theme.fontCaption)
                            .foregroundColor(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.warningColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.warningColor.opacity(0.25), lineWidth: 0.5)
            )
            .frame(maxWidth: ViewLayout.maxContentWidth)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Saved with \(advisories.count) advisory note(s)")
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

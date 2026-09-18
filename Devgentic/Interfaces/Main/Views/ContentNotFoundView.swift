// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ContentNotFoundView.swift
//  Devgentic
//
//  Shared empty/error state shown when a detail view's target entity
//  (profile, prompt, task) can't be found.
//

import SwiftUI

struct ContentNotFoundView: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(theme.surfaceOverlay)
                    .frame(width: 80, height: 80)

                Image(systemName: icon)
                    .font(.system(size: 32)) // Fixed size: intentional (icon)
                    .foregroundColor(theme.secondaryText.opacity(0.6))
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(.title3, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                if let subtitle {
                    Text(subtitle)
                        .font(theme.fontSubheadline)
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

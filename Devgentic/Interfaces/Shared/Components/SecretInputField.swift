// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SecretInputField.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// A reusable credential input field: leading key icon, monospaced font, show/hide toggle and quick clear button,
/// on a rounded dark glass background.
struct SecretInputField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    var isDisabled: Bool = false
    var isConnected: Bool = false

    @State private var isRevealed: Bool = false
    @Environment(\.appTheme) private var theme

    private var effectiveDisabled: Bool {
        isDisabled || isConnected
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText.opacity(0.7))
                .accessibilityHidden(true)

            if isRevealed {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(theme.fontCodeCaption)
                    .foregroundColor(theme.primaryText)
                    .disabled(effectiveDisabled)
            } else {
                SecureField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(theme.fontCodeCaption)
                    .foregroundColor(theme.primaryText)
                    .disabled(effectiveDisabled)
            }

            if !text.isEmpty && !effectiveDisabled {
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText.opacity(0.8))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(isRevealed ? "Hide token" : "Show token")

                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText.opacity(0.6))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Clear token")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.secondaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.dividerColor.opacity(0.4), lineWidth: 1)
        )
    }
}

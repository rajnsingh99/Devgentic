// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingComponents.swift
//  Devgentic
//
//  Created by Raj Singh on 17/09/26.
//

import SwiftUI

// MARK: - Secondary Button (Back, Cancel, etc.) with Hover Effect
struct OnboardingSecondaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered: Bool = false

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(theme.fontBody)
            }
            .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? theme.secondaryBackground.opacity(0.85) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovered ? theme.dividerColor.opacity(0.8) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Primary Action Button with Hover Lift and Arrow Nudge
struct OnboardingPrimaryButton: View {
    let title: String
    let icon: String
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered: Bool = false

    init(_ title: String, icon: String = "arrow.right", isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .fontWeight(.semibold)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .offset(x: isHovered && isEnabled ? 2 : 0)
            }
            .font(theme.fontBody)
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(isEnabled ? Color.accentColor : Color.gray.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(
                color: isEnabled ? Color.accentColor.opacity(isHovered ? 0.5 : 0.3) : Color.clear,
                radius: isHovered ? 12 : 8,
                x: 0,
                y: isHovered ? 4 : 2
            )
            .scaleEffect(isEnabled && isHovered ? 1.02 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}

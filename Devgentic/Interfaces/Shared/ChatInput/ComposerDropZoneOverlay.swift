// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ComposerDropZoneOverlay.swift
//  Devgentic
//
//  Tactile animated drop zone overlay for Devgentic's composer surfaces.
//  Provides immediate visual and optical glass feedback styled in the user's
//  active accent color when dragging files or folders over the input area,
//  without obstructing touch/mouse hit testing.
//

import SwiftUI

struct ComposerDropZoneOverlay: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.surfaceStyle) private var surfaceStyle

    var cornerRadius: CGFloat = 18
    var message: String = "Drop files or folders to attach to context"
    var accentColorOverride: Color? = nil

    @State private var dashPhase: CGFloat = 0
    @State private var isBobbing: Bool = false

    private var activeAccentColor: Color {
        accentColorOverride ?? theme.accentColor
    }

    var body: some View {
        ZStack {
            // 1. Backdrop Fill (Liquid Glass material vs Solid Matte opaque)
            if surfaceStyle == .solid {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(theme.isDark ? Color(hex: "#18181B").opacity(0.96) : Color.white.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(activeAccentColor.opacity(0.08))
                    )
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.black.opacity(0.30))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(activeAccentColor.opacity(0.05))
                    )
            }

            // 2. Diffused Accent Outer Glow
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(activeAccentColor, lineWidth: 2.5)
                .blur(radius: 6)
                .opacity(0.50)

            // 3. Accent Animated Dashed Stroke
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    activeAccentColor,
                    style: StrokeStyle(
                        lineWidth: 2,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: [8, 6],
                        dashPhase: dashPhase
                    )
                )

            // 4. Centered Floating Pill
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(activeAccentColor)
                    .offset(y: isBobbing ? -2.5 : 2.5)

                Text(message)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundColor(surfaceStyle == .solid ? theme.primaryText : Color.white.opacity(0.95))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background {
                if surfaceStyle == .solid {
                    Capsule()
                        .fill(theme.isDark ? Color(hex: "#222225") : Color(hex: "#F4F4F5"))
                } else {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule()
                                .fill(Color.black.opacity(0.60))
                        )
                }
            }
            .overlay {
                if surfaceStyle == .solid {
                    Capsule()
                        .strokeBorder(theme.isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.12), lineWidth: 1)
                } else {
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.38), Color.white.opacity(0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
            }
            .shadow(
                color: Color.black.opacity(surfaceStyle == .solid ? (theme.isDark ? 0.45 : 0.15) : 0.45),
                radius: surfaceStyle == .solid ? 10 : 12,
                y: surfaceStyle == .solid ? 4 : 5
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 2.5).repeatForever(autoreverses: false)) {
                dashPhase = -28
            }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isBobbing = true
            }
        }
    }
}

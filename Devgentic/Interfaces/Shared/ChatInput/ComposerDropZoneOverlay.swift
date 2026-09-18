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
            // 1. Frosted Glass Backdrop Fill
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

            // 4. Centered Floating Glass Pill
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(activeAccentColor)
                    .offset(y: isBobbing ? -2.5 : 2.5)

                Text(message)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.95))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .fill(Color.black.opacity(0.60))
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.38), Color.white.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.45), radius: 12, y: 5)
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

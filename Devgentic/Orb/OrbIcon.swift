// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbIcon.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit

/// The Voice Orb toolbar icon: a gray waveform glyph at rest that blooms into a cyan-indigo-purple radial orb on hover.
struct OrbIcon: View {
    var size: CGFloat = 18
    var isHovered: Bool = false

    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            // Resting state: Monochrome gray waveform matching mic / toolbar icons
            OrbWaveformGlyph(size: 13)
                .foregroundColor(theme.secondaryText.opacity(0.85))
                .opacity(isHovered ? 0 : 1)
                .scaleEffect(isHovered ? 0.82 : 1.0)

            // Hovered state: Full-color glowing Orb Voice Orb matching HUD screenshot
            voiceOrbContent
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1.0 : 0.82)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.18), value: isHovered)
    }

    private var voiceOrbContent: some View {
        ZStack {
            // Ambient Aura Glow (subtle atmospheric halo matching the HUD)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.0, green: 0.88, blue: 1.0).opacity(0.55),
                            Color(red: 0.65, green: 0.25, blue: 0.95).opacity(0.35),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: size * 0.08,
                        endRadius: size * 0.68
                    )
                )
                .frame(width: size * 1.35, height: size * 1.35)
                .blur(radius: 2.5)

            // Main Voice Orb Gradient Sphere (Cyan core -> Indigo -> Purple edge)
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(red: 0.22, green: 0.88, blue: 1.00), location: 0.0),
                            .init(color: Color(red: 0.25, green: 0.52, blue: 1.00), location: 0.38),
                            .init(color: Color(red: 0.55, green: 0.30, blue: 0.98), location: 0.72),
                            .init(color: Color(red: 0.80, green: 0.38, blue: 0.98), location: 0.94),
                            .init(color: Color(red: 0.70, green: 0.28, blue: 0.92), location: 1.0)
                        ]),
                        center: .center,
                        startRadius: size * 0.04,
                        endRadius: size * 0.50
                    )
                )
                .frame(width: size, height: size)
                .shadow(
                    color: Color(red: 0.22, green: 0.88, blue: 1.0).opacity(0.45),
                    radius: 3
                )

            // Inner Specular Rim Highlight (delicate top-left reflection)
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.70),
                            Color.white.opacity(0.20),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: max(0.8, size * 0.055)
                )
                .frame(width: size * 0.93, height: size * 0.93)

            // Center White Waveform Glyph (5 vertical rounded capsules)
            OrbWaveformGlyph(size: size * 0.50)
                .foregroundColor(.white)
                .shadow(color: Color.white.opacity(0.85), radius: 2)
        }
    }
}

/// 5-bar vertical rounded audio waveform matching the HUD screenshot.
struct OrbWaveformGlyph: View {
    var size: CGFloat = 10

    var body: some View {
        let barWidth = max(1.25, size * 0.13)
        let spacing = max(1.1, size * 0.10)

        HStack(alignment: .center, spacing: spacing) {
            Capsule()
                .frame(width: barWidth, height: size * 0.36)

            Capsule()
                .frame(width: barWidth, height: size * 0.68)

            Capsule()
                .frame(width: barWidth, height: size * 0.96)

            Capsule()
                .frame(width: barWidth, height: size * 0.68)

            Capsule()
                .frame(width: barWidth, height: size * 0.36)
        }
        .frame(width: size, height: size)
    }
}

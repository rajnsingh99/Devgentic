// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbPalette.swift
//  Devgentic
//
//  [Orb MVP] The HUD's hologram look. Deliberately theme-independent: the
//  overlay is always a dark "holographic" surface regardless of app theme, so the
//  palette is fixed rather than drawn from the Theme protocol.
//

import SwiftUI

enum OrbPalette {

    /// Signature hologram cyan.
    static let hologram = Color(red: 0.36, green: 0.80, blue: 1.00)
    static let hologramDim = Color(red: 0.36, green: 0.80, blue: 1.00).opacity(0.45)
    static let hologramGlow = Color(red: 0.20, green: 0.70, blue: 1.00).opacity(0.60)
    static let deepIndigo = Color(red: 0.30, green: 0.25, blue: 0.90)

    /// Secondary accents for "working" and "alert" states.
    static let gold = Color(red: 1.00, green: 0.78, blue: 0.35)
    static let alert = Color(red: 1.00, green: 0.45, blue: 0.40)
    static let successEmerald = Color(red: 0.20, green: 0.85, blue: 0.55)

    static let backgroundTop = Color(red: 0.015, green: 0.03, blue: 0.06)
    static let backgroundBottom = Color(red: 0.00, green: 0.01, blue: 0.02)

    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)

    /// Panel chrome for glass cards.
    static let panelFill = Color.white.opacity(0.045)
    static let panelStroke = hologram.opacity(0.18)

    // MARK: - Gradients
    static var hologramGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.45, green: 0.88, blue: 1.00), hologram, Color(red: 0.20, green: 0.55, blue: 0.95)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var processingGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 1.00, green: 0.85, blue: 0.45), gold, Color(red: 0.95, green: 0.55, blue: 0.25)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var listeningGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.30, green: 0.85, blue: 1.00), Color(red: 0.40, green: 0.50, blue: 1.00)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var glassBorderGradient: LinearGradient {
        LinearGradient(
            colors: [hologram.opacity(0.45), Color.white.opacity(0.12), hologram.opacity(0.15)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Voice Orb Gradients (Modern Siri/Apple Intelligence Style)
    static var voiceOrbGradient: [Color] {
        [Color.cyan, Color.indigo, Color.purple]
    }

    static var voiceOrbCapturingGradient: [Color] {
        [Color.cyan, Color(red: 0.20, green: 0.55, blue: 1.00), Color.indigo]
    }

    static var voiceOrbProcessingGradient: [Color] {
        [gold, Color.indigo, Color.purple]
    }

    static var voiceOrbAlertGradient: [Color] {
        [alert, Color.purple, Color.indigo]
    }

    static var ambientAuraGradient: LinearGradient {
        LinearGradient(
            colors: [Color.cyan.opacity(0.35), Color.indigo.opacity(0.30), Color.purple.opacity(0.20)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Shared text styles

extension View {
    /// Uppercase, letter-spaced HUD label ("STANDING BY", "PROCESSING"…).
    func orbStatusStyle(color: Color = OrbPalette.hologram) -> some View {
        self
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .tracking(5)
            .foregroundColor(color)
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbCoreVisual.swift
//  Devgentic
//
//  [Orb] Modern Siri / Apple Intelligence style Voice Orb.
//  Replaces the legacy mechanical arc-reactor HUD with a fluid, multi-gradient
//  glowing orb that breathes calmly in standby, scales reactively to microphone
//  audio, flows with expanding ripple waves when speaking, and pulses with
//  warm amber/gold intelligence when processing.
//

import SwiftUI

/// What the core is currently expressing (mapped from OrbStage by the overlay).
enum OrbCoreMode {
    case idle          // profile picker backdrop
    case greeting
    case passive       // wake-word standby: slow, calm
    case capturing     // hot mic: audio-reactive
    case processing    // run in flight: fast, gold accents
    case speaking      // TTS out: soft emanating waves
    case alert         // voice unavailable
}

struct OrbCoreVisual: View {
    let mode: OrbCoreMode
    /// Normalized 0…1 microphone level (capturing mode).
    var level: CGFloat = 0
    /// Recent energy samples for audio responsiveness.
    var energy: [Float] = []
    var size: CGFloat = 130

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var gradientColors: [Color] {
        switch mode {
        case .capturing:
            return OrbPalette.voiceOrbCapturingGradient
        case .processing:
            return OrbPalette.voiceOrbProcessingGradient
        case .alert:
            return OrbPalette.voiceOrbAlertGradient
        default:
            return OrbPalette.voiceOrbGradient
        }
    }

    private var glowColor: Color {
        switch mode {
        case .processing: return OrbPalette.gold
        case .alert: return OrbPalette.alert
        case .capturing: return Color.cyan
        default: return Color.cyan
        }
    }

    private var glyphName: String {
        switch mode {
        case .alert: return "exclamationmark.triangle.fill"
        default: return "waveform"
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : 1.0 / 30.0)) { context in
            let t = reduceMotion ? 0.0 : context.date.timeIntervalSinceReferenceDate
            let breathe = reduceMotion ? 1.0 : (mode == .capturing ? 1.0 : (1.0 + 0.06 * sin(t * 2 * .pi / 2.4)))
            let captureScale = mode == .capturing ? (1.0 + level * 0.32) : 1.0
            let totalScale = breathe * captureScale
            let orbDiameter = size * 0.85

            ZStack {
                // Ambient Luminous Backdrop Aura
                ambientAura(t: t)

                // Speaking ripple wave rings (when TTS is active or welcoming)
                if mode == .speaking || mode == .greeting {
                    speakingRipples(t: t)
                }

                // Main Voice Orb Sphere
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: gradientColors),
                                center: .center,
                                startRadius: orbDiameter * 0.06,
                                endRadius: orbDiameter * 0.58
                            )
                        )
                        .rotationEffect(.degrees(mode == .processing && !reduceMotion ? (t * 45).truncatingRemainder(dividingBy: 360) : 0))
                        .frame(width: orbDiameter, height: orbDiameter)
                        .shadow(color: glowColor.opacity(mode == .capturing ? 0.75 : 0.55), radius: size * 0.16)

                    // Inner Specular Glow Ring
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.45), Color.white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                        .frame(width: orbDiameter * 0.94, height: orbDiameter * 0.94)

                    // Center Dynamic Waveform Equalizer Bars or Alert Icon
                    dynamicCenterVisual(t: t)
                }
                .scaleEffect(totalScale)
                .animation(.easeOut(duration: 0.15), value: captureScale)
            }
            .frame(width: size, height: size)
        }
    }

    // MARK: - Ambient Backdrop Aura (Organic Circular Radial Glow)
    private func ambientAura(t: TimeInterval) -> some View {
        let auraOpacity: Double = {
            switch mode {
            case .capturing: return 0.40 + Double(level) * 0.25
            case .processing: return 0.35
            case .alert: return 0.32
            default: return 0.25
            }
        }()

        let primaryColor = gradientColors.first ?? glowColor
        let secondaryColor = gradientColors.indices.contains(1) ? gradientColors[1] : glowColor
        let tertiaryColor = gradientColors.indices.contains(2) ? gradientColors[2] : Color.clear

        return ZStack {
            // Broad outer atmospheric radial halo (fades completely to transparent at perimeter)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            primaryColor.opacity(auraOpacity * 0.65),
                            secondaryColor.opacity(auraOpacity * 0.30),
                            tertiaryColor.opacity(auraOpacity * 0.10),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: size * 0.12,
                        endRadius: size * 0.72
                    )
                )
                .frame(width: size * 1.5, height: size * 1.5)
                .blur(radius: size * 0.10)

            // Inner core luminous aura
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            glowColor.opacity(auraOpacity * 0.85),
                            secondaryColor.opacity(auraOpacity * 0.35),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: size * 0.05,
                        endRadius: size * 0.52
                    )
                )
                .frame(width: size * 1.20, height: size * 1.20)
                .blur(radius: size * 0.06)
        }
    }

    // MARK: - Speaking Ripples
    private func speakingRipples(t: TimeInterval) -> some View {
        ForEach(0..<2, id: \.self) { index in
            let phase = ((t + Double(index) * 0.6) / 1.6).truncatingRemainder(dividingBy: 1.0)
            Circle()
                .stroke(
                    glowColor.opacity((1.0 - phase) * 0.5),
                    lineWidth: 1.8
                )
                .frame(
                    width: size * 0.75 + (size * 0.42 * phase),
                    height: size * 0.75 + (size * 0.42 * phase)
                )
        }
    }

    // MARK: - Center Visual (Dynamic Waveform Equalizer Bars or Alert Glyph)
    @ViewBuilder
    private func dynamicCenterVisual(t: TimeInterval) -> some View {
        if mode == .alert {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: size * 0.28, weight: .bold))
                .foregroundColor(.white)
                .shadow(color: Color.white.opacity(0.8), radius: 6)
        } else {
            OrbDynamicWaveformBars(
                mode: mode,
                level: level,
                energy: energy,
                t: t,
                size: size,
                reduceMotion: reduceMotion
            )
        }
    }
}

// MARK: - Dynamic Audio-Reactive Waveform Bars

/// 5-bar vertical rounded audio equalizer that dances fluidly to speech energy,
/// breathes gently in standby, ripples in processing, and pulses with speaking cadence.
struct OrbDynamicWaveformBars: View {
    let mode: OrbCoreMode
    let level: CGFloat
    let energy: [Float]
    let t: TimeInterval
    let size: CGFloat
    let reduceMotion: Bool

    // Baseline height multiplier profiles for the 5 bars (index 0..<5)
    // Creates the signature rounded-arch audio waveform matching the HUD screenshot.
    private let baseProfiles: [CGFloat] = [0.36, 0.68, 0.98, 0.68, 0.36]

    var body: some View {
        let barWidth = max(2.5, size * 0.048)
        let spacing = max(2.4, size * 0.038)
        let totalHeight = size * 0.38

        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<5, id: \.self) { index in
                let barH = computedBarHeight(index: index, maxHeight: totalHeight, barWidth: barWidth)
                Capsule()
                    .fill(Color.white)
                    .frame(width: barWidth, height: barH)
                    .shadow(color: Color.white.opacity(0.85), radius: size * 0.03)
            }
        }
        .frame(height: totalHeight)
    }

    private func computedBarHeight(index: Int, maxHeight: CGFloat, barWidth: CGFloat) -> CGFloat {
        let baseH = maxHeight * baseProfiles[index]

        if reduceMotion {
            return baseH
        }

        let dynamicH: CGFloat
        switch mode {
        case .capturing:
            // Hot mic: reactive to live microphone level and vocal frequencies
            let harmonicOffset: Double = {
                switch index {
                case 0: return -1.4
                case 1: return -0.7
                case 2: return 0.0
                case 3: return 0.7
                default: return 1.4
                }
            }()
            let vocalFlutter = 0.08 * sin(t * 18.0 + harmonicOffset)
            let sensitivity: CGFloat = index == 2 ? 1.0 : (index == 1 || index == 3 ? 0.78 : 0.58)
            let factor = 0.30 + (level * sensitivity * 0.85) + CGFloat(vocalFlutter)
            dynamicH = baseH * max(0.22, min(1.30, factor))

        case .passive:
            // Standby: gentle, organic breathing wave across the bars
            let wave = sin(t * 2.2 + Double(index) * 0.75)
            let factor = 0.80 + 0.20 * wave
            dynamicH = baseH * CGFloat(factor)

        case .processing:
            // Working / Thinking: smooth undulating harmonic ripple
            let wave = sin(t * 4.8 + Double(index) * 1.15)
            let factor = 0.65 + 0.35 * wave
            dynamicH = baseH * CGFloat(factor)

        case .speaking, .greeting:
            // Voice output / TTS: cadenced speech rhythm
            let speechCadence = sin(t * 3.8) * cos(t * 1.9 + Double(index) * 0.55)
            let factor = 0.60 + 0.40 * abs(speechCadence)
            dynamicH = baseH * CGFloat(factor)

        case .idle:
            dynamicH = baseH * 0.88

        case .alert:
            dynamicH = baseH
        }

        // Ensure bars never collapse below their capsule width
        return max(barWidth, dynamicH)
    }
}

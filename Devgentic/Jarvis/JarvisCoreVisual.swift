// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  JarvisCoreVisual.swift
//  Devgentic
//
//  [Jarvis MVP] The animated arc-reactor core — the centerpiece of the HUD.
//  Pure SwiftUI: TimelineView-driven ring rotations, an audio-reactive energy
//  ring (Canvas), and a breathing plasma center. Honors Reduce Motion by
//  freezing rotations and dropping the pulse (level/opacity cues remain).
//

import SwiftUI

/// What the core is currently expressing (mapped from JarvisStage by the overlay).
enum JarvisCoreMode {
    case idle          // profile picker backdrop
    case greeting
    case passive       // wake-word standby: slow, calm
    case capturing     // hot mic: audio-reactive
    case processing    // run in flight: fast, gold accents
    case speaking      // TTS out: soft emanating waves
    case alert         // voice unavailable
}

struct JarvisCoreVisual: View {
    let mode: JarvisCoreMode
    /// Normalized 0…1 microphone level (capturing mode).
    var level: CGFloat = 0
    /// Recent energy samples for the radial bar ring.
    var energy: [Float] = []
    var size: CGFloat = 300

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color {
        switch mode {
        case .alert: return JarvisPalette.alert
        case .processing: return JarvisPalette.hologram
        default: return JarvisPalette.hologram
        }
    }

    private var coreScale: CGFloat {
        switch mode {
        case .capturing: return 1.0 + level * 0.28
        default: return 1.0
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : 1.0 / 30.0)) { context in
            let t = reduceMotion ? 0.0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                ambientGlow
                outerDashedRing(t: t)
                segmentedRing(t: t)
                tickRing
                energyRing
                processingArc(t: t)
                speakingWaves(t: t)
                plasmaCore(t: t)
            }
            .frame(width: size, height: size)
        }
    }

    // MARK: Layers

    private var ambientGlow: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(mode == .capturing ? 0.38 : (mode == .processing ? 0.30 : 0.18)), accent.opacity(0.05), .clear],
                        center: .center, startRadius: 0, endRadius: size * 0.54
                    )
                )
                .scaleEffect(coreScale)

            if mode == .capturing || mode == .processing {
                Circle()
                    .fill(accent.opacity(0.25))
                    .blur(radius: size * 0.18)
                    .scaleEffect(coreScale * 1.05)
            }
        }
    }

    /// Slow outer dashed ring — 14s per revolution.
    private func outerDashedRing(t: TimeInterval) -> some View {
        Circle()
            .stroke(
                LinearGradient(
                    colors: [accent.opacity(0.45), accent.opacity(0.12), accent.opacity(0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                style: StrokeStyle(lineWidth: 1.2, dash: [3, 8])
            )
            .frame(width: size * 0.96, height: size * 0.96)
            .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 14) / 14 * 360))
    }

    /// Three counter-rotating arc segments — 9s per revolution.
    private func segmentedRing(t: TimeInterval) -> some View {
        let rotation = -(t.truncatingRemainder(dividingBy: 9) / 9 * 360)
        return ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .shadow(color: accent.opacity(0.6), radius: 4, x: 0, y: 0)
                    .rotationEffect(.degrees(Double(index) * 120))
            }
        }
        .frame(width: size * 0.80, height: size * 0.80)
        .rotationEffect(.degrees(rotation))
    }

    /// Static fine tick marks — instrument-panel texture.
    private var tickRing: some View {
        ZStack {
            ForEach(0..<36, id: \.self) { index in
                Rectangle()
                    .fill(accent.opacity(index % 3 == 0 ? 0.65 : 0.25))
                    .frame(width: index % 3 == 0 ? 1.5 : 1.0, height: index % 3 == 0 ? 9 : 4.5)
                    .shadow(color: index % 3 == 0 ? accent.opacity(0.4) : .clear, radius: 2)
                    .offset(y: -size * 0.335)
                    .rotationEffect(.degrees(Double(index) * 10))
            }
        }
    }

    /// Audio-reactive radial bars (capturing) — falls back to a faint static ring.
    private var energyRing: some View {
        Canvas { canvasContext, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let barCount = 48
            let innerRadius = size * 0.245
            for index in 0..<barCount {
                let sample: CGFloat
                if mode == .capturing, !energy.isEmpty {
                    let sampleIndex = index * max(1, energy.count / barCount) % energy.count
                    sample = CGFloat(min(1.0, max(0.0, energy[sampleIndex] / 0.25)))
                } else {
                    sample = 0.08
                }
                let barLength = 3.5 + sample * (size * 0.09)
                let angle = CGFloat(index) / CGFloat(barCount) * 2 * .pi
                let from = CGPoint(x: center.x + cos(angle) * innerRadius,
                                   y: center.y + sin(angle) * innerRadius)
                let to = CGPoint(x: center.x + cos(angle) * (innerRadius + barLength),
                                 y: center.y + sin(angle) * (innerRadius + barLength))
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                let opacity = mode == .capturing ? (0.4 + sample * 0.6) : 0.3
                canvasContext.stroke(
                    path,
                    with: .color(accent.opacity(opacity)),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
            }
        }
        .frame(width: size, height: size)
        .animation(.linear(duration: 0.1), value: energy)
    }

    /// Fast gold arc while a run is in flight — 1.6s per revolution.
    @ViewBuilder
    private func processingArc(t: TimeInterval) -> some View {
        if mode == .processing {
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.35)
                    .stroke(
                        AngularGradient(colors: [.clear, JarvisPalette.gold, .white], center: .center),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                    )
                    .shadow(color: JarvisPalette.gold.opacity(0.8), radius: 6)
                    .frame(width: size * 0.60, height: size * 0.60)
                    .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1.6) / 1.6 * 360))
            }
        }
    }

    /// Two expanding rings while TTS is speaking.
    @ViewBuilder
    private func speakingWaves(t: TimeInterval) -> some View {
        if mode == .speaking || mode == .greeting {
            ForEach(0..<2, id: \.self) { index in
                let phase = ((t + Double(index)) / 2.0).truncatingRemainder(dividingBy: 1.0)
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [accent.opacity((1 - phase) * 0.6), accent.opacity(0.1)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.8
                    )
                    .shadow(color: accent.opacity((1 - phase) * 0.4), radius: 4)
                    .frame(width: size * 0.35 + size * 0.5 * phase,
                           height: size * 0.35 + size * 0.5 * phase)
            }
        }
    }

    /// The plasma center: gradient disc + white-hot pip, breathing in passive mode.
    private func plasmaCore(t: TimeInterval) -> some View {
        let breathe: CGFloat = {
            guard !reduceMotion else { return 1.0 }
            switch mode {
            case .passive, .idle: return 1.0 + 0.05 * sin(t * 2 * .pi / 3.2)
            default: return 1.0
            }
        }()
        return ZStack {
            // Ambient core aura
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            mode == .processing ? JarvisPalette.gold.opacity(0.9) : accent.opacity(0.9),
                            accent.opacity(0.35),
                            .clear
                        ],
                        center: .center, startRadius: 2, endRadius: size * 0.22
                    )
                )
                .frame(width: size * 0.44, height: size * 0.44)

            // Inner specular ring
            Circle()
                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                .frame(width: size * 0.22, height: size * 0.22)

            // White-hot core pip
            Circle()
                .fill(Color.white.opacity(0.98))
                .frame(width: size * 0.08, height: size * 0.08)
                .blur(radius: 0.8)
                .shadow(color: mode == .processing ? JarvisPalette.gold : accent, radius: 12)
        }
        .scaleEffect(coreScale * breathe)
        .animation(.easeOut(duration: 0.12), value: coreScale)
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DevgenticActivityIndicator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Context-adaptive activity indicator styles for Devgentic.
enum DevgenticIndicatorStyle: Sendable, Equatable {
    /// Macro reasoning & graph orchestration (Chat thought process, streaming footer, workflow execution)
    case gyroscope
    /// Code syntax synthesis & live editing (Code Viewer, live file writes, inline code blocks)
    case syntaxNexus
}

/// A lightweight, GPU-accelerated vector indicator replacing generic SF symbols (`sparkles`).
///
/// Fully vector, scalable, dark/light theme aware, and respects `accessibilityReduceMotion`.
struct DevgenticActivityIndicator: View {
    var style: DevgenticIndicatorStyle = .gyroscope
    var size: CGFloat = 14
    var tint: Color? = nil

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activeColor: Color {
        tint ?? theme.streamingIndicator
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvasSize in
                let w = canvasSize.width
                let h = canvasSize.height
                let c = CGPoint(x: w / 2, y: h / 2)
                let dim = min(w, h)

                switch style {
                case .gyroscope:
                    drawGyroscope(context: &context, center: c, size: dim, elapsed: elapsed)
                case .syntaxNexus:
                    drawSyntaxNexus(context: &context, center: c, size: dim, elapsed: elapsed)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch style {
        case .gyroscope:
            return String(localized: "Thinking")
        case .syntaxNexus:
            return String(localized: "Synthesizing code")
        }
    }

    // MARK: - 1. Gyroscopic Flux
    // Dual counter-rotating 3D tilted elliptical rings
    private func drawGyroscope(context: inout GraphicsContext, center: CGPoint, size: CGFloat, elapsed: Double) {
        let rOuterX = size * 0.44
        let rOuterY = size * 0.22
        let rInnerX = size * 0.33
        let rInnerY = size * 0.15

        // Outer Ring (tilted at 35°, rotating clockwise)
        var outerCtx = context
        outerCtx.translateBy(x: center.x, y: center.y)
        let outerAngle = reduceMotion ? Angle(degrees: 35) : Angle(degrees: (elapsed * 55).truncatingRemainder(dividingBy: 360) + 35)
        outerCtx.rotate(by: outerAngle)
        let outerEllipse = Path(ellipseIn: CGRect(x: -rOuterX, y: -rOuterY, width: rOuterX * 2, height: rOuterY * 2))
        outerCtx.stroke(
            outerEllipse,
            with: .color(activeColor.opacity(0.85)),
            style: StrokeStyle(lineWidth: max(1.0, size * 0.08), dash: [size * 0.4, size * 0.16])
        )

        // Inner Ring (tilted at -35°, counter-rotating)
        var innerCtx = context
        innerCtx.translateBy(x: center.x, y: center.y)
        let innerAngle = reduceMotion ? Angle(degrees: -35) : Angle(degrees: -(elapsed * 75).truncatingRemainder(dividingBy: 360) - 35)
        innerCtx.rotate(by: innerAngle)
        let innerEllipse = Path(ellipseIn: CGRect(x: -rInnerX, y: -rInnerY, width: rInnerX * 2, height: rInnerY * 2))
        innerCtx.stroke(
            innerEllipse,
            with: .color(activeColor.opacity(0.65)),
            style: StrokeStyle(lineWidth: max(0.9, size * 0.07))
        )
    }

    // MARK: - 2. Syntax Nexus
    // Breathing developer chevrons (< >) embracing a pulsing luminous core
    private func drawSyntaxNexus(context: inout GraphicsContext, center: CGPoint, size: CGFloat, elapsed: Double) {
        let breath = reduceMotion ? 0 : sin(elapsed * 3.5) * (size * 0.08)
        let corePulse = reduceMotion ? 1.0 : 0.65 + 0.35 * (0.5 + 0.5 * sin(elapsed * 3.5))

        let leftX = center.x - size * 0.26 - breath
        let rightX = center.x + size * 0.26 + breath
        let chevronH = size * 0.40
        let chevSpread = size * 0.18
        let strokeW = max(1.2, size * 0.10)

        // Left Chevron (<)
        var leftChevron = Path()
        leftChevron.move(to: CGPoint(x: leftX + chevSpread, y: center.y - chevronH / 2))
        leftChevron.addLine(to: CGPoint(x: leftX, y: center.y))
        leftChevron.addLine(to: CGPoint(x: leftX + chevSpread, y: center.y + chevronH / 2))
        context.stroke(
            leftChevron,
            with: .color(activeColor.opacity(0.92)),
            style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round)
        )

        // Right Chevron (>)
        var rightChevron = Path()
        rightChevron.move(to: CGPoint(x: rightX - chevSpread, y: center.y - chevronH / 2))
        rightChevron.addLine(to: CGPoint(x: rightX, y: center.y))
        rightChevron.addLine(to: CGPoint(x: rightX - chevSpread, y: center.y + chevronH / 2))
        context.stroke(
            rightChevron,
            with: .color(activeColor.opacity(0.92)),
            style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round)
        )

        // Central Energy Core (·)
        let coreRadius = (size * 0.11) * corePulse
        let coreRect = CGRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2)
        context.fill(Path(ellipseIn: coreRect), with: .color(activeColor.opacity(0.85 * corePulse)))
    }
}

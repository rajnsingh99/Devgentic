// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AgentRobotIcon.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Bespoke vector robot icon for Agent profiles, drawn in pure SwiftUI shapes that scale crisply from 14pt to 256pt.
/// Antenna with signal dot and bulb node, squircle head with circular eyes and a pill mouth, subtle torso curve.
struct AgentRobotIcon: View {
    var size: CGFloat = 24
    var color: Color? = nil
    var isFilled: Bool = false
    var isHovered: Bool = false
    var isThinking: Bool = false

    @Environment(\.appTheme) private var theme
    @State private var pulseState: Bool = false

    private var activeColor: Color {
        color ?? theme.accentColor
    }

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let strokeWidth = max(1.1, w * 0.055)
            let baseColor = isHovered ? activeColor : (color ?? theme.secondaryText)

            // 1. Torso / Shoulder Curve
            var shoulderPath = Path()
            shoulderPath.move(to: CGPoint(x: w * 0.16, y: h * 0.94))
            shoulderPath.addQuadCurve(
                to: CGPoint(x: w * 0.84, y: h * 0.94),
                control: CGPoint(x: w * 0.50, y: h * 0.85)
            )
            context.stroke(
                shoulderPath,
                with: .color(baseColor.opacity(isHovered ? 0.85 : 0.65)),
                style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
            )

            // 2. Squircle Head Outline
            let headRect = CGRect(
                x: w * 0.20,
                y: h * 0.41,
                width: w * 0.60,
                height: h * 0.39
            )
            let headCornerRadius = max(3.0, w * 0.12)
            let headPath = Path(roundedRect: headRect, cornerRadius: headCornerRadius, style: .continuous)
            
            if isFilled {
                context.fill(headPath, with: .color(baseColor.opacity(0.12)))
            } else if isHovered {
                context.fill(headPath, with: .color(activeColor.opacity(0.06)))
            }
            context.stroke(
                headPath,
                with: .color(baseColor),
                style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
            )

            // 3. Eyes
            let eyeRadius = max(1.3, w * 0.068)
            let leftEyeRect = CGRect(
                x: w * 0.38 - eyeRadius,
                y: h * 0.59 - eyeRadius,
                width: eyeRadius * 2,
                height: eyeRadius * 2
            )
            let rightEyeRect = CGRect(
                x: w * 0.62 - eyeRadius,
                y: h * 0.59 - eyeRadius,
                width: eyeRadius * 2,
                height: eyeRadius * 2
            )
            context.fill(Path(ellipseIn: leftEyeRect), with: .color(baseColor))
            context.fill(Path(ellipseIn: rightEyeRect), with: .color(baseColor))

            // 4. Mouth
            var mouthPath = Path()
            mouthPath.move(to: CGPoint(x: w * 0.44, y: h * 0.72))
            mouthPath.addLine(to: CGPoint(x: w * 0.56, y: h * 0.72))
            context.stroke(
                mouthPath,
                with: .color(baseColor.opacity(isHovered ? 0.85 : 0.60)),
                style: StrokeStyle(lineWidth: max(1.0, w * 0.045), lineCap: .round)
            )

            // 5. Antenna Stem
            var antennaPath = Path()
            antennaPath.move(to: CGPoint(x: w * 0.50, y: h * 0.32))
            antennaPath.addLine(to: CGPoint(x: w * 0.50, y: h * 0.41))
            context.stroke(
                antennaPath,
                with: .color(baseColor),
                style: StrokeStyle(lineWidth: max(1.0, w * 0.048), lineCap: .round)
            )

            // 6. Antenna Bulb Node
            let bulbRadius = max(1.2, w * 0.060)
            let bulbRect = CGRect(
                x: w * 0.50 - bulbRadius,
                y: h * 0.28 - bulbRadius,
                width: bulbRadius * 2,
                height: bulbRadius * 2
            )
            context.fill(Path(ellipseIn: bulbRect), with: .color(baseColor))

            // 7. Single Floating Signal Dot above Antenna
            let dotRadius = max(1.3, w * 0.068)
            let dotYOffset = (isThinking && pulseState) ? -h * 0.03 : 0.0
            let dotRect = CGRect(
                x: w * 0.50 - dotRadius,
                y: (h * 0.12 + dotYOffset) - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            let dotOpacity = (isHovered || isFilled) ? 0.95 : 0.60
            context.fill(Path(ellipseIn: dotRect), with: .color(baseColor.opacity(dotOpacity)))
        }
        .frame(width: size, height: size)
        .shadow(
            color: isHovered ? activeColor.opacity(0.40) : Color.clear,
            radius: max(2, size * 0.12)
        )
        .onAppear {
            if isThinking {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    pulseState = true
                }
            }
        }
    }
}

// MARK: - Profile Type Icon Bridge

/// Unified icon component for any ProfileType. Automatically delegates to
/// the bespoke AgentRobotIcon for Agent profiles and standard SF Symbols for others.
struct ProfileTypeIcon: View {
    let type: ProfileType
    var size: CGFloat = 18
    var color: Color? = nil
    var isFilled: Bool = false
    var isHovered: Bool = false
    var isThinking: Bool = false

    @Environment(\.appTheme) private var theme

    private var effectiveColor: Color {
        color ?? theme.accentColor
    }

    var body: some View {
        if type == .agent {
            AgentRobotIcon(
                size: size,
                color: color,
                isFilled: isFilled,
                isHovered: isHovered,
                isThinking: isThinking
            )
        } else {
            Image(systemName: isFilled ? type.iconNameFilled : type.iconName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundColor(effectiveColor)
        }
    }
}

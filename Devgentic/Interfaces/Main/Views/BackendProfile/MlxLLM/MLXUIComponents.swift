// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXUIComponents.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Circular progress indicator for an in-flight MLX model download; shows the percentage and swaps to
/// an X on hover. The parent confirms the cancel action via an alert.
struct MLXDownloadProgressCircle: View {
    let progress: Double
    let onCancelRequested: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A real Button rather than a tap gesture, so cancelling is reachable by keyboard and VoiceOver.
        Button(action: onCancelRequested) {
            circleBody
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel("Cancel download")
        .accessibilityValue("\(Int(progress * 100)) percent complete")
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        // `pointerStyle` is tied to the view's lifetime; pushing and popping `NSCursor` from `onHover` leaks a
        // cursor if the exit event never arrives.
        .pointerStyle(.link)
        .help("Cancel download")
    }

    private var circleBody: some View {
        ZStack {
            Circle()
                .stroke(theme.surfaceOverlayStrong, lineWidth: 3)

            Circle()
                .trim(from: 0, to: max(0.0, min(progress, 1.0)))
                .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: progress)

            if isHovered {
                Image(systemName: "xmark")
                    .font(.system(.caption, weight: .bold))
                    .foregroundColor(theme.errorColor)
            } else {
                Text("\(Int(progress * 100))%")
                    .font(.system(.caption, weight: .semibold).monospacedDigit())
                    .foregroundColor(theme.primaryText.opacity(0.9))
            }
        }
        .frame(width: 44, height: 44)
    }
}

/// A visual badge representing a specific model capability (e.g. "Reasoning", "Vision").
/// In icon-only mode (default), renders as a compact 24×24 circular icon chip with a hover tooltip.
struct CapabilityBadge: View {
    let capability: MLXModelCapability
    var iconOnly: Bool = true

    @Environment(\.appTheme) private var theme

    private var accentColor: Color {
        switch capability {
        case .reasoning: return .purple
        case .toolUse: return .orange
        case .vision: return .blue
        case .coding: return .green
        case .textGeneration: return theme.secondaryText
        }
    }

    var body: some View {
        Group {
            if iconOnly {
                Image(systemName: capability.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(accentColor)
                    .frame(width: 24, height: 24)
                    .background(theme.surfaceOverlay)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(theme.surfaceOverlayStrong.opacity(0.6), lineWidth: 0.5)
                    )
            } else {
                HStack(spacing: 5) {
                    Image(systemName: capability.icon)
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundColor(accentColor)

                    Text(capability.localizedTitle)
                        .font(.caption2)
                        .foregroundColor(theme.primaryText.opacity(0.85))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(theme.surfaceOverlay)
                .clipShape(Capsule())
            }
        }
        .help(capability.localizedTitle)
        .accessibilityLabel(capability.localizedTitle)
    }
}

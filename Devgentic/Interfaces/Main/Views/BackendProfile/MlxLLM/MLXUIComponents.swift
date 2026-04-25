//
//  MLXUIComponents.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//

import SwiftUI

/// Circular progress indicator used on MLX model cards during an in-flight
/// download. Shows percentage in the center by default; on hover, swaps to an
/// X icon so the user can request cancellation with a single click.
/// The parent is responsible for confirming the cancel action via alert.
struct MLXDownloadProgressCircle: View {
    let progress: Double
    let onCancelRequested: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.surfaceOverlayStrong, lineWidth: 3)

            Circle()
                .trim(from: 0, to: max(0.0, min(progress, 1.0)))
                .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: progress)

            if isHovered {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(theme.errorColor)
            } else {
                Text("\(Int(progress * 100))%")
                    .font(.system(.caption, weight: .semibold).monospacedDigit())
                    .foregroundColor(theme.primaryText.opacity(0.9))
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .onTapGesture {
            onCancelRequested()
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("Click to cancel download")
    }
}

/// A visual badge representing a specific model capability (e.g. "Reasoning", "Vision").
/// Uses a unified neutral style across all capabilities — the accent color is
/// expressed only through the small leading icon, keeping the card calm when
/// multiple badges stack together.
struct CapabilityBadge: View {
    let capability: MLXModelCapability

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
        HStack(spacing: 5) {
            Image(systemName: capability.icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(accentColor)

            Text(capability.rawValue)
                .font(.caption2)
                .foregroundColor(theme.primaryText.opacity(0.85))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.surfaceOverlay)
        .clipShape(Capsule())
    }
}

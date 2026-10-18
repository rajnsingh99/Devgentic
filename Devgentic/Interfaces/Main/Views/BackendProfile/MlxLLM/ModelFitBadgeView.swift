// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModelFitBadgeView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// A compact badge showing the model fit verdict, reusable across MLX and Ollama stores and pickers.
/// Styled like `CapabilityBadge`: a neutral capsule with the verdict colour as a small leading dot.
struct ModelFitBadgeView: View {
    let assessment: ModelFitAssessment
    /// Compact mode shows only the verdict label. Full mode shows the RAM estimate.
    var compact: Bool = false

    @Environment(\.appTheme) private var theme

    private var badgeColor: Color {
        switch assessment.verdict {
        case .comfortable: return .green
        case .tight: return .yellow
        case .risky: return .orange
        case .incompatible: return .red
        // Deliberately grey, not green: an unknown fit must not read as a safe one.
        case .unknown: return .secondary
        }
    }

    /// The badge text and VoiceOver form: verdict plus estimate, so the verdict is not conveyed by colour alone.
    /// Returns `Text`, not `String`, so the label localizes; the switch is exhaustive so a new verdict cannot fall through.
    private var accessibleLabel: Text {
        let verdict = Text(assessment.verdict.localizedTitle)
        switch assessment.verdict {
        case .unknown:
            return verdict
        case .comfortable, .tight, .risky, .incompatible:
            guard assessment.estimatedRuntimeRAM > 0 else { return verdict }
            return verdict + Text(" · ~\(assessment.formattedEstimatedRAM) RAM")
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            // A per-verdict symbol so the signal survives without colour.
            Image(systemName: assessment.verdict.systemImage)
                .font(.caption2)
                .foregroundColor(badgeColor)

            // Composed rather than interpolated: the verdict is a translatable key and the RAM figure a number appended after it,
            // since `Text(label)` binds to the non-localizing overload.
            Group {
                if compact || assessment.estimatedRuntimeRAM <= 0 {
                    Text(assessment.verdict.localizedTitle)
                } else {
                    Text(assessment.verdict.localizedTitle)
                        + Text(verbatim: " · ~\(assessment.formattedEstimatedRAM) RAM")
                }
            }
            .font(.caption2)
            .foregroundColor(theme.primaryText.opacity(0.85))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.surfaceOverlay)
        .clipShape(Capsule())
        .help(assessment.explanation)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Memory fit: \(accessibleLabel)"))
        .accessibilityHint(assessment.explanation)
    }
}

/// A slightly larger inline indicator for model lists, showing estimated RAM and a brief explanation.
struct ModelFitInlineView: View {
    let assessment: ModelFitAssessment

    private var indicatorColor: Color {
        switch assessment.verdict {
        case .comfortable: return .green
        case .tight: return .yellow
        case .risky: return .orange
        case .incompatible: return .red
        // Deliberately grey, not green: an unknown fit must not read as a safe one.
        case .unknown: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)

            Text(assessment.explanation)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}

/// A pre-download advisory sheet shown when a model is risky or incompatible.
struct ModelFitAdvisoryView: View {
    let modelName: String
    let assessment: ModelFitAssessment
    let onDownloadAnyway: () -> Void
    let onDismiss: () -> Void

    @Environment(\.appTheme) private var theme

    private var accentColor: Color {
        assessment.verdict == .incompatible ? .red : .orange
    }

    private var freeDisk: String? {
        guard let bytes = MLXModelService.availableBytes(
            onVolumeContaining: MLXModelService.shared.modelsDirectory
        ) else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: assessment.verdict.systemImage)
                .font(.system(size: 40)) // Fixed size: intentional (icon)
                .foregroundColor(accentColor)

            // Title
            Text(assessment.verdict == .incompatible ? "Model Too Large" : "Memory Warning")
                .font(.title2)
                .fontWeight(.bold)

            // Explanation
            VStack(spacing: 8) {
                Text(modelName)
                    .font(.headline)
                    .foregroundColor(theme.primaryText)

                Text(assessment.explanation)
                    .font(.body)
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)

                if let recommendation = assessment.recommendation {
                    Text(recommendation)
                        .font(.callout)
                        .foregroundColor(accentColor)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }

            // System Info
            let profile = SystemHardwareProfiler.shared.profile
            HStack(spacing: 20) {
                VStack(spacing: 2) {
                    Text("System RAM")
                        .font(.caption2)
                        .foregroundColor(theme.secondaryText)
                    Text(profile.formattedTotalRAM)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                VStack(spacing: 2) {
                    Text("Available Budget")
                        .font(.caption2)
                        .foregroundColor(theme.secondaryText)
                    Text(profile.formattedEffectiveBudget)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                VStack(spacing: 2) {
                    Text("Model Needs")
                        .font(.caption2)
                        .foregroundColor(theme.secondaryText)
                    Text(assessment.formattedEstimatedRAM)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(accentColor)
                }
                // The sheet models RAM only, so free disk space is shown to inform a multi-gigabyte download.
                if let freeDisk {
                    VStack(spacing: 2) {
                        Text("Free Disk")
                            .font(.caption2)
                            .foregroundColor(theme.secondaryText)
                        Text(freeDisk)
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                }
            }
            .padding()
            .background(theme.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Actions
            HStack(spacing: 12) {
                TactileButton(
                    title: "Download Anyway",
                    variant: .secondary,
                    size: .regular
                ) {
                    onDownloadAnyway()
                }

                TactileButton(
                    title: "Cancel",
                    variant: .primary,
                    size: .regular
                ) {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 420)
    }
}

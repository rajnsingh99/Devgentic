//
//  ModelFitBadgeView.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import SwiftUI

/// A compact badge that displays the model fit verdict with color coding.
/// Reusable across MLX and Ollama model stores and pickers.
///
/// Styled to match `CapabilityBadge` — subtle neutral capsule with the verdict
/// color expressed only as a small leading dot, so stacks of badges stay calm
/// and the truly-critical verdicts (risky/incompatible) still read clearly.
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

    /// Verdict + estimate in text. The badge used to encode the verdict in the dot's COLOUR
    /// alone and show only a bare "2.9 GB" — which sat next to the card's disk size and read
    /// as a duplicate of it, with nothing saying it meant RAM. Colour-only is also invisible
    /// to anyone who can't distinguish these hues.
    /// VoiceOver form of the badge.
    ///
    /// ⚠️ Returns `Text`, not `String`: `accessibilityLabel(_: String)` does not localize, so
    /// this read `verdict.rawValue` out in English while the visible label beside it — already
    /// converted to `localizedTitle` — was translated.
    ///
    /// ⚠️ Exhaustive, with no `default:`. The old `default:` arm both hid the raw value and
    /// meant a verdict added later would silently fall into it, which is exactly how `.paused`
    /// came to render as a raw string on the download rows.
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

            // Composed rather than interpolated into one string: the verdict is a
            // translatable key, the RAM figure is a formatted number appended after it.
            // `Text(label)` would have bound to the non-localizing overload and lost both.
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

/// A slightly larger inline indicator for model pickers, showing estimated RAM and a brief explanation.
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
                // This sheet models RAM only, but the user is about to commit multiple
                // gigabytes of DISK. Showing free space here is the difference between an
                // informed "Download Anyway" and one that fills the startup volume.
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
                Button("Download Anyway") {
                    onDownloadAnyway()
                }
                .buttonStyle(.bordered)

                Button("Cancel") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 420)
    }
}

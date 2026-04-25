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
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(badgeColor)
                .frame(width: 6, height: 6)

            Text(compact ? assessment.verdict.rawValue : assessment.formattedEstimatedRAM)
                .font(.caption2)
                .foregroundColor(theme.primaryText.opacity(0.85))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.surfaceOverlay)
        .clipShape(Capsule())
        .help(assessment.explanation)
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

//
//  ModelFitBadgeView.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import SwiftUI

/// A compact badge that displays the model fit verdict with color coding.
/// Reusable across MLX and Ollama model stores and pickers.
struct ModelFitBadgeView: View {
    let assessment: ModelFitAssessment
    /// Compact mode shows only the icon + verdict. Full mode adds the RAM estimate.
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
        HStack(spacing: 4) {
            Image(systemName: assessment.verdict.systemImage)
                .font(.caption2)

            if compact {
                Text(assessment.verdict.rawValue)
                    .font(.caption2)
                    .fontWeight(.medium)
            } else {
                Text("\(assessment.formattedEstimatedRAM)")
                    .font(.caption2)
                    .fontWeight(.medium)
            }
        }
        .foregroundColor(badgeColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(badgeColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(badgeColor.opacity(0.3), lineWidth: 1)
        )
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
                .font(.system(size: 40))
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
            .cornerRadius(8)

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

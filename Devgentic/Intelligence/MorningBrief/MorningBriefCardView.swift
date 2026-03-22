//
//  MorningBriefCardView.swift
//  Devgentic
//
//  Created by Devgentic Architect
//  Redesigned — premium AI insight card with glass-morphism styling.
//

import SwiftUI

/// Displays the Morning Brief as a premium AI-powered insight card.
/// Each conversation gets a summary + suggestion, tappable to navigate.
struct MorningBriefCardView: View {

    let brief: MorningBrief
    let onNavigate: (BriefItemDestination) -> Void
    let onDismiss: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var appearedInsights: Set<UUID> = []
    @State private var showSystem = false

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            headerView

            // MARK: - Insights
            VStack(spacing: 12) {
                ForEach(Array(brief.insights.enumerated()), id: \.element.id) { index, insight in
                    insightCard(insight, index: index)
                        .opacity(appearedInsights.contains(insight.id) ? 1 : 0)
                        .offset(y: appearedInsights.contains(insight.id) ? 0 : 10)
                        .animation(
                            .spring(response: 0.45, dampingFraction: 0.8).delay(Double(index) * 0.12),
                            value: appearedInsights.contains(insight.id)
                        )
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.12) {
                                appearedInsights.insert(insight.id)
                            }
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            // System status
            if let status = brief.systemStatus {
                systemFooter(status)
                    .opacity(showSystem ? 1 : 0)
                    .animation(.easeOut(duration: 0.3), value: showSystem)
                    .onAppear {
                        let delay = Double(brief.insights.count) * 0.12 + 0.25
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            showSystem = true
                        }
                    }
            }

            Spacer().frame(height: 16)
        }
        .background(theme.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.surfaceOverlayStrong, lineWidth: 1)
        )
        .shadow(color: theme.primaryText.opacity(0.05), radius: 24, x: 0, y: 12)
        .frame(maxWidth: 500)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .center) {
            HStack(spacing: 8) {
                // Gradient sunrise orb
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.orange.opacity(0.2), .yellow.opacity(0.1)],
                                startPoint: .bottomLeading,
                                endPoint: .topTrailing
                            )
                        )
                        .frame(width: 32, height: 32)

                    Image(systemName: "sunrise.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.orange, .yellow],
                                startPoint: .bottomLeading,
                                endPoint: .topTrailing
                            )
                        )
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Morning Brief")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.primaryText)

                    Text(brief.generatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }
            }

            Spacer()

            // AI badge
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                Text("AI Generated")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(theme.accentColor.opacity(0.1))
            .clipShape(Capsule())

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 22, height: 22)
                    .background(theme.secondaryBackground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss brief")
            .padding(.leading, 6)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Insight Card

    private func insightCard(_ insight: ConversationInsight, index: Int) -> some View {
        Button(action: {
            onNavigate(.conversation(id: insight.conversationID))
        }) {
            VStack(alignment: .leading, spacing: 10) {
                // Title row
                HStack(alignment: .center, spacing: 8) {
                    // Numbered indicator
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(theme.accentColor)
                        .frame(width: 20, height: 20)
                        .background(theme.accentColor.opacity(0.12))
                        .clipShape(Circle())

                    Text(insight.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    Spacer()

                    Text(insight.timeAgo)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(theme.tertiaryText)
                }

                // AI Summary
                Text(insight.summary)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)

                // Suggestion
                if let suggestion = insight.suggestion {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                            .padding(.top, 2)

                        Text(suggestion)
                            .font(.system(size: 11))
                            .foregroundColor(theme.primaryText.opacity(0.85))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.orange.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.orange.opacity(0.12), lineWidth: 0.5)
                            )
                    )
                    .padding(.leading, 28)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.secondaryBackground.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.surfaceOverlayStrong.opacity(0.6), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - System Footer

    private func systemFooter(_ status: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 9))

            Text(status)
                .font(.system(size: 10))
                .lineLimit(1)
        }
        .foregroundColor(theme.tertiaryText)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

// MARK: - Loading State View

/// Shown while the brief is being generated.
struct MorningBriefLoadingView: View {
    @Environment(\.appTheme) private var theme
    @State private var pulseOpacity: Double = 0.4

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(pulseOpacity))
                    .frame(width: 36, height: 36)
                    .animation(
                        .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                        value: pulseOpacity
                    )

                Image(systemName: "sunrise.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.orange, .yellow],
                            startPoint: .bottomLeading,
                            endPoint: .topTrailing
                        )
                    )
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Preparing your brief")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(theme.primaryText)

                Text("Analysing recent conversations...")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer()

            ProgressView()
                .controlSize(.small)
                .tint(theme.accentColor)
        }
        .padding(16)
        .background(theme.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.surfaceOverlayStrong, lineWidth: 1)
        )
        .frame(maxWidth: 500)
        .onAppear { pulseOpacity = 0.15 }
    }
}

//
//  SubAgentChipView.swift
//  Devgentic
//
//  A compact chip representing an inline sub-agent in the delegation capability section.
//  Follows the Nested Card pattern from ui_philosophy.md:
//    background: secondaryBackground.opacity(0.5), radius: 10, border: 0.5px surfaceOverlayStrong.opacity(0.6)
//

import SwiftUI

struct SubAgentChipView: View {
    let subAgent: SubAgentConfig
    var onConfigure: () -> Void
    var onDelete: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Provider icon
            Image(systemName: providerIcon)
                .font(.system(size: 14))
                .foregroundColor(isHovered ? .accentColor : theme.secondaryText)
                .frame(width: 20, alignment: .center)

            // Labels
            VStack(alignment: .leading, spacing: 2) {
                Text(subAgent.name.isEmpty ? "Unnamed" : subAgent.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Text(modelShortName)
                    .font(.caption2)
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }

            if isHovered {
                HStack(spacing: 2) {
                    Button(action: onConfigure) {
                        Image(systemName: "gearshape")
                            .font(.caption2)
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Configure")

                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isHovered ? Color.accentColor.opacity(0.4) : theme.surfaceOverlayStrong.opacity(0.6),
                    lineWidth: isHovered ? 1 : 0.5
                )
        )
        .shadow(
            color: theme.primaryText.opacity(isHovered ? 0.06 : 0.02),
            radius: isHovered ? 8 : 4, x: 0, y: 2
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .onTapGesture(count: 2) { onConfigure() }
    }

    // MARK: - Helpers

    private var modelShortName: String {
        let name = subAgent.llmConfig.modelName
        if name.contains("/") {
            return String(name.split(separator: "/").last ?? Substring(name))
        }
        return name.isEmpty ? "No model" : name
    }

    private var providerIcon: String {
        switch subAgent.llmConfig.apiProvider {
        case .anthropic: return "cloud.fill"
        case .openAI: return "cloud.fill"
        case .google: return "cloud.fill"
        case .ollama: return "server.rack"
        case .mlx: return "desktopcomputer"
        }
    }
}

//
//  PromptRowView.swift
//  Devgentic
//
//  Created by Antigravity.
//

import SwiftUI

struct PromptRowView: View {
    let prompt: DevPrompt
    let isSelected: Bool
    
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    @State private var isHovering = false
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        HStack(spacing: 0) {
            standardContentView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                self.isHovering = hovering
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
    
    @ViewBuilder
    private var standardContentView: some View {
        HStack(alignment: .top, spacing: 0) {
            // Accent gradient line on left for selected state
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.4)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .padding(.trailing, 6)
                    .transition(.scale(scale: 0.5, anchor: .leading).combined(with: .opacity))
            }
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(prompt.title)
                        .font(theme.fontSubheadline.weight(.medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    Spacer()

                    if !isHovering {
                        Text(prompt.category)
                            .font(.system(size: 10, weight: .medium)) // Fixed size: intentional (badge/chip text)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(theme.accentColor.opacity(0.1))
                            .foregroundColor(theme.accentColor.opacity(0.8))
                            .clipShape(Capsule())
                            .transition(.opacity)
                    }
                }

                Text(prompt.text)
                    .font(.system(.caption))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
    
    @ViewBuilder
    private var backgroundView: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.accentColor.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: theme.accentColor.opacity(0.05), radius: 4, x: 0, y: 0)
        } else if isHovering {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceOverlay)
        } else {
            Color.clear
        }
    }
}

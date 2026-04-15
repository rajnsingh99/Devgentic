//
//  WorkflowOutcomeCardView.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  A single workflow node's execution result card.
//  Fixed vertical rectangle showing agent name + timeline preview.
//  Tapping selects the card and renders full detail in the output area below.
//

import SwiftUI

struct WorkflowOutcomeCardView: View {
    let nodeData: WorkflowRunDisplayData.NodeDisplayData
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private var durationText: String {
        let d = nodeData.duration
        if d < 1 { return "<1s" }
        if d < 60 { return "\(String(format: "%.1f", d))s" }
        return "\(Int(d / 60))m \(Int(d.truncatingRemainder(dividingBy: 60)))s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: status + name
            HStack(spacing: 6) {
                if nodeData.status == .running {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: nodeData.status.icon)
                        .foregroundColor(nodeData.status.color)
                        .font(.system(size: 13))
                }
                Text(nodeData.profileName)
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()
                .padding(.horizontal, 8)

            // Timeline preview (clipped, non-interactive)
            if !nodeData.nodeTimeline.isEmpty {
                AgentTimelineView(events: nodeData.nodeTimeline, isStreaming: nodeData.isStreaming)
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .clipped()
                    .allowsHitTesting(false)
            } else if !nodeData.detail.isEmpty && nodeData.status != .running {
                // Fallback: show output preview when no timeline
                Text(nodeData.detail)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                Spacer()
            }

            Divider()
                .padding(.horizontal, 8)

            // Footer: duration + event count
            HStack(spacing: 6) {
                Text(durationText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryText)

                if !nodeData.nodeTimeline.isEmpty {
                    Text("\(nodeData.nodeTimeline.count) event\(nodeData.nodeTimeline.count == 1 ? "" : "s")")
                        .font(.system(size: 9))
                        .foregroundColor(theme.tertiaryText)
                }

                Spacer(minLength: 0)

                Text(nodeData.status.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(nodeData.status.color)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 200)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? theme.accentColor.opacity(0.08) : (isHovering ? theme.surfaceOverlay : theme.controlBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? theme.accentColor : nodeData.status.color.opacity(isHovering ? 0.5 : 0.3),
                    lineWidth: isSelected ? 2 : 1.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

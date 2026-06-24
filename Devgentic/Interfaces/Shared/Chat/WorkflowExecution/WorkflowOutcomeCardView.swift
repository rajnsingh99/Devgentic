//
//  WorkflowOutcomeCardView.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Redesign (build 2026-04-25): each card represents a single workflow node and
//  shows the *input* the node received (or will receive). Three visual states —
//  pending / running / completed-or-failed — are driven entirely by
//  `NodeDisplayData.status`. The full output for the selected card now renders
//  in the dedicated Final Output area below the strip, not inside the card.
//

import SwiftUI

struct WorkflowOutcomeCardView: View {
    let nodeData: WorkflowRunDisplayData.NodeDisplayData
    let isSelected: Bool
    /// [HITL/P4] When true, this node is paused awaiting a HITL response — the request itself
    /// renders in the shared above-input banner; this badge points the user at the right node (D2).
    var isAwaitingInput: Bool = false
    let onTap: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private var durationText: String {
        let d = nodeData.duration
        if d < 1 { return "<1s" }
        if d < 60 { return "\(String(format: "%.1f", d))s" }
        return "\(Int(d / 60))m \(Int(d.truncatingRemainder(dividingBy: 60)))s"
    }

    private var statusColor: Color { nodeData.status.color }

    /// Body text resolution. Terminal states (`.completed` / `.failed`) preview
    /// the node's *output* (`detail`) so each card mirrors the Final Outcome
    /// card and the user can scan results without selecting every node. Pre-
    /// terminal states (`.pending` / `.running` / `.skipped`) preview the
    /// upstream-derived input — i.e. "what's coming into this node" — so the
    /// user can see the flow before output exists.
    private var bodyText: String? {
        switch nodeData.status {
        case .completed, .failed:
            let detail = nodeData.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? nil : detail
        case .pending, .running, .skipped:
            if let input = nodeData.input?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty {
                return input
            }
            return nil
        }
    }

    private var fallbackBodyText: String {
        switch nodeData.status {
        case .pending:
            if let src = nodeData.inputSourceLabel, !src.isEmpty {
                return "Waiting for \(src)…"
            }
            return "Awaiting input…"
        case .running:
            return "Running…"
        case .skipped:
            return "Skipped — upstream condition not met."
        case .failed:
            return "Failed — no output produced."
        default:
            return "—"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: status icon + name + duration
            HStack(spacing: 8) {
                statusBadge
                Text(nodeData.profileName)
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if nodeData.status != .pending && nodeData.duration > 0 {
                    Text(durationText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // Body: terminal nodes preview their output; pre-terminal nodes
            // preview their upstream input. Font is intentionally compact —
            // 240×180 cards fit the most useful preview at ~11pt.
            Group {
                if let text = bodyText {
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(5)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Text(fallbackBodyText)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .italic()
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            // Footer: status label band — or an "awaiting input" call-out when this node is
            // paused on a HITL request (D2). The actual prompt lives in the shared banner.
            HStack(spacing: 6) {
                if isAwaitingInput {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Needs your input")
                        .font(.system(size: 11, weight: .semibold))
                } else {
                    Text(nodeData.status.label)
                        .font(.system(size: 11, weight: .semibold))
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(isAwaitingInput ? theme.warningColor : statusColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((isAwaitingInput ? theme.warningColor : statusColor).opacity(isAwaitingInput ? 0.14 : 0.08))
        }
        .frame(width: 240, height: 180)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isAwaitingInput ? theme.warningColor
                        : (isSelected ? statusColor : statusColor.opacity(isHovering ? 0.55 : 0.35)),
                    lineWidth: (isAwaitingInput || isSelected) ? 2 : 1.5
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

    @ViewBuilder
    private var statusBadge: some View {
        switch nodeData.status {
        case .running:
            ProgressView()
                .controlSize(.small)
                .tint(statusColor)
        default:
            Image(systemName: nodeData.status.icon)
                .foregroundColor(statusColor)
                .font(.system(size: 14))
        }
    }
}

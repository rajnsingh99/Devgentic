//
//  QuickAccessHITLBanner.swift
//  Devgentic
//
//  [QA revival P1c] In-panel Human-in-the-Loop banner. The app's InteractionBannerStack is
//  bound to the main window's selectedConversationID and its per-kind banners are fileprivate,
//  so the panel needs its own compact host. It reads one pending interaction (strict FIFO) for
//  the panel's conversation and answers via ExecutionSuspensionService — the same operationID-
//  keyed path every other surface uses, so an answer here (or in the main window) resolves the
//  request everywhere. Rendered as a self-contained themed card so it stays readable over the
//  panel's translucent glass in either light or dark theme.
//

import SwiftUI

struct QuickAccessHITLBanner: View {
    let pending: PendingHITL
    let session: QuickAccessSessionViewModel

    @Environment(\.appTheme) private var theme
    @State private var clarificationText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            if let hint = keyboardHint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .accessibilityHidden(true) // affordance hint; actions are already labeled
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.primaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.warningColor.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 4)
        // Reset per-item @State (typed answer) when the FIFO advances to a new request.
        .id(pending.id)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: headerIcon)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundColor(theme.warningColor)
            Text(pending.origin.title)
                .font(theme.fontSubheadline.weight(.semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var headerIcon: String {
        switch pending.kind {
        case .toolConfirmation(let c): return c.risk.icon
        case .clarification: return "questionmark.bubble"
        case .planReview: return "list.bullet.rectangle"
        case .gate: return "arrow.triangle.branch"
        }
    }

    /// [M9] Discoverability hint for the panel-level keyboard shortcuts. ⌘Return approves the
    /// yes/no kinds; Escape always cancels/denies. Clarification & gate need typed/selected input,
    /// so only Escape is advertised there.
    private var keyboardHint: LocalizedStringKey? { // [M10] LocalizedStringKey so hints are extracted
        switch pending.kind {
        case .toolConfirmation, .planReview: return "⌘⏎ approve · esc cancel"
        case .clarification, .gate: return "esc to cancel"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch pending.kind {
        case .toolConfirmation(let confirmation): toolConfirmationView(confirmation)
        case .clarification(let clarification): clarificationView(clarification)
        case .planReview(let plan): planReviewView(plan)
        case .gate(let gate): gateView(gate)
        }
    }

    // MARK: - Tool confirmation

    @ViewBuilder
    private func toolConfirmationView(_ c: PendingToolConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(c.toolName)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(c.risk.label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(c.risk.color(in: theme))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(c.risk.color(in: theme).opacity(0.15)))
            }
            if !c.params.isEmpty {
                Text(c.params)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                actionButton("Deny", color: theme.secondaryText, filled: false) { session.denyTool(pending) }
                // "Allow for this chat" is hidden for destructive tools (always re-prompt).
                if c.risk != .destructive {
                    actionButton("Allow for chat", color: theme.accentColor, filled: false) {
                        session.approveTool(pending, allowForChat: true)
                    }
                }
                Spacer(minLength: 0)
                actionButton(c.risk == .destructive ? "Allow anyway" : "Approve",
                             color: c.risk == .destructive ? theme.errorColor : theme.successColor,
                             filled: true) {
                    session.approveTool(pending, allowForChat: false)
                }
            }
        }
    }

    // MARK: - Clarification

    @ViewBuilder
    private func clarificationView(_ c: PendingClarification) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(c.question)
                .font(theme.fontBody)
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let options = c.options, !options.isEmpty {
                // One-tap suggested answers.
                FlowRow(options: options) { option in
                    session.submitClarification(pending, text: option)
                }
            } else {
                HStack(spacing: 8) {
                    TextField("Type your answer…", text: $clarificationText, axis: c.multiline ? .vertical : .horizontal)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(c.multiline ? 4 : 1)
                        .onSubmit { session.submitClarification(pending, text: clarificationText) }
                    actionButton("Send", color: theme.accentColor, filled: true) {
                        session.submitClarification(pending, text: clarificationText)
                    }
                    .disabled(clarificationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Plan review

    @ViewBuilder
    private func planReviewView(_ p: PendingPlanReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // [M10] Automatic grammar agreement instead of a hand-rolled English "s" — pluralizes
            // correctly per locale via the string catalog.
            Text("Proposed plan — ^[\(p.subtasks.count) step](inflect: true)")
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(theme.secondaryText)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(p.subtasks.enumerated()), id: \.element.id) { index, task in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                            .font(.system(.caption, design: .monospaced, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                        Text(task.description)
                            .font(.system(.caption))
                            .foregroundColor(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 8) {
                actionButton("Reject", color: theme.secondaryText, filled: false) { session.resolvePlan(pending, approved: false) }
                Spacer(minLength: 0)
                actionButton("Approve plan", color: theme.successColor, filled: true) { session.resolvePlan(pending, approved: true) }
            }
        }
    }

    // MARK: - Gate

    @ViewBuilder
    private func gateView(_ g: PendingGate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(g.prompt)
                .font(theme.fontBody)
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            // ⚠️ A Router's ambiguity arbitration carries the text being routed in `inputText`
            // rather than inside the prompt, because the highlight spans are measured against that
            // exact string. Without this the QuickAccess panel would show "2 rules match this
            // input — which branch?" and never show the input.
            //
            // Deliberately PLAIN here: this compact panel has no room for the colour-coded spans the
            // main banner paints, so it degrades to unhighlighted text rather than dropping it.
            if let input = g.inputText, !input.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(input)
                        .font(.system(.caption))
                        .foregroundColor(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 72)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.surfaceOverlay.opacity(0.35)))
            }

            FlowRow(options: g.options) { option in
                session.chooseGate(pending, option: option)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    // [M10] LocalizedStringKey (not String) so the literal call-site labels ("Deny", "Approve", …)
    // are extracted into Localizable.xcstrings instead of shipping verbatim English.
    private func actionButton(_ title: LocalizedStringKey, color: Color, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(filled ? .white : color)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(
                    Capsule().fill(filled ? color : Color.clear)
                )
                .overlay(
                    Capsule().stroke(color.opacity(filled ? 0 : 0.5), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Simple wrapping row of one-tap option chips (clarification suggestions / gate options).
private struct FlowRow: View {
    let options: [String]
    let onTap: (String) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        // Compact: a horizontally-scrolling row keeps the banner height bounded even with
        // many options, which matters in a small floating panel.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    Button(action: { onTap(option) }) {
                        Text(option)
                            .font(.system(.caption, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(theme.surfaceOverlay))
                            .overlay(Capsule().stroke(theme.accentColor.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

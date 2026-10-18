// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CapabilityProgressCards.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

// MARK: - Plan Progress Card

/// Structured progress cards for agent capabilities: `PlanProgressCard` (Plan & Execute checklist) and
/// `ReflectionAttemptsCard` (Reflexion attempts). Both render `TimelineEvent` payloads updated in place
/// while streaming and reuse AgentTimelineView for nested events.
struct PlanProgressCard: View {
    let data: PlanRunData
    var isStreaming: Bool = false
    /// The chat conversation this card lives in, forwarded into each step's nested timeline for its file
    /// rows' destination check. nil off the chat path (previews, non-chat hosts).
    var conversationID: UUID? = nil

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// nil = automatic (expanded while unfinished, receipt when finished); user taps override.
    @State private var cardExpandedOverride: Bool? = nil
    /// Per-step user toggles; absent = automatic (the running step is expanded).
    @State private var stepExpandOverrides: [String: Bool] = [:]

    private var capColor: Color { theme.capabilityColor(for: .planning) }

    /// Live means the run is still producing events; a persisted card left unfinished by a force-quit is
    /// not live and renders frozen. Gates both the ticking `elapsedLabel` and the step glyph
    /// (`CapabilityStatusIcon`).
    private var isLive: Bool { isStreaming && data.phase != .finished }

    private var isCardExpanded: Bool { cardExpandedOverride ?? (data.phase != .finished) }

    /// `.other` is deliberately not settled: an unrecognised status from a newer build must not count as
    /// done. Under-reporting progress on a finished plan is the safer error.
    private var settledCount: Int {
        data.steps.filter {
            $0.status != .pending && $0.status != .running && !$0.status.isUnrecognised
        }.count
    }

    /// True for a plan that finished cancelled before any step ran (review rejection).
    private var wasRejectedBeforeRun: Bool {
        data.phase == .finished && data.outcome == .cancelled && data.steps.allSatisfy { $0.status == .pending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            if isCardExpanded && !data.steps.isEmpty {
                Divider().background(theme.dividerColor.opacity(0.35))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(data.steps.enumerated()), id: \.element.id) { index, step in
                        stepRow(step, index: index)
                        if step.id != data.steps.last?.id {
                            Divider().background(theme.dividerColor.opacity(0.25))
                        }
                    }
                }
            }

            if isCardExpanded && data.phase == .awaitingApproval {
                Divider().background(theme.dividerColor.opacity(0.35))
                HStack(spacing: 6) {
                    Image(systemName: "checklist.checked")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Review and approve in the banner below")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(theme.streamingIndicator.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadiusPanel, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [capColor.opacity(0.08), capColor.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusPanel, style: .continuous)
                .stroke(capColor.opacity(0.18), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plan: \(headerSummaryText)")
    }

    // MARK: Header

    /// Everything the header asserts about the run, as one string, including failures that
    /// `headerStatusText` omits. The accessibility label replaces the button's content wholesale, so the
    /// warnings pill and per-step labels are otherwise unreachable.
    nonisolated static func headerSummary(for data: PlanRunData, statusText: String) -> String {
        guard let suffix = degradedSuffix(for: data) else { return statusText }
        return "\(statusText) · \(suffix)"
    }

    /// The WarningsPill's text when the header shows one, nil when it does not. The `if` in
    /// `headerRow` reads this too, so the label and the pill cannot disagree about WHEN a run
    /// counts as degraded — the disagreement is the whole bug.
    nonisolated static func degradedSuffix(for data: PlanRunData) -> String? {
        guard data.phase == .finished, data.hasDegradedSteps else { return nil }
        return degradedPillText(for: data)
    }

    private var headerSummaryText: String {
        Self.headerSummary(for: data, statusText: headerStatusText)
    }

    private var headerRow: some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                cardExpandedOverride = !isCardExpanded
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(capColor)

                Text("Plan")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                Text(headerStatusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)

                if data.phase == .executing {
                    ProgressCapsule(fraction: data.steps.isEmpty ? 0 : Double(settledCount) / Double(data.steps.count), tint: capColor)
                        .frame(maxWidth: 120)
                }

                Spacer(minLength: 8)

                if let degraded = Self.degradedSuffix(for: data) {
                    WarningsPill(text: degraded)
                }

                elapsedLabel

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .rotationEffect(.degrees(isCardExpanded ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The summary rides the button label: `.accessibilityLabel` replaces the computed label, hiding status
        // and warnings.
        .accessibilityLabel(
            "\(headerSummaryText). " + (isCardExpanded ? String(localized: "Collapse plan") : String(localized: "Expand plan"))
        )
    }

    private var headerStatusText: String {
        switch data.phase {
        case .awaitingApproval:
            return "\(data.steps.count) step\(data.steps.count == 1 ? "" : "s") · awaiting approval"
        case .executing:
            return String(localized: "\(data.completedCount) of \(data.steps.count) done")
        case .finished:
            if wasRejectedBeforeRun { return String(localized: "rejected before execution") }
            if data.outcome == .cancelled { return String(localized: "cancelled") }
            return "\(data.steps.count) step\(data.steps.count == 1 ? "" : "s") · \(data.completedCount) done"
        }
    }

    nonisolated static func degradedPillText(for data: PlanRunData) -> String {
        let failed = data.steps.filter { $0.status == .failed }.count
        let warned = data.steps.filter { $0.status == .warning }.count
        if failed > 0 && warned > 0 { return String(localized: "\(failed) failed · \(warned) ended early") }
        if failed > 0 { return String(localized: "\(failed) failed") }
        return String(localized: "\(warned) ended early")
    }

    @ViewBuilder
    private var elapsedLabel: some View {
        if isLive {
            TimelineView(.periodic(from: data.startedAt, by: 1.0)) { timeline in
                Text(DurationFormat.elapsed(from: data.startedAt, to: timeline.date))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .monospacedDigit()
            }
        } else if let finishedAt = data.finishedAt {
            Text(DurationFormat.elapsed(from: data.startedAt, to: finishedAt))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
        }
    }

    // MARK: Step rows

    private func isStepExpanded(_ step: PlanStepData) -> Bool {
        stepExpandOverrides[step.id] ?? (step.status == .running)
    }

    /// The summary the disclosure will actually show, or nil when it would show none.
    /// One predicate read by both the chevron (`hasDetail`) and the body, so a chevron never expands to
    /// nothing. The "Completed (" guard skips the capability's synthetic "Completed (N tool calls)" string.
    nonisolated static func disclosedSummary(_ step: PlanStepData) -> String? {
        guard let summary = step.summary, !summary.isEmpty, !summary.hasPrefix("Completed (") else { return nil }
        return summary
    }

    @ViewBuilder
    private func stepRow(_ step: PlanStepData, index: Int) -> some View {
        let expanded = isStepExpanded(step)
        let hasDetail = !step.events.isEmpty || Self.disclosedSummary(step) != nil

        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasDetail else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                    stepExpandOverrides[step.id] = !expanded
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CapabilityStatusIcon(status: step.status, isLive: isLive)
                        .frame(width: 16, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.system(size: 13, weight: step.status == .running ? .medium : .regular))
                            .foregroundColor(titleColor(for: step.status))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        // Failure or early-stop reason at a glance, so expanding is not required to learn why a step went
                        // amber or red.
                        if step.status == .failed || step.status == .warning,
                           let summary = step.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.system(size: 11))
                                .foregroundColor(step.status == .failed ? theme.errorColor.opacity(0.9) : theme.warningColor.opacity(0.9))
                                .lineLimit(2)
                        }
                    }

                    Spacer(minLength: 8)

                    if let meta = stepMeta(step) {
                        Text(meta)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }

                    if hasDetail {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.tertiaryText)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    step.status == .running
                        ? capColor.opacity(0.07)
                        : Color.clear
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Step \(index + 1): \(step.title), \(Text(step.status.localizedTitle))"))

            if expanded && hasDetail {
                VStack(alignment: .leading, spacing: 6) {
                    if !step.events.isEmpty {
                        AgentTimelineView(
                            events: step.events,
                            isStreaming: isLive && step.status == .running,
                            chatFidelity: true,
                            conversationID: conversationID
                        )
                    }
                    // The subtask's closing summary, shown after the events and muted, using the chevron's predicate.
                    // For `.failed`/`.warning` it repeats the clamped reason in full.
                    if let summary = Self.disclosedSummary(step) {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText.opacity(0.85))
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 30)
                .padding(.trailing, 12)
                .padding(.bottom, 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [capColor.opacity(0.35), capColor.opacity(0.05)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(width: 2)
                        .padding(.leading, 18)
                }
                .transition(.opacity)
            }
        }
    }

    private func titleColor(for status: PlanStepStatus) -> Color {
        switch status {
        case .pending:   return theme.secondaryText.opacity(0.55)
        case .running:   return theme.primaryText
        case .cancelled: return theme.secondaryText.opacity(0.7)
        default:         return theme.secondaryText
        }
    }

    private func stepMeta(_ step: PlanStepData) -> String? {
        var parts: [String] = []
        let toolCount = step.events.reduce(0) { count, event in
            if case .toolExecution = event { return count + 1 }
            return count
        }
        if toolCount > 0 { parts.append("\(toolCount) tool\(toolCount == 1 ? "" : "s")") }
        if let ms = step.durationMs, ms >= 100 { parts.append(DurationFormat.milliseconds(ms)) }
        if step.status == .pending { parts.append(String(localized: "pending")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Reflection Attempts Card

struct ReflectionAttemptsCard: View {
    let data: ReflectionRunData
    var isStreaming: Bool = false
    /// Same purpose as `PlanProgressCard.conversationID`: the attempt's nested timeline sits inside a chat
    /// message and needs the destination check.
    var conversationID: UUID? = nil

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var cardExpandedOverride: Bool? = nil
    @State private var attemptExpandOverrides: [Int: Bool] = [:]

    private var capColor: Color { theme.capabilityColor(for: .reflection) }

    private var isLive: Bool { isStreaming && data.finishedAt == nil }

    private var isCardExpanded: Bool { cardExpandedOverride ?? (data.finishedAt == nil || isStreaming) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            if isCardExpanded && !data.attempts.isEmpty {
                Divider().background(theme.dividerColor.opacity(0.35))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(data.attempts) { attempt in
                        attemptRow(attempt)
                        if attempt.trial != data.attempts.last?.trial {
                            Divider().background(theme.dividerColor.opacity(0.25))
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadiusPanel, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [capColor.opacity(0.08), capColor.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusPanel, style: .continuous)
                .stroke(capColor.opacity(0.18), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attempts: \(headerStatusText)")
    }

    private var headerRow: some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                cardExpandedOverride = !isCardExpanded
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.trianglehead.2.counterclockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(capColor)

                Text("Attempts")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                Text(headerStatusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                elapsedLabel

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .rotationEffect(.degrees(isCardExpanded ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The status text is folded into the label, since `.accessibilityLabel` replaces the computed one
        // and per-attempt verdicts are unreachable while the card is collapsed.
        .accessibilityLabel(
            "\(headerStatusText). " + (isCardExpanded ? String(localized: "Collapse attempts") : String(localized: "Expand attempts"))
        )
    }

    private var headerStatusText: String {
        if let accepted = data.acceptedTrial {
            return String(localized: "accepted on attempt \(accepted) of \(data.maxTrials)")
        }
        if data.finishedAt == nil {
            let current = data.attempts.last?.trial ?? 1
            return String(localized: "attempt \(current) of \(data.maxTrials)")
        }
        switch data.outcome {
        case .cancelled: return String(localized: "cancelled")
        case .failed:    return String(localized: "no attempt accepted")
        default:         return "completed after \(data.attempts.count) attempt\(data.attempts.count == 1 ? "" : "s")"
        }
    }

    @ViewBuilder
    private var elapsedLabel: some View {
        if isLive {
            TimelineView(.periodic(from: data.startedAt, by: 1.0)) { timeline in
                Text(DurationFormat.elapsed(from: data.startedAt, to: timeline.date))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .monospacedDigit()
            }
        } else if let finishedAt = data.finishedAt {
            Text(DurationFormat.elapsed(from: data.startedAt, to: finishedAt))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
        }
    }

    // MARK: Attempt rows

    private func isAttemptExpanded(_ attempt: ReflectionAttemptData) -> Bool {
        attemptExpandOverrides[attempt.trial] ?? (attempt.status == .running || attempt.status == .evaluating)
    }

    @ViewBuilder
    private func attemptRow(_ attempt: ReflectionAttemptData) -> some View {
        let expanded = isAttemptExpanded(attempt)
        let hasDetail = !attempt.events.isEmpty

        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasDetail else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                    attemptExpandOverrides[attempt.trial] = !expanded
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        CapabilityStatusIcon(status: attempt.status.stepEquivalent, isEvaluating: attempt.status == .evaluating, isLive: isLive)
                            .frame(width: 16, alignment: .center)

                        Text("Attempt \(attempt.trial)")
                            .font(.system(size: 13, weight: attempt.status == .running ? .medium : .regular))
                            .foregroundColor(attempt.status == .running ? theme.primaryText : theme.secondaryText)

                        if let verdict = verdictLabel(attempt.status) {
                            Text(verdict.text)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(verdict.color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(verdict.color.opacity(0.12)))
                        }

                        Spacer(minLength: 8)

                        if let meta = attemptMeta(attempt) {
                            Text(meta)
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(1)
                        }

                        if hasDetail {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(theme.tertiaryText)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                    }

                    // The evaluator's critique, in full: the reason behind a retry.
                    if let critique = attempt.critique, !critique.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("critique")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(capColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(capColor.opacity(0.12)))
                            Text(critique)
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.leading, 24)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    (attempt.status == .running || attempt.status == .evaluating)
                        ? capColor.opacity(0.07)
                        : Color.clear
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Attempt \(attempt.trial), \(Text(attempt.status.localizedTitle))"))

            if expanded && hasDetail {
                AgentTimelineView(
                    events: attempt.events,
                    isStreaming: isLive && attempt.status == .running,
                    chatFidelity: true,
                    conversationID: conversationID
                )
                .padding(.leading, 30)
                .padding(.trailing, 12)
                .padding(.bottom, 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [capColor.opacity(0.35), capColor.opacity(0.05)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(width: 2)
                        .padding(.leading, 18)
                }
                .transition(.opacity)
            }
        }
    }

    private func verdictLabel(_ status: ReflectionAttemptStatus) -> (text: String, color: Color)? {
        switch status {
        case .accepted:   return ("accepted", theme.successColor)
        case .rejected:   return ("retry", theme.warningColor)
        case .evaluating: return ("evaluating", capColor)
        case .failed:     return ("failed", theme.errorColor)
        case .cancelled:  return ("cancelled", theme.tertiaryText)
        case .running, .completed: return nil
        // No verdict to show for a status this build does not know — the attempt row itself,
        // its critique and its nested tool calls all still render.
        case .other:      return nil
        }
    }

    private func attemptMeta(_ attempt: ReflectionAttemptData) -> String? {
        var parts: [String] = []
        let toolCount = attempt.events.reduce(0) { count, event in
            if case .toolExecution = event { return count + 1 }
            return count
        }
        if toolCount > 0 { parts.append("\(toolCount) tool\(toolCount == 1 ? "" : "s")") }
        if let ms = attempt.durationMs, ms >= 100 { parts.append(DurationFormat.milliseconds(ms)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private extension ReflectionAttemptStatus {
    /// Reuses the plan-step icon vocabulary for the shared status glyph.
    var stepEquivalent: PlanStepStatus {
        switch self {
        case .running, .evaluating: return .running
        case .accepted, .completed: return .completed
        case .rejected:             return .warning
        case .failed:               return .failed
        case .cancelled:            return .cancelled
        // Carry the unrecognised value across rather than collapsing it onto a known status,
        // so the glyph is honestly "unknown" instead of silently claiming success or failure.
        case .other(let raw):       return .other(raw)
        }
    }
}

// MARK: - Shared bits

/// Status glyph shared by plan steps and reflection attempts.
private struct CapabilityStatusIcon: View {
    let status: PlanStepStatus
    var isEvaluating: Bool = false
    /// False when the card is a persisted record rather than a running one.
    /// A `.running` status survives a force-quit and is repaired only on the resume path, so a reloaded
    /// card would otherwise show a live spinner.
    var isLive: Bool = true

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dashed")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText.opacity(0.7))
        case .running:
            if !isLive {
                // Interrupted: the step never reported a terminal status and nothing is working on it.
                // A static glyph, distinct from `.cancelled`'s `slash.circle`.
                Image(systemName: "circle.dotted")
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText.opacity(0.8))
            } else if isEvaluating {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.streamingIndicator)
                    // `isActive: true` pinned this on regardless of Reduce Motion, in a file
                    // that already honours the setting in two other places.
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
            }
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.successColor.opacity(0.9))
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(theme.warningColor)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.errorColor.opacity(0.9))
        case .cancelled:
            Image(systemName: "slash.circle")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
        case .other:
            // A status written by a newer build. A neutral glyph is the honest rendering — the
            // step's title, summary and nested tool calls are all still present and correct.
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
        }
    }
}

/// Thin determinate progress capsule for the plan header.
private struct ProgressCapsule: View {
    let fraction: Double
    let tint: Color

    @Environment(\.appTheme) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.surfaceOverlayStrong.opacity(0.6))
                Capsule()
                    .fill(tint.opacity(0.85))
                    .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
                    .animation(.easeInOut(duration: 0.3), value: fraction)
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// Amber "honesty" pill for degraded runs (mirrors TerminalOutcomeChip's tone).
private struct WarningsPill: View {
    let text: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8, weight: .bold))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(theme.warningColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(theme.warningColor.opacity(0.12)))
    }
}

// MARK: - Previews

#if DEBUG
struct CapabilityProgressCards_Previews: PreviewProvider {

    static var livePlan: PlanRunData {
        PlanRunData(
            phase: .executing,
            steps: [
                PlanStepData(
                    id: "step_1", title: "Create /tmp/devgentic_test",
                    status: .completed, summary: "Successfully created directory", durationMs: 4200,
                    events: [
                        .toolExecution(ToolExecutionData(
                            id: UUID(), name: "create_folder", params: "{\"path\":\"/tmp/devgentic_test\"}",
                            output: "Successfully created directory: /tmp/devgentic_test",
                            isSuccess: true, durationMs: 180, isExecuting: false
                        ))
                    ]
                ),
                PlanStepData(
                    id: "step_2", title: "Write notes.txt with \"alpha test\"",
                    status: .running,
                    events: [
                        .reasoning(id: UUID(), text: "The user wants \"alpha test\" written to notes.txt — I'll use write_file."),
                        .toolExecution(ToolExecutionData(
                            id: UUID(), name: "write_file", params: "{\"path\":\"/tmp/devgentic_test/notes.txt\"}",
                            output: nil, isSuccess: nil, isExecuting: true
                        ))
                    ]
                ),
                PlanStepData(id: "step_3", title: "Write log.txt with \"run one\""),
                PlanStepData(id: "step_4", title: "List folder contents and report sizes")
            ],
            startedAt: Date().addingTimeInterval(-72)
        )
    }

    static var finishedDegradedPlan: PlanRunData {
        PlanRunData(
            phase: .finished,
            steps: [
                PlanStepData(id: "step_1", title: "Create folder", status: .completed, durationMs: 4000),
                PlanStepData(id: "step_2", title: "Write notes.txt", status: .completed, durationMs: 6100),
                PlanStepData(id: "step_3", title: "Write log.txt", status: .warning,
                             summary: "Ended early: repetitive tool loop", durationMs: 30800),
                PlanStepData(id: "step_4", title: "List folder contents", status: .completed, durationMs: 2300)
            ],
            outcome: .completedWithWarnings,
            startedAt: Date().addingTimeInterval(-144),
            finishedAt: Date()
        )
    }

    static var reflection: ReflectionRunData {
        ReflectionRunData(
            maxTrials: 3,
            attempts: [
                ReflectionAttemptData(
                    trial: 1, status: .rejected,
                    critique: "Used a relative path — the directory it needed to inspect was never found.",
                    durationMs: 31000,
                    events: [
                        .toolExecution(ToolExecutionData(
                            id: UUID(), name: "list_directory", params: "{\"path\":\"devgentic_test\"}",
                            output: "Error: no such directory", isSuccess: false,
                            failureCategory: .executionThrew, isExecuting: false
                        ))
                    ]
                ),
                ReflectionAttemptData(
                    trial: 2, status: .accepted, durationMs: 22000,
                    events: [
                        .toolExecution(ToolExecutionData(
                            id: UUID(), name: "list_directory", params: "{\"path\":\"/tmp/devgentic_test\"}",
                            output: "notes.txt (10 B), log.txt (7 B)", isSuccess: true, isExecuting: false
                        ))
                    ]
                )
            ],
            acceptedTrial: 2,
            outcome: .completed,
            startedAt: Date().addingTimeInterval(-53),
            finishedAt: Date()
        )
    }

    static var previews: some View {
        VStack(alignment: .leading, spacing: 16) {
            PlanProgressCard(data: livePlan, isStreaming: true)
            PlanProgressCard(data: finishedDegradedPlan, isStreaming: false)
            ReflectionAttemptsCard(data: reflection, isStreaming: false)
        }
        .padding(24)
        .frame(width: 640)
        .background(Color.black.opacity(0.9))
    }
}
#endif

// MARK: - Localized status names (audit C2)

// Declared here, not on the enums: they live in the Foundation-only `ChatMessage.swift` and are
// `Codable`. A `LocalizedStringKey` there would pull the view layer into the persistence model.

extension PlanStepStatus {
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .pending:   return "Pending"
        case .running:   return "Running"
        case .completed: return "Completed"
        case .warning:   return "Completed with warnings"
        case .failed:    return "Failed"
        case .cancelled: return "Cancelled"
        // Show the raw value rather than an invented label — it is the only truthful thing
        // this build knows about the status, and it is more useful than "Unknown".
        case .other(let raw): return LocalizedStringKey(raw)
        }
    }
}

extension ReflectionAttemptStatus {
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .running:    return "Running"
        case .evaluating: return "Evaluating"
        case .rejected:   return "Retrying"
        case .accepted:   return "Accepted"
        case .completed:  return "Completed"
        case .failed:     return "Failed"
        case .cancelled:  return "Cancelled"
        case .other(let raw): return LocalizedStringKey(raw)
        }
    }
}

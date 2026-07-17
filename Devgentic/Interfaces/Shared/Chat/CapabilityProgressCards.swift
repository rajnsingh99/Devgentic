//
//  CapabilityProgressCards.swift
//  Devgentic
//
//  Structured progress cards for agent capabilities:
//    - PlanProgressCard: a Plan & Execute run as a checklist — step rows with live
//      statuses, each expanding into its own nested timeline. The running step is
//      auto-expanded; completed steps collapse to one line; a finished card folds
//      to a one-line receipt.
//    - ReflectionAttemptsCard: a Reflexion run as attempt rows with the evaluator's
//      verdict and full critique, each expanding into its own nested timeline.
//
//  Both render `TimelineEvent.planExecution` / `.reflectionRun` (updated in place by
//  CapabilityCardRouter while streaming) and reuse AgentTimelineView for the nested
//  event lists, so tool rows / reasoning rows look identical at every nesting level.
//

import SwiftUI

// MARK: - Plan Progress Card

struct PlanProgressCard: View {
    let data: PlanRunData
    var isStreaming: Bool = false

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// nil = automatic (expanded while unfinished, receipt when finished); user taps override.
    @State private var cardExpandedOverride: Bool? = nil
    /// Per-step user toggles; absent = automatic (the running step is expanded).
    @State private var stepExpandOverrides: [String: Bool] = [:]

    private var capColor: Color { theme.capabilityColor(for: .planning) }

    /// Live = the run is still producing events. A persisted card left unfinished by a
    /// force-quit is NOT live (isStreaming false on reload) — it renders frozen, and the
    /// InterruptedRunChip below the bubble explains why.
    private var isLive: Bool { isStreaming && data.phase != .finished }

    private var isCardExpanded: Bool { cardExpandedOverride ?? (data.phase != .finished) }

    private var settledCount: Int {
        data.steps.filter { $0.status != .pending && $0.status != .running }.count
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
        .accessibilityLabel("Plan: \(headerStatusText)")
    }

    // MARK: Header

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

                if data.phase == .finished && data.hasDegradedSteps {
                    WarningsPill(text: degradedPillText)
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
        .accessibilityLabel(isCardExpanded ? "Collapse plan" : "Expand plan")
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

    private var degradedPillText: String {
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

    @ViewBuilder
    private func stepRow(_ step: PlanStepData, index: Int) -> some View {
        let expanded = isStepExpanded(step)
        let hasDetail = !step.events.isEmpty || (step.summary?.isEmpty == false)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasDetail else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                    stepExpandOverrides[step.id] = !expanded
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CapabilityStatusIcon(status: step.status)
                        .frame(width: 16, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.system(size: 13, weight: step.status == .running ? .medium : .regular))
                            .foregroundColor(titleColor(for: step.status))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        // Failure / early-stop reason at a glance — expanding shouldn't
                        // be required to learn WHY a step went amber or red.
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
            .accessibilityLabel("Step \(index + 1): \(step.title), \(step.status.rawValue)")

            if expanded && hasDetail {
                VStack(alignment: .leading, spacing: 6) {
                    if !step.events.isEmpty {
                        AgentTimelineView(
                            events: step.events,
                            isStreaming: isLive && step.status == .running,
                            chatFidelity: true
                        )
                    }
                    // The subtask's own closing summary (its intermediate answer) —
                    // shown after the events, muted, only where it adds signal.
                    if step.status == .completed, let summary = step.summary,
                       !summary.isEmpty, !summary.hasPrefix("Completed (") {
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
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
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
        .accessibilityLabel(isCardExpanded ? "Collapse attempts" : "Expand attempts")
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
                        CapabilityStatusIcon(status: attempt.status.stepEquivalent, isEvaluating: attempt.status == .evaluating)
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

                    // The evaluator's critique — the WHY behind a retry, full text.
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
            .accessibilityLabel("Attempt \(attempt.trial), \(attempt.status.rawValue)")

            if expanded && hasDetail {
                AgentTimelineView(
                    events: attempt.events,
                    isStreaming: isLive && attempt.status == .running,
                    chatFidelity: true
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
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
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
        }
    }
}

// MARK: - Shared bits

/// Status glyph shared by plan steps and reflection attempts.
private struct CapabilityStatusIcon: View {
    let status: PlanStepStatus
    var isEvaluating: Bool = false

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dashed")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText.opacity(0.7))
        case .running:
            if isEvaluating {
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

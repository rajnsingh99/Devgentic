// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowExecutionTimelineView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// A vertical execution timeline: run header, status spine, and one row per node with the selected row expanded inline.
/// The binding pins on manual taps; `nil` selects the Final Outcome, the last step.
struct WorkflowExecutionTimelineView: View {
    let displayData: WorkflowRunDisplayData
    @Binding var selectedNodeID: UUID?
    let awaitingNodeIDs: Set<UUID>
    let onAwaitingTap: () -> Void
    /// Re-runs this run's original input through the normal send path. Nil (or a live run) hides
    /// the button.
    var onRerun: (() -> Void)? = nil

    /// Conversation this run belongs to; the per-node Skip toggle keys its store on it. `nil` hides the button.
    /// Also passed to each `AgentTimelineView` so a delayed "Open in viewer" is dropped after a conversation switch.
    var conversationID: UUID? = nil
    /// True while another send/stream is in flight; the re-run pill stays visible but disabled with a tooltip.
    var rerunBlocked: Bool = false

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var runningPulse = false
    @State private var hoveredRowKey: AnyHashable?

    /// Anchor id for the Final Outcome row inside the ScrollViewReader.
    private static let finalOutcomeAnchor = "timeline-final-outcome"

    /// The Final Outcome row's single source for its visible tag and its VoiceOver label.
    /// Pure and `nonisolated static` so it is testable without a hosted view.
    nonisolated static func finalOutcomeTagLabel(
        status: WorkflowRunDisplayData.NodeDisplayData.NodeStatus,
        isCancelled: Bool,
        isUnknown: Bool,
        isCompletedWithWarnings: Bool = false,
        isRunning: Bool,
        settledCount: Int,
        totalNodeCount: Int
    ) -> String {
        if status == .pending, isRunning {
            return "Awaiting inputs · \(settledCount)/\(max(totalNodeCount, 1))"
        }
        if isCancelled { return String(localized: "Cancelled") }
        if isUnknown { return String(localized: "Unknown") }
        // `status` is a node-level vocabulary with no value for this run-level case, so the label override is applied here.
        if isCompletedWithWarnings { return String(localized: "Completed with warnings") }
        return status.label
    }

    /// Whether the timeline scrolls to `selection` for this `.onChange` delivery.
    /// The initial pass scrolls only for an explicit node selection; `nil` is the resting Final Outcome row and must not
    /// scroll a freshly opened run past its own timeline. Pure so it is testable.
    nonisolated static func shouldScrollToSelection(_ selection: UUID?, isInitial: Bool) -> Bool {
        isInitial ? selection != nil : true
    }

    /// Readable measure for prose inside expanded panels — full-width error/output
    /// paragraphs at ~1000pt are hard to scan.
    private static let proseMaxWidth: CGFloat = 760

    // MARK: - Derived run state

    // One-line delegates to `WorkflowRunDisplayData`, where the verdict logic lives so it is testable. Keep logic out.
    private var settledCount: Int { displayData.settledNodeCount }
    private var isCancelled: Bool { displayData.isCancelledRun }

    /// Counts only genuine failures: nodes that did not run (routed elsewhere, nothing to handle) or were cancelled
    /// are excluded.
    private var hasFailure: Bool { displayData.hasGenuineFailure }

    /// A node that never executed, rendered as a neutral "Not run" rather than as a failure.
    /// Reads the `.skipped` status; the legacy branch covers records that predate it.
    private func isNotRun(_ node: WorkflowRunDisplayData.NodeDisplayData) -> Bool {
        displayData.nodeDidNotRun(node)
    }

    /// The status word for a skipped node, shared by the visible tag and the VoiceOver label.
    private func skipTagLabel(for node: WorkflowRunDisplayData.NodeDisplayData) -> String {
        displayData.skipTagLabel(for: node)
    }

    /// What to tell the user about a node that did not run.
    private func notRunMessage(for node: WorkflowRunDisplayData.NodeDisplayData) -> String {
        displayData.notRunMessage(for: node)
    }

    /// The run's aggregate status, from `WorkflowRunDisplayData.rollupOutcome`.
    private var finalOutcomeStatus: WorkflowRunDisplayData.NodeDisplayData.NodeStatus {
        displayData.rollupOutcome
    }

// The persisted-status precedence (and its regression history) lives on
    // `WorkflowRunDisplayData.pillVerdict` — the testable side of this seam.

    private var runPillColor: Color {
        switch displayData.pillVerdict {
        case .running:               return theme.accentColor
        case .cancelled:             return theme.warningColor
        case .failed:                return theme.errorColor
        case .unknown:               return theme.secondaryText
        case .completed:             return theme.successColor
        case .completedWithWarnings: return theme.warningColor
        }
    }

    private var runPillLabel: String { displayData.pillLabel }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            runHeader
            unsavedEditsDisclosure
            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 0.5)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(displayData.nodeResults.enumerated()), id: \.element.id) { _, node in
                            nodeStep(node)
                                .id(node.nodeID)
                        }
                        finalOutcomeStep
                            .id(Self.finalOutcomeAnchor)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                // `initial: true` is required: the failed-run auto-focus sets `selectedNodeID` in the same update that makes
                // `displayData` non-nil, so the view is constructed with the id in place and a change-only observer never fires.
                .onChange(of: selectedNodeID, initial: true) { oldValue, newValue in
                    // `initial: true` delivers the current value as BOTH parameters; a real change
                    // never can, because `onChange` only fires on inequality.
                    let isInitial = oldValue == newValue
                    guard Self.shouldScrollToSelection(newValue, isInitial: isInitial) else { return }
                    let target = newValue.map { AnyHashable($0) } ?? AnyHashable(Self.finalOutcomeAnchor)
                    // Unanimated on the initial pass: there is no previous offset to travel from.
                    if isInitial {
                        proxy.scrollTo(target, anchor: .top)
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: displayData.isRunning, initial: true) { _, running in
            runningPulse = false
            guard running, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                runningPulse = true
            }
        }
    }

    // MARK: - Run header (status pill + segmented progress + step counter + Re-run)

    private var runHeader: some View {
        HStack(spacing: 12) {
            // Status pill
            HStack(spacing: 6) {
                Circle()
                    .fill(runPillColor)
                    .frame(width: 7, height: 7)
                    .opacity(displayData.isRunning ? (runningPulse ? 0.4 : 1.0) : 1.0)
                Text(runPillLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(runPillColor)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(Capsule().fill(runPillColor.opacity(0.12)))

            // Segmented progress — one segment per node.
            HStack(spacing: 5) {
                ForEach(Array(displayData.nodeResults.enumerated()), id: \.element.id) { _, node in
                    let color = isNotRun(node) ? theme.secondaryText.opacity(0.35)
                              : (node.hasWarnings && node.status == .completed ? theme.warningColor
                              : segmentColor(for: node.status))
                    Capsule()
                        .fill(color)
                        .frame(height: 5)
                        .frame(maxWidth: .infinity)
                        .shadow(color: node.status == .running ? theme.accentColor.opacity(runningPulse ? 0.65 : 0.25) : Color.clear, radius: 3)
                }
            }
            .frame(maxWidth: .infinity)

            // Step counter + total time
            Text(stepCounterText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
                .fixedSize()

            if let onRerun, !displayData.isRunning {
                TactileButton(
                    title: "Re-run",
                    icon: "arrow.clockwise",
                    variant: .secondary,
                    size: .compact,
                    isDisabled: rerunBlocked
                ) {
                    onRerun()
                }
                .help(rerunBlocked
                      ? "Another run is in progress — wait for it to finish"
                      : "Run this workflow again with the same input")
                .accessibilityLabel("Re-run workflow")
                .accessibilityHint(rerunBlocked ? Text("Disabled while another run is in progress") : Text(""))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Notes that the run executed the last-saved graph while the canvas held unsaved edits.
    /// Informational only (amber, never recolours the status pill); shown for live runs because the flag is not persisted.
    @ViewBuilder
    private var unsavedEditsDisclosure: some View {
        if displayData.ranWithUnsavedCanvasEdits {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Text(WorkflowRunEditDisclosure.userFacingReason)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(WorkflowRunEditDisclosure.userFacingReason))
        }
    }

    /// Mid-flight: "step X of N · time". Terminal runs phrase the outcome instead — a completed
    /// counter ("step 2 of 2") on a FAILED run would imply the run got through everything.
    private var stepCounterText: String { displayData.stepCounterDescription }

    private func segmentColor(for status: WorkflowRunDisplayData.NodeDisplayData.NodeStatus) -> Color {
        switch status {
        case .completed:          return theme.successColor
        case .failed:             return theme.errorColor
        case .skipped:            return theme.secondaryText.opacity(0.4)
        case .cancelled:          return theme.warningColor
        case .running:            return theme.accentColor.opacity(runningPulse ? 0.9 : 0.45)
        case .pending:            return theme.surfaceOverlayStrong
        case .unknown:            return theme.secondaryText.opacity(0.6)
        }
    }

    /// Which override a node row's colour takes, returned as a role so the rule is testable without a `Theme`.
    /// The awaiting override is applied last at the call site (see `rowColor`); header segments use their own palette.
    enum NodeColorRole: Equatable {
        /// Never executed — muted, never the failure red.
        case notRun
        /// Completed on a best-effort answer (circuit breaker / iteration budget) — amber, matching
        /// the "Completed · warnings" tag.
        case degraded
        /// The node's own status colour.
        case status
    }

    nonisolated static func nodeColorRole(
        status: WorkflowRunDisplayData.NodeDisplayData.NodeStatus,
        hasWarnings: Bool,
        isNotRun: Bool
    ) -> NodeColorRole {
        if isNotRun { return .notRun }
        // Requires `.completed`: an `.unknown` node from a newer build must not be shown as a degraded completion.
        if hasWarnings, status == .completed { return .degraded }
        return .status
    }

    private func nodeColor(for role: NodeColorRole,
                           status: WorkflowRunDisplayData.NodeDisplayData.NodeStatus) -> Color {
        switch role {
        case .notRun:   return theme.secondaryText.opacity(0.6)
        case .degraded: return theme.warningColor
        case .status:   return status.color(theme)
        }
    }

    // MARK: - Node step row

    @ViewBuilder
    private func nodeStep(_ node: WorkflowRunDisplayData.NodeDisplayData) -> some View {
        let isSelected = selectedNodeID == node.nodeID
        let isAwaiting = awaitingNodeIDs.contains(node.nodeID)
        let notRun = isNotRun(node)
        // The one decision for which override this row's colour takes; see `nodeColorRole`.
        let statusColor = nodeColor(
            for: Self.nodeColorRole(status: node.status, hasWarnings: node.hasWarnings, isNotRun: notRun),
            status: node.status)
        // The row's colour including the awaiting override, shared by the spine and the expanded panel's edge.
        let rowColor = isAwaiting ? theme.warningColor : statusColor
        let isHovered = hoveredRowKey == AnyHashable(node.nodeID)

        HStack(alignment: .top, spacing: 14) {
            spineColumn(color: rowColor,
                        isActive: node.status == .running || isAwaiting,
                        isTerminalFill: !notRun && (node.status == .completed || node.status == .failed),
                        isLast: false)

            VStack(alignment: .leading, spacing: 4) {
                stepHeaderRow(
                    name: node.profileName,
                    nameColor: (node.status == .pending && !isAwaiting) || notRun ? theme.secondaryText : theme.primaryText,
                    // [XUI-10] ONE source for the word, shared with the accessibility label below.
                    tagLabel: displayData.nodeTagLabel(for: node, isAwaiting: isAwaiting),
                    tagColor: isAwaiting ? theme.warningColor : (node.status == .pending || notRun ? theme.secondaryText : statusColor),
                    tagIcon: isAwaiting ? "hand.raised.fill" : nil,
                    tagAction: isAwaiting ? onAwaitingTap : nil,
                    duration: node.status == .pending ? nil : node.duration,
                    showsChevron: isHovered && !isSelected
                )

                // Collapsed one-line preview: pre-terminal rows show their incoming task/input,
                // terminal unselected rows show a snippet of their output.
                if !isSelected, let preview = Self.collapsedPreview(for: node) {
                    Text(preview)
                        .font(.system(.caption))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }

                // Per-node Skip toggle for pending profile nodes on a live run. Toggles freely until dispatch consumes the request,
                // so there is no confirmation; reading the store in `body` flips the row back on an engine-side consume.
                if node.status == .pending, node.isUserSkippable, displayData.isRunning,
                   let conversationID {
                    let isRequested = WorkflowNodeSkipStore.shared.isRequested(nodeID: node.nodeID, conversationID: conversationID)
                    Button {
                        WorkflowNodeSkipStore.shared.toggle(nodeID: node.nodeID, conversationID: conversationID)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isRequested ? "arrow.uturn.backward" : "forward.end")
                                .font(.system(size: 9, weight: .semibold))
                            Text(isRequested ? "Undo skip" : "Skip")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(isRequested ? theme.warningColor : theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.surfaceOverlay))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help(isRequested
                          ? "Cancel the skip — this node will run normally"
                          : "Skip this node when the run reaches it — its input is passed downstream unchanged (downstream gets the node's input, not its output)")
                    .accessibilityLabel(isRequested ? "Undo skip for \(node.profileName)" : "Skip \(node.profileName)")
                }

                // Skip for a running bot/agent node of a live run. Not undoable: the button becomes a disabled "Skipping" until the
                // engine's event lands. Sub-workflow rows never qualify (`isRunningSkippable` excludes them).
                if node.status == .running, node.isRunningSkippable, displayData.isRunning,
                   let conversationID {
                    let inFlight = WorkflowNodeSkipStore.shared.runningSkipInFlight(nodeID: node.nodeID, conversationID: conversationID)
                    Button {
                        WorkflowNodeSkipStore.shared.requestRunningSkip(nodeID: node.nodeID, conversationID: conversationID)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "forward.end")
                                .font(.system(size: 9, weight: .semibold))
                            Text(inFlight ? "Skipping" : "Skip")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(inFlight ? theme.tertiaryText : theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.surfaceOverlay))
                    }
                    .buttonStyle(.plain)
                    .disabled(inFlight)
                    .pointingHandCursor(enabled: !inFlight)
                    .help(inFlight
                          ? "Skip is in progress — the node's in-flight work is being torn down"
                          : "Skip this node NOW — its in-flight work is discarded and its input is passed downstream unchanged (not undoable; downstream gets the node's input, not its output)")
                    .accessibilityLabel(inFlight ? "Skipping \(node.profileName)" : "Skip \(node.profileName) now")
                }

                if isSelected {
                    expandedContent(for: node, edgeColor: rowColor)
                        .padding(.top, 6)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 18)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered && !isSelected ? theme.surfaceOverlay.opacity(0.6) : Color.clear)
                .padding(.horizontal, -8)
                .padding(.top, -4)
                .padding(.bottom, 8)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredRowKey = hovering ? AnyHashable(node.nodeID) : nil
            }
        }
        .onTapGesture { selectedNodeID = node.nodeID }
        .pointingHandCursor()
        .accessibilityAddTraits(.isButton)
        // Reads `nodeTagLabel` so the VoiceOver label always agrees with the visible tag.
        .accessibilityLabel("\(node.profileName), \(displayData.nodeTagLabel(for: node, isAwaiting: isAwaiting))")
        .accessibilityHint(isSelected ? "Selected step" : "Show step details")
        .accessibilityAction { selectedNodeID = node.nodeID }
    }

    // Why: bounds what reaches `Text`, not this function: the trim is linear, but laying out huge strings per body pass is not
    /// Bounds the one-line collapsed preview, since `detail` and `input` can be a node's entire output.
    /// `limit` (200 characters) sits above what the single caption line can show at the timeline's max width.
    nonisolated private static func boundedPreview(_ text: String, limit: Int = 200) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // `index(offsetBy:limitedBy:)` rather than `count > limit`: counting graphemes over a
        // 128 KB detail is itself the O(n) walk this row is about. This one stops at the cap.
        guard let cut = trimmed.index(trimmed.startIndex, offsetBy: limit,
                                      limitedBy: trimmed.endIndex),
              cut < trimmed.endIndex else { return trimmed }
        return String(trimmed[..<cut]) + "…"
    }

    nonisolated static func collapsedPreview(for node: WorkflowRunDisplayData.NodeDisplayData) -> String? {
        switch node.status {
        case .pending, .running:
            // `input` concatenates every upstream node's entire output, so this is the larger arm; see `boundedPreview`.
            return boundedPreview(node.input ?? "")
        case .skipped:
            // Shows the skip reason, not the input, so legacy records do not print the raw upstream-failure sentence
            // under a "Not run" tag.
            return boundedPreview(node.detail)
        // `.unknown` is a FINISHED node (newer-build status) — its detail is real; show it like
        // any settled node rather than the input preview a pending node gets.
        case .completed, .failed, .cancelled, .unknown:
            return boundedPreview(node.detail)
        }
    }

    // MARK: - Final Outcome step

    @ViewBuilder
    private var finalOutcomeStep: some View {
        let isSelected = selectedNodeID == nil
        let status = finalOutcomeStatus
        // Cancelled and unknown runs override the label here rather than in `finalOutcomeStatus`, which the spine and the
        // pending/awaiting logic also read: `NodeStatus` has no cancelled value and a newer-build record derives `.completed`.
        let isUnknown = displayData.hasUnknownPersistedStatus
        // The run's softened verdict is layered on here; `status` still reads `.failed` underneath.
        let isCompletedWithWarnings = displayData.pillVerdict == .completedWithWarnings
        let statusColor = isCancelled ? theme.warningColor
            : isUnknown ? theme.secondaryText
            : isCompletedWithWarnings ? theme.warningColor
            : status.color(theme)
        // One shared computation drives both the visible tag and what VoiceOver speaks; see `finalOutcomeTagLabel`.
        let visibleTagLabel = Self.finalOutcomeTagLabel(
            status: status, isCancelled: isCancelled, isUnknown: isUnknown,
            isCompletedWithWarnings: isCompletedWithWarnings,
            isRunning: displayData.isRunning, settledCount: settledCount,
            totalNodeCount: displayData.nodeResults.count)
        let isHovered = hoveredRowKey == AnyHashable(Self.finalOutcomeAnchor)

        HStack(alignment: .top, spacing: 14) {
            spineColumn(color: statusColor,
                        isActive: status == .running,
                        isTerminalFill: status == .completed || status == .failed,
                        isLast: true)

            VStack(alignment: .leading, spacing: 4) {
                stepHeaderRow(
                    name: "Final Outcome",
                    nameColor: status == .pending ? theme.secondaryText : theme.primaryText,
                    tagLabel: visibleTagLabel,
                    tagColor: status == .pending ? theme.secondaryText : statusColor,
                    tagIcon: nil,
                    tagAction: nil,
                    duration: displayData.isRunning ? nil : displayData.duration,
                    showsChevron: isHovered && !isSelected
                )

                if isSelected {
                    // Uses `statusColor`, not `status`, so the panel edge follows this row's whole override chain.
                    finalOutcomeExpanded(status: status, edgeColor: statusColor)
                        .padding(.top, 6)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered && !isSelected ? theme.surfaceOverlay.opacity(0.6) : Color.clear)
                .padding(.horizontal, -8)
                .padding(.vertical, -4)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredRowKey = hovering ? AnyHashable(Self.finalOutcomeAnchor) : nil
            }
        }
        .onTapGesture { selectedNodeID = nil }
        .pointingHandCursor()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Final Outcome, \(visibleTagLabel)")
        .accessibilityHint(isSelected ? "Selected" : "Show final output")
        .accessibilityAction { selectedNodeID = nil }
    }

    // MARK: - Shared row pieces

    /// The left status spine: a state dot with the connecting line below it.
    private func spineColumn(color: Color, isActive: Bool, isTerminalFill: Bool, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            ZStack {
                if isActive {
                    Circle()
                        .stroke(color.opacity(0.45), lineWidth: 2)
                        .scaleEffect(runningPulse ? 1.6 : 1.0)
                        .opacity(runningPulse ? 0.0 : 1.0)
                        .frame(width: 12, height: 12)
                }

                Circle()
                    .fill(isTerminalFill ? color : theme.primaryBackground)
                    .frame(width: 12, height: 12)
                    .shadow(color: isActive ? color.opacity(0.65) : .clear, radius: 4)
                
                Circle()
                    .stroke(color, lineWidth: 2)
                    .frame(width: 12, height: 12)
            }
            .padding(.top, 2)

            if !isLast {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.6), theme.dividerColor.opacity(0.35)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .padding(.top, 4)
            }
        }
        .frame(width: 14)
    }

    private func stepHeaderRow(
        name: String,
        nameColor: Color,
        tagLabel: String,
        tagColor: Color,
        tagIcon: String?,
        tagAction: (() -> Void)?,
        duration: TimeInterval?,
        showsChevron: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(theme.fontSubheadline.weight(.semibold))
                .foregroundColor(nameColor)
                .lineLimit(1)

            // Attaches the gesture only when there is something to invoke: a descendant tap gesture beats the row's selection tap,
            // so an unconditional one would make the pill a dead zone. The Final Outcome row passes `tagAction: nil`.
            if let tagAction {
                statusTag(label: tagLabel, color: tagColor, icon: tagIcon)
                    .onTapGesture { tagAction() }
                    .pointingHandCursor()
                    .help(Text("Show me where to respond"))
            } else {
                statusTag(label: tagLabel, color: tagColor, icon: tagIcon)
            }

            Spacer(minLength: 6)

            if let duration, duration > 0 {
                Text(DurationFormat.seconds(duration))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }

            // Expand affordance — rows are clickable; hint it on hover.
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .opacity(showsChevron ? 1 : 0)
        }
    }

    private func statusTag(label: String, color: Color, icon: String?) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
        .overlay(
            Capsule()
                .stroke(color.opacity(0.25), lineWidth: 0.5)
        )
        .lineLimit(1)
        .fixedSize()
    }

    // MARK: - Error text helpers

    /// Splits a node's failure detail into the error body and the folded-in remediation
    /// (`"…\n\n💡 suggestion"`, appended by WorkflowExecutionState.handleNodeFailed) so the
    /// suggestion renders as its own styled line instead of one red blob.
    private func splitDetail(_ detail: String) -> (body: String, suggestion: String?) {
        guard let range = detail.range(of: "\n\n💡 ") else {
            return (detail.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let body = String(detail[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestion = String(detail[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, suggestion.isEmpty ? nil : suggestion)
    }

    /// Memo key for `errorBodyIsDuplicated`. `traceLength` and `traceTailID` invalidate the cached answer when the trace
    /// changes, including across re-runs that reuse the same persistent layout `nodeID`. Event content is not keyed.
    private struct DuplicationKey: Hashable {
        let nodeID: UUID
        let body: String
        let traceLength: Int
        /// The last event's id — nil for an empty trace. See the run-scoping note above.
        let traceTailID: UUID?
    }

    /// Bounded because nothing evicts on run or conversation change; 64 is far more than the
    /// selected-and-failed nodes one sitting produces, and dropping the map costs exactly one
    /// recomputation on the next body pass.
    @MainActor private static var duplicationCache: [DuplicationKey: Bool] = [:]

    /// Memoised `isDuplicatedInTimeline`, which is expensive and would otherwise run on every body pass, hover included.
    /// MainActor-isolated: the only callers are view bodies.
    @MainActor
    static func errorBodyIsDuplicated(nodeID: UUID, body: String, events: [TimelineEvent]) -> Bool {
        let key = DuplicationKey(nodeID: nodeID, body: body, traceLength: events.count,
                                 traceTailID: events.last?.id)
        if let cached = duplicationCache[key] { return cached }
        let answer = isDuplicatedInTimeline(body, events: events)
        if duplicationCache.count >= 64 { duplicationCache.removeAll(keepingCapacity: true) }
        duplicationCache[key] = answer
        return answer
    }

    /// True when the error body is already told by the tail of the node's timeline (e.g. the LOOP GUARD card).
    /// Call `errorBodyIsDuplicated` from view code, not this raw predicate.
    nonisolated static func isDuplicatedInTimeline(_ body: String, events: [TimelineEvent]) -> Bool {
        func normalize(_ s: String) -> String {
            s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        // Strip the classifier's prefix ("Model error from X: …") to compare the core sentence.
        var core = body
        if let colon = core.range(of: ": "), core.lowercased().hasPrefix("model error from") {
            core = String(core[colon.upperBound...])
        }
        let needle = normalize(core)
        guard needle.count >= 24 else { return false }

        for event in events.suffix(4) {
            let text: String?
            switch event {
            case .warning(_, _, let t):        text = t
            case .thought(_, let t):           text = t
            case .reasoning(_, let t):         text = t
            case .toolExecution(let data):     text = data.output
            default:                           text = nil
            }
            guard let text else { continue }
            let hay = normalize(text)
            if hay.contains(needle) || (needle.count > hay.count && hay.count >= 24 && needle.contains(hay)) {
                return true
            }
        }
        return false
    }

    // MARK: - Expanded step content

    /// Inline detail for the selected node (agent timeline + markdown output); the outer timeline scroll owns scrolling.
    /// - Parameter edgeColor: the row's already-overridden colour; do not re-derive it from `node.status`.
    @ViewBuilder
    private func expandedContent(for node: WorkflowRunDisplayData.NodeDisplayData,
                                 edgeColor: Color) -> some View {
        detailContainer(edgeColor: edgeColor) {
            // Only a node that never started gets the bare one-line treatment: a node skipped mid-flight has a captured trace
            // that must still render.
            if isNotRun(node), !displayData.nodeRanBeforeSkip(node) {
                // Shows the node's own reason, never a hardcoded "upstream failed" sentence.
                inlineStatusLine(message: notRunMessage(for: node), showsSpinner: false)
            } else {
                switch node.status {
                case .running:
                    if node.supportsTimeline {
                        AgentTimelineView(
                            events: node.nodeTimeline,
                            isStreaming: node.isStreaming,
                            chatFidelity: true,
                            streamingStartedAt: displayData.timestamp,
                            conversationID: conversationID
                        )
                    } else {
                        inlineStatusLine(message: "Generating output…", showsSpinner: true)
                    }

                case .pending:
                    inlineStatusLine(message: "Waiting for execution", showsSpinner: false)

                // Why: the arm routing is unreachable by unit tests (`nodeShowsCapturedTrace` is the testable half); verify edits on device
                // A node skipped mid-flight or cancelled while executing has a trace, so these arms render it above the reason line.
                // No `finalContentText`: the detail is the skip/cancel reason, not the model's answer.
                case .skipped:
                    VStack(alignment: .leading, spacing: 14) {
                        if displayData.nodeShowsCapturedTrace(node) {
                            AgentTimelineView(
                                events: node.nodeTimeline,
                                isStreaming: false,
                                chatFidelity: true,
                                conversationID: conversationID,
                                terminalOutcome: .cancelled,
                                isInterrupted: true
                            )
                        }
                        inlineStatusLine(message: notRunMessage(for: node), showsSpinner: false)
                    }

                case .cancelled:
                    VStack(alignment: .leading, spacing: 14) {
                        if displayData.nodeShowsCapturedTrace(node) {
                            AgentTimelineView(
                                events: node.nodeTimeline,
                                isStreaming: false,
                                chatFidelity: true,
                                conversationID: conversationID,
                                terminalOutcome: .cancelled,
                                isInterrupted: true
                            )
                        }
                        inlineStatusLine(message: String(localized: "Cancelled before this node finished."), showsSpinner: false)
                    }

                // `.unknown` routes with the settled arms: the node finished under a newer build, so its full detail must render.
                case .completed, .failed, .unknown:
                    let isError = node.status == .failed
                    let (errorBody, suggestion) = isError ? splitDetail(node.detail) : (node.detail, nil)
                    // Goes through the memo, not the raw predicate, because this line runs on every body pass.
                    let bodyIsDuplicated = isError
                        && node.supportsTimeline
                        && Self.errorBodyIsDuplicated(nodeID: node.nodeID, body: errorBody,
                                                      events: node.nodeTimeline)

                    VStack(alignment: .leading, spacing: 14) {
                        if !node.detail.isEmpty {
                            HStack {
                                Spacer()
                                TimelineCopyChip(target: node.detail)
                            }
                        }

                        if displayData.nodeShowsCapturedTrace(node) {
                            AgentTimelineView(
                                events: node.nodeTimeline,
                                isStreaming: false,
                                chatFidelity: true,
                                finalContentText: node.detail,
                                conversationID: conversationID,
                                terminalOutcome: isError ? .failed : .completed,
                                isInterrupted: false
                            )
                        }

                        if isError {
                            // Error body at footnote scale; skipped when the trace already ends with the same sentence.
                            if !errorBody.isEmpty && !bodyIsDuplicated {
                                Text(errorBody)
                                    .font(theme.fontFootnote)
                                    .foregroundColor(theme.errorColor)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: Self.proseMaxWidth, alignment: .leading)
                            }
                            if let suggestion {
                                suggestionLine(suggestion)
                            }
                        } else if !node.detail.isEmpty {
                            WorkflowMarkdownView(text: node.detail)
                                .frame(maxWidth: Self.proseMaxWidth, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    /// - Parameter edgeColor: the row's already-overridden colour; do not re-derive it from `status`,
    /// which is deliberately un-overridden.
    private func finalOutcomeExpanded(
        status: WorkflowRunDisplayData.NodeDisplayData.NodeStatus,
        edgeColor: Color
    ) -> some View {
        // Which panel shows is decided by `WorkflowRunDisplayData.finalOutcomePanel`; this switch only renders.
        detailContainer(edgeColor: edgeColor) {
            switch displayData.finalOutcomePanel(rowStatus: status) {
            case .waiting:
                inlineStatusLine(message: "Waiting for execution", showsSpinner: false)
            case .progress(let synthesising):
                inlineStatusLine(
                    message: synthesising ? "Synthesising final output…" : "Awaiting node outputs…",
                    showsSpinner: synthesising
                )
            case .error(let error):
                let (errorBody, suggestion) = splitDetail(error)
                VStack(alignment: .leading, spacing: 10) {
                    Text(errorBody)
                        .font(theme.fontFootnote)
                        .foregroundColor(theme.errorColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: Self.proseMaxWidth, alignment: .leading)
                    if let suggestion {
                        suggestionLine(suggestion)
                    }
                }
            case .reason(let reason):
                // Neutral register, matching the history card's `.reason` arm: no warning glyph,
                // no error tint. A Stop is not a fault.
                HStack(spacing: 8) {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                    Text(reason)
                        .font(theme.fontFootnote)
                        .foregroundColor(theme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: Self.proseMaxWidth, alignment: .leading)
                }
            case .output(let finalOutput):
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Spacer()
                        TimelineCopyChip(target: finalOutput)
                    }
                    WorkflowMarkdownView(text: finalOutput)
                        .frame(maxWidth: Self.proseMaxWidth, alignment: .leading)
                }
            }
        }
    }

    /// Rounded container with a colored leading edge — the "this is the focused step" panel.
    private func detailContainer<Content: View>(edgeColor: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [edgeColor.opacity(0.95), edgeColor.opacity(0.2)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 3)
                .padding(.vertical, 8)
                .padding(.leading, 8)

            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(theme.controlBackground.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.surfaceOverlayStrong, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 3, x: 0, y: 1)
    }

    /// Remediation hint styled as its own quiet line (matches the chat error card's 💡 treatment).
    private func suggestionLine(_ suggestion: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lightbulb")
                .font(.system(size: 11))
                .foregroundColor(theme.warningColor)
                .padding(.top, 1)
            Text(suggestion)
                .font(.system(.caption))
                .foregroundColor(theme.secondaryText)
                .textSelection(.enabled)
        }
        .frame(maxWidth: Self.proseMaxWidth, alignment: .leading)
    }

    private func inlineStatusLine(message: String, showsSpinner: Bool) -> some View {
        HStack(spacing: 8) {
            if showsSpinner {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "hourglass")
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            }
            Text(message)
                .font(.system(.caption))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Copy chip

/// The timeline's copy affordance.
private struct TimelineCopyChip: View {
    let target: String
    @Environment(\.appTheme) private var theme
    @State private var isCopied = false
    @State private var isHovering = false

    var body: some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(target, forType: .string)
            isCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isCopied = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .bold))
                Text(isCopied ? "Copied" : "Copy")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(isCopied ? theme.successColor : theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isHovering ? theme.surfaceOverlayStrong : theme.surfaceOverlay.opacity(0.4))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isHovering ? theme.accentColor.opacity(0.3) : theme.dividerColor.opacity(0.2), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityLabel(isCopied ? "Copied" : "Copy output")
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
    }
}

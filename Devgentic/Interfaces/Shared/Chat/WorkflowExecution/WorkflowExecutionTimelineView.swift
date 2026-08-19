//
//  WorkflowExecutionTimelineView.swift
//  Devgentic
//
//  [UI-REDESIGN PROTOTYPE A — "Execution timeline"] A single vertical timeline that replaces the
//  horizontal card strip + separate output panel: a run header (status pill + segmented progress +
//  step counter + Re-run), a status spine down the left, one row per node with the SELECTED row's
//  content expanded inline (live tool activity for the running node, output for completed ones),
//  and the Final Outcome as the last step. Selection semantics are unchanged from the strip: the
//  binding pins on manual taps (WorkflowDedicatedView wraps it), `nil` selects the Final Outcome,
//  and the auto-follow in WorkflowDedicatedView moves the selection as execution progresses.
//
//  Short runs top-align and leave space below — intentional (standard for execution logs); the
//  content scrolls once it outgrows the viewport.
//
//  Prototype seam: rendered when `WorkflowDedicatedView.executionLayout == .timelineA`; switch back
//  to `.original` to restore the classic strip + output layout (both paths stay compiled).
//

import SwiftUI

struct WorkflowExecutionTimelineView: View {
    let displayData: WorkflowRunDisplayData
    @Binding var selectedNodeID: UUID?
    let awaitingNodeIDs: Set<UUID>
    let onAwaitingTap: () -> Void
    /// Re-runs this run's original input through the normal send path. Nil (or a live run) hides
    /// the button.
    var onRerun: (() -> Void)? = nil
    /// True while another send/stream is in flight. The pill stays VISIBLE but disabled with an
    /// honest tooltip — it used to be fully enabled during a stream and the click was dropped
    /// downstream with only a log line, which reads as a broken button (WF-UI4).
    var rerunBlocked: Bool = false

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var runningPulse = false
    @State private var hoveredRowKey: AnyHashable?

    /// Anchor id for the Final Outcome row inside the ScrollViewReader.
    private static let finalOutcomeAnchor = "timeline-final-outcome"

    /// Readable measure for prose inside expanded panels — full-width error/output
    /// paragraphs at ~1000pt are hard to scan.
    private static let proseMaxWidth: CGFloat = 760

    // MARK: - Derived run state

    // ⚠️ ALL verdict logic lives on `WorkflowRunDisplayData` (the "Run roll-up" extension) so it
    // is testable — these are one-line delegates kept only so the view reads naturally. Do not
    // grow logic back into them; that is how this surface became an untested second implementation
    // of "what happened to this run" (WF-UI5).
    private var settledCount: Int { displayData.settledNodeCount }
    private var isCancelled: Bool { displayData.isCancelledRun }

    /// ⚠️ Counts only GENUINE failures. A node that did not run — because a Condition or Gate
    /// routed the other way, or because its error handler had nothing to handle — carries
    /// `.skipped`, and nothing about it is a failure. Omitting `isNotRun` here turned the header
    /// pill red on every successful conditional run. Cancelled nodes are excluded for the same
    /// reason: the user asked for that one.
    private var hasFailure: Bool { displayData.hasGenuineFailure }

    /// A node that never executed. Rendered as a neutral "Not run" instead of the same red as the
    /// node that genuinely crashed.
    ///
    /// ⚠️ Reads the STATUS now. This used to be `status == .failed && detail.hasPrefix("Upstream
    /// dependency")` — the skip was only knowable by parsing English out of a free-text field, and
    /// three of the nine surfaces that needed the test forgot to apply it. The legacy branch below
    /// is for records written before 2026-08-15, which have no `.skipped` status to read.
    private func isNotRun(_ node: WorkflowRunDisplayData.NodeDisplayData) -> Bool {
        displayData.nodeDidNotRun(node)
    }

    /// What to tell the user about a node that did not run.
    ///
    /// The engine now writes the structural cause into `detail` via `NodeSkipReason.displayText`, so
    /// a Router that branched elsewhere says so instead of claiming an upstream failure. The
    /// fallback covers records written before 2026-08-15, whose detail is the old sentence.
    private func notRunMessage(for node: WorkflowRunDisplayData.NodeDisplayData) -> String {
        displayData.notRunMessage(for: node)
    }

    /// The ONE aggregate-status implementation. It used to be a copy-paste pair with
    /// `WorkflowFinalOutcomeCardView.aggregateStatus`, whose file had no call sites at all and was
    /// deleted on 2026-08-11 — two prior sessions had spent effort fixing accessibility and
    /// reduce-motion issues on workflow views that turned out to be unreachable.
    private var finalOutcomeStatus: WorkflowRunDisplayData.NodeDisplayData.NodeStatus {
        displayData.rollupOutcome
    }

// The persisted-status precedence (and its regression history) lives on
    // `WorkflowRunDisplayData.pillVerdict` — the testable side of this seam.

    private var runPillColor: Color {
        switch displayData.pillVerdict {
        case .running:   return theme.accentColor
        case .cancelled: return theme.warningColor
        case .failed:    return theme.errorColor
        case .unknown:   return theme.secondaryText
        case .completed: return theme.successColor
        }
    }

    private var runPillLabel: String { displayData.pillLabel }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            runHeader
            Divider().opacity(0.4)

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
                .onChange(of: selectedNodeID) { _, newValue in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(newValue.map { AnyHashable($0) } ?? AnyHashable(Self.finalOutcomeAnchor), anchor: .top)
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
                Button(action: onRerun) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Re-run")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.secondaryText.opacity(rerunBlocked ? 0.45 : 1.0))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.surfaceOverlay))
                }
                .buttonStyle(.plain)
                .disabled(rerunBlocked)
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

    // MARK: - Node step row

    @ViewBuilder
    private func nodeStep(_ node: WorkflowRunDisplayData.NodeDisplayData) -> some View {
        let isSelected = selectedNodeID == node.nodeID
        let isAwaiting = awaitingNodeIDs.contains(node.nodeID)
        let notRun = isNotRun(node)
        // Degraded success: completed on a best-effort answer → amber instead of green.
        let degraded = node.hasWarnings && node.status == .completed
        let statusColor = notRun
            ? theme.secondaryText.opacity(0.6)
            : (degraded ? theme.warningColor : node.status.color(theme))
        let isHovered = hoveredRowKey == AnyHashable(node.nodeID)

        HStack(alignment: .top, spacing: 14) {
            spineColumn(color: isAwaiting ? theme.warningColor : statusColor,
                        isActive: node.status == .running || isAwaiting,
                        isTerminalFill: !notRun && (node.status == .completed || node.status == .failed),
                        isLast: false)

            VStack(alignment: .leading, spacing: 4) {
                stepHeaderRow(
                    name: node.profileName,
                    nameColor: (node.status == .pending && !isAwaiting) || notRun ? theme.secondaryText : theme.primaryText,
                    tagLabel: isAwaiting ? "Needs your input"
                        : (notRun ? "Not run"
                        : (degraded ? "Completed · warnings" : node.status.label)),
                    tagColor: isAwaiting ? theme.warningColor : (node.status == .pending || notRun ? theme.secondaryText : statusColor),
                    tagIcon: isAwaiting ? "hand.raised.fill" : nil,
                    tagAction: isAwaiting ? onAwaitingTap : nil,
                    duration: node.status == .pending ? nil : node.duration,
                    showsChevron: isHovered && !isSelected
                )

                // Collapsed one-line preview: pre-terminal rows show their incoming task/input,
                // terminal unselected rows show a snippet of their output.
                if !isSelected, let preview = collapsedPreview(for: node) {
                    Text(preview)
                        .font(.system(.caption))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }

                if isSelected {
                    expandedContent(for: node)
                        .padding(.top, 6)
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
        .accessibilityAddTraits(.isButton)
        // ⚠️ Must agree with the visible tag. This read the RAW status, so on every conditional
        // run VoiceOver announced "Failed" for a node the screen labelled "Not run" — the two
        // descriptions of the same row contradicted each other.
        .accessibilityLabel("\(node.profileName), \(isNotRun(node) ? String(localized: "Not run") : node.status.label)")
        .accessibilityHint(isSelected ? "Selected step" : "Show step details")
        .accessibilityAction { selectedNodeID = node.nodeID }
    }

    private func collapsedPreview(for node: WorkflowRunDisplayData.NodeDisplayData) -> String? {
        switch node.status {
        case .pending, .running:
            let input = node.input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return input.isEmpty ? nil : input
        case .skipped:
            // ⚠️ The REASON, not the input. This arm used to fall through to the input preview,
            // and for legacy records the detail underneath printed the raw engine sentence
            // "Upstream dependency failed" directly below a grey "Not run" tag — restoring the
            // exact failure wording the tag exists to suppress.
            let detail = node.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? nil : detail
        // `.unknown` is a FINISHED node (newer-build status) — its detail is real; show it like
        // any settled node rather than the input preview a pending node gets.
        case .completed, .failed, .cancelled, .unknown:
            let detail = node.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? nil : detail
        }
    }

    // MARK: - Final Outcome step

    @ViewBuilder
    private var finalOutcomeStep: some View {
        let isSelected = selectedNodeID == nil
        let status = finalOutcomeStatus
        // A cancelled run has no `.cancelled` in `NodeStatus` to fall back on, and `workflowError`
        // ("Cancelled") drives `finalOutcomeStatus` to `.failed` — so the Final Outcome row said
        // "Failed" in red under a header pill that correctly said "Cancelled". Overridden here
        // rather than in `finalOutcomeStatus`, which the spine and the pending/awaiting logic also
        // read and which are right as they are.
        // Same override pattern for UNKNOWN (WF-UI1): a record stamped by a newer build derives
        // `.completed` from its settled nodes, so the row asserted a green "Completed" one line
        // under a pill honestly saying "Unknown". The spine/awaiting logic still read `status`.
        let isUnknown = displayData.hasUnknownPersistedStatus
        let statusColor = isCancelled ? theme.warningColor
            : isUnknown ? theme.secondaryText
            : status.color(theme)
        let statusLabel = isCancelled ? String(localized: "Cancelled")
            : isUnknown ? String(localized: "Unknown")
            : status.label
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
                    tagLabel: status == .pending && displayData.isRunning
                        ? "Awaiting inputs · \(settledCount)/\(max(displayData.nodeResults.count, 1))"
                        : statusLabel,
                    tagColor: status == .pending ? theme.secondaryText : statusColor,
                    tagIcon: nil,
                    tagAction: nil,
                    duration: displayData.isRunning ? nil : displayData.duration,
                    showsChevron: isHovered && !isSelected
                )

                if isSelected {
                    finalOutcomeExpanded(status: status)
                        .padding(.top, 6)
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
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Final Outcome, \(status.label)")
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

            statusTag(label: tagLabel, color: tagColor, icon: tagIcon)
                .onTapGesture { tagAction?() }

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

    /// True when the error body is already told by the tail of the node's timeline (e.g. the
    /// circuit-breaker's LOOP GUARD card carries the same sentence) — showing it again below the
    /// trace is pure duplication.
    private func isDuplicatedInTimeline(_ body: String, events: [TimelineEvent]) -> Bool {
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

    /// Inline detail for the selected node — reuses the exact rendering pipeline the output panel
    /// used (AgentTimelineView + WorkflowMarkdownView), but embedded in the timeline so the active
    /// step is the hero. No inner ScrollView: the outer timeline scroll owns scrolling.
    @ViewBuilder
    private func expandedContent(for node: WorkflowRunDisplayData.NodeDisplayData) -> some View {
        let statusColor = isNotRun(node) ? theme.secondaryText.opacity(0.6) : node.status.color(theme)

        detailContainer(edgeColor: statusColor) {
            if isNotRun(node) {
                // The node's own reason, never a hardcoded sentence. "an upstream node failed" was
                // asserted over ordinary Router/Gate routing and over an error handler that
                // correctly stood down — on runs where nothing failed at all.
                inlineStatusLine(message: notRunMessage(for: node), showsSpinner: false)
            } else {
                switch node.status {
                case .running:
                    if node.supportsTimeline {
                        AgentTimelineView(
                            events: node.nodeTimeline,
                            isStreaming: node.isStreaming,
                            chatFidelity: true,
                            streamingStartedAt: displayData.timestamp
                        )
                    } else {
                        inlineStatusLine(message: "Generating output…", showsSpinner: true)
                    }

                case .pending:
                    inlineStatusLine(message: "Waiting for execution", showsSpinner: false)

                case .skipped:
                    inlineStatusLine(message: notRunMessage(for: node), showsSpinner: false)

                case .cancelled:
                    inlineStatusLine(message: String(localized: "Cancelled before this node finished."), showsSpinner: false)

                // `.unknown` routes with the settled arms: the node FINISHED under a newer build,
                // so its detail, duration and full agent trace must render — suppressing them was
                // the WF-UI3 defect ("Waiting" over a node that finished days ago).
                case .completed, .failed, .unknown:
                    let isError = node.status == .failed
                    let (errorBody, suggestion) = isError ? splitDetail(node.detail) : (node.detail, nil)
                    let bodyIsDuplicated = isError
                        && node.supportsTimeline
                        && isDuplicatedInTimeline(errorBody, events: node.nodeTimeline)

                    VStack(alignment: .leading, spacing: 14) {
                        if !node.detail.isEmpty {
                            HStack {
                                Spacer()
                                TimelineCopyChip(target: node.detail)
                            }
                        }

                        if node.supportsTimeline && !node.nodeTimeline.isEmpty {
                            AgentTimelineView(
                                events: node.nodeTimeline,
                                isStreaming: false,
                                chatFidelity: true,
                                finalContentText: node.detail
                            )
                        }

                        if isError {
                            // Error body at footnote scale (body-size red paragraphs dominated the
                            // panel); skipped entirely when the trace already ends with the same
                            // sentence (e.g. the LOOP GUARD card).
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
    private func finalOutcomeExpanded(status: WorkflowRunDisplayData.NodeDisplayData.NodeStatus) -> some View {
        detailContainer(edgeColor: status.color(theme)) {
            if displayData.nodeResults.isEmpty || displayData.nodeResults.allSatisfy({ $0.status == .pending }) {
                inlineStatusLine(message: "Waiting for execution", showsSpinner: false)
            } else if displayData.isRunning && displayData.finalOutput.isEmpty {
                inlineStatusLine(
                    message: status == .running ? "Synthesising final output…" : "Awaiting node outputs…",
                    showsSpinner: status == .running
                )
            } else if let error = displayData.workflowError, displayData.finalOutput.isEmpty {
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
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Spacer()
                        TimelineCopyChip(target: displayData.finalOutput)
                    }
                    WorkflowMarkdownView(text: displayData.finalOutput)
                        .frame(maxWidth: Self.proseMaxWidth, alignment: .leading)
                }
            }
        }
    }

    /// Rounded container with a colored leading edge — the "this is the focused step" panel.
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

/// Local mirror of the output panel's copy affordance (that one is private to WorkflowOutputView,
/// which this prototype leaves untouched for easy revert).
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
                    .fill(isHovering ? theme.surfaceOverlay.opacity(0.8) : theme.surfaceOverlay.opacity(0.4))
            )
            .contentShape(Capsule())
            .scaleEffect(isHovering ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCopied ? "Copied" : "Copy output")
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
    }
}

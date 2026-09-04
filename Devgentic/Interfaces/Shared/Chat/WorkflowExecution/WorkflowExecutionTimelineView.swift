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
//  ⚠️ THE ONLY execution layout — there is no fallback to fall back to. This was once one arm of a
//  `WorkflowDedicatedView.executionLayout` prototype switch, and this header promised "both paths
//  stay compiled"; the `.original` strip + output layout and its four views were DELETED 2026-07-17
//  after shipping timeline-only, taking the property and the enum with them. The sibling note at
//  `WorkflowDedicatedView`'s call site says the same thing; this one had been left claiming the
//  opposite ever since.
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

    /// Conversation this run belongs to — required for the per-node Skip toggle (D2.1), whose
    /// store keys on it (sound under the one-root-run-per-conversation invariant). `nil` hides
    /// the button entirely: a surface that cannot identify the run must not offer to change it.
    /// ⚠️ [CF-53] Also threaded into every `AgentTimelineView` below, so a workflow node's
    /// "Open in viewer" whose disk read outlives a conversation switch is dropped instead of
    /// landing a tab in whatever conversation is open when it returns.
    ///
    /// ⚠️ This is `MainApplicationViewModel.selectedConversationID` — the SIDEBAR selection —
    /// which LEADS `ChatHistoryViewModel`'s load by the 250 ms debounce in
    /// `ConversationSwitchCoordinator`. During that window it already names the incoming
    /// conversation while the chat view model still names the outgoing one, so an open clicked
    /// inside the debounce is dropped even though it was still safe. That is the harmless
    /// direction (a logged drop the user can repeat, rather than a tab landing in the wrong
    /// conversation) and is why the mismatch is not treated as an error.
    var conversationID: UUID? = nil
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

    /// [WF-RU3] The Final Outcome row's ONE source for what it tags and what it speaks.
    ///
    /// `nonisolated static` and pure (no theme/view state) so it is testable directly — a SwiftUI
    /// `.accessibilityLabel` cannot be read back from a hosted view (see
    /// `ChatAccessibilitySemanticsTests`'s header note), so pulling the logic out from under the
    /// view is the only way to pin it. Before this, the visible tag read this same override chain
    /// while `.accessibilityLabel` read the raw, un-overridden `status.label` three lines below —
    /// VoiceOver announced "Failed" on a run the screen correctly tagged "Cancelled", "Completed"
    /// on one tagged "Unknown", and "Waiting" with no progress on a run counting down live inputs.
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
        // [WF-RU4] Same override shape as `isCancelled`/`isUnknown` above: `status`
        // (`finalOutcomeStatus`/`rollupOutcome`) has no third value of its own — it is a NODE-level
        // vocabulary reused for this row — so the run-level nuance is applied here, at the label,
        // exactly like the other two run-level exceptions to a node-shaped status.
        if isCompletedWithWarnings { return String(localized: "Completed with warnings") }
        return status.label
    }

    /// [CF-60] Whether the timeline scrolls to `selection` for this `.onChange` delivery.
    ///
    /// `nonisolated static` and pure (the WF-UI5 shape) because the `ScrollViewReader` closure is
    /// SwiftUI runtime behaviour no unit test can reach, while the rule inside it is exactly the
    /// thing that was wrong.
    ///
    /// ⚠️ The CONSTRUCTION pass scrolls only for an EXPLICIT node selection. `nil` means the Final
    /// Outcome row, which is the resting selection every "back" press leaves behind and the one a
    /// freshly-opened historical run inherits — honouring it here would scroll every run the user
    /// opens straight past its own timeline to the last row. A real change to `nil` still scrolls:
    /// that one the user (or a completing run) asked for.
    nonisolated static func shouldScrollToSelection(_ selection: UUID?, isInitial: Bool) -> Bool {
        isInitial ? selection != nil : true
    }

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

    /// THE status word for a skipped node. Both the visible tag and the VoiceOver label go
    /// through here — they used to hard-code "Not run" independently, which is false for a node
    /// the user skipped mid-flight (it started, spent model time, and its output was discarded).
    private func skipTagLabel(for node: WorkflowRunDisplayData.NodeDisplayData) -> String {
        displayData.skipTagLabel(for: node)
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
                // ⚠️ [CF-60] `initial: true` is load-bearing, not tidiness. The failed-run
                // auto-focus lives on WorkflowDedicatedView and assigns `selectedNodeID` in the
                // SAME update that makes `displayData` non-nil — so this view is CONSTRUCTED with
                // the id already in place, a change-only observer saw no change, and the node the
                // user was sent to debug stayed below the fold. (Selecting another run while the
                // timeline is already on screen scrolled fine, because the view persists.)
                .onChange(of: selectedNodeID, initial: true) { oldValue, newValue in
                    // `initial: true` delivers the current value as BOTH parameters; a real change
                    // never can, because `onChange` only fires on inequality.
                    let isInitial = oldValue == newValue
                    guard Self.shouldScrollToSelection(newValue, isInitial: isInitial) else { return }
                    let target = newValue.map { AnyHashable($0) } ?? AnyHashable(Self.finalOutcomeAnchor)
                    // Unanimated on the construction pass: there is no previous offset to travel
                    // from, and animating one at appear time reads as the view sliding under the
                    // user rather than opening where it should.
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

    /// [WF-CS4] The run executed the last-SAVED graph while the canvas held unsaved edits.
    ///
    /// ⚠️ INFORMATIONAL, not an error: amber, no icon-as-alarm, and it never suppresses or recolours
    /// the status pill above it — the run itself may have succeeded perfectly, it simply ran a
    /// different graph than the one on screen.
    ///
    /// ⚠️ LIVE RUNS ONLY (owner decision, 2026-08-24) — `WorkflowRunDisplayData.from(record:)` leaves
    /// the flag false because the persisted record has no column for it. The wording below is
    /// therefore safe to phrase as a present-tense instruction ("save the canvas and run again"),
    /// which would read wrong on a run that finished days ago. If this is ever persisted, that copy
    /// must be split live/historical in the SAME change.
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

    /// [CF-56] Which override a node row's colour takes.
    ///
    /// `nonisolated static` and theme-free (the WF-UI5 shape) precisely because the defect was a
    /// SECOND, independent derivation of this rule: `expandedContent` re-derived its panel edge
    /// from the raw status and applied only `.notRun`, so a degraded node got a green success frame
    /// under its own amber "Completed · warnings" tag. Returning a ROLE rather than a `Color` is
    /// what makes the rule testable without a `Theme`.
    ///
    /// ⚠️ The awaiting override is NOT here: it is a live-run, HITL-only property of the row rather
    /// than of the node's recorded status, it is not available on the record path at all, and the
    /// call site applies it last (see `rowColor`) exactly as the spine always did.
    ///
    /// ⚠️ The header's progress segments apply the same three overrides in their own palette
    /// (`segmentColor` + a 0.35-alpha muted arm) and deliberately do not route through here — a
    /// 5pt capsule is not a status dot.
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
        // ⚠️ The `.completed` conjunct is load-bearing for the same reason it is on `nodeTagLabel`:
        // a node decoded from a newer build (`.unknown`) can carry `hasWarnings`, and amber there
        // would claim a degraded COMPLETION this build cannot classify.
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
        // [CF-56] ONE decision for which override this row's colour takes — see `nodeColorRole`.
        let statusColor = nodeColor(
            for: Self.nodeColorRole(status: node.status, hasWarnings: node.hasWarnings, isNotRun: notRun),
            status: node.status)
        // ⚠️ [CF-56] THE row's colour, awaiting override included — rendered by the spine here AND
        // by the expanded panel's edge below, which used to re-derive its own from the raw status
        // and so dropped every override but did-not-run: a green success frame under this row's own
        // amber "Completed · warnings" tag, an accent-blue one under "Needs your input". Same shape
        // and same fix as XUI-13 on the Final Outcome row — computed once, passed down.
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

                // Per-node SKIP toggle (Phase A, D2.1): PENDING profile nodes on a LIVE run only.
                // Toggles freely until dispatch consumes the request — that single-shot consume is
                // why no confirmation dialog exists. Reading the store in `body` registers
                // Observation, so an engine-side consume flips the row back without the button.
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
                    .help(isRequested
                          ? "Cancel the skip — this node will run normally"
                          : "Skip this node when the run reaches it — its input is passed downstream unchanged (downstream gets the node's input, not its output)")
                    .accessibilityLabel(isRequested ? "Undo skip for \(node.profileName)" : "Skip \(node.profileName)")
                }

                // RUNNING-skip (Phase B increment 5): bot/agent rows of a LIVE run, mid-flight.
                // NOT undoable — the engine's racer child tears the node down the moment it fires,
                // so once clicked the button becomes a disabled "Skipping…" (driven observably by
                // the store's in-flight state; the row itself flips to Skipped when the engine's
                // event lands). Sub-workflow rows never qualify (`isRunningSkippable` excludes
                // them — the structural path has no racer; increment 8 is deferred).
                if node.status == .running, node.isRunningSkippable, displayData.isRunning,
                   let conversationID {
                    let inFlight = WorkflowNodeSkipStore.shared.runningSkipInFlight(nodeID: node.nodeID, conversationID: conversationID)
                    Button {
                        WorkflowNodeSkipStore.shared.requestRunningSkip(nodeID: node.nodeID, conversationID: conversationID)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "forward.end")
                                .font(.system(size: 9, weight: .semibold))
                            Text(inFlight ? "Skipping…" : "Skip")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(inFlight ? theme.tertiaryText : theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.surfaceOverlay))
                    }
                    .buttonStyle(.plain)
                    .disabled(inFlight)
                    .help(inFlight
                          ? "Skip is in progress — the node's in-flight work is being torn down"
                          : "Skip this node NOW — its in-flight work is discarded and its input is passed downstream unchanged (not undoable; downstream gets the node's input, not its output)")
                    .accessibilityLabel(inFlight ? "Skipping \(node.profileName)" : "Skip \(node.profileName) now")
                }

                if isSelected {
                    expandedContent(for: node, edgeColor: rowColor)
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
        // ⚠️ Must agree with the visible tag, and now does BY CONSTRUCTION — both read
        // `nodeTagLabel`. This used to read the RAW status, so on every conditional run VoiceOver
        // announced "Failed" for a node the screen labelled "Not run". [XUI-10] extended that to the
        // other two overrides the tag applies: a node parked on a HITL prompt was TAGGED "Needs your
        // input" but ANNOUNCED "Running...", and a degraded node was announced as a clean "Completed".
        .accessibilityLabel("\(node.profileName), \(displayData.nodeTagLabel(for: node, isAwaiting: isAwaiting))")
        .accessibilityHint(isSelected ? "Selected step" : "Show step details")
        .accessibilityAction { selectedNodeID = node.nodeID }
    }

    /// Bounds the one-line collapsed preview (register CF-58). `detail` is a node's entire model
    /// output and `input` is the concatenation of every upstream node's entire output; both were
    /// handed to a `lineLimit(1)` `Text` whole, on every body pass, hover transitions included.
    ///
    /// - Parameter limit: 200 characters, chosen to sit ABOVE what the row can actually show —
    ///   this timeline is capped at `ViewLayout.maxContentWidth` and the preview is a single
    ///   `.caption` line, which fits roughly 180 characters at that width. The cap therefore
    ///   removes nothing the user could have read. Signature mirrors the sibling
    ///   `RunCardSpeech.spokenPreview(_:limit:)`, which bounds the SPOKEN half of the same idea.
    ///
    /// ⚠️ Bounds what reaches `Text`, not what reaches this function: the trim below is still
    /// linear in the source string. That is a memcpy; laying out and diffing a multi-kilobyte
    /// string on every body pass was not.
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
            // ⚠️ `input` is the concatenation of every upstream node's ENTIRE output, so this arm
            // is the larger of the two — see `boundedPreview`.
            return boundedPreview(node.input ?? "")
        case .skipped:
            // ⚠️ The REASON, not the input. This arm used to fall through to the input preview,
            // and for legacy records the detail underneath printed the raw engine sentence
            // "Upstream dependency failed" directly below a grey "Not run" tag — restoring the
            // exact failure wording the tag exists to suppress.
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
        // A cancelled run has no `.cancelled` in `NodeStatus` to fall back on, and `workflowError`
        // ("Cancelled") drives `finalOutcomeStatus` to `.failed` — so the Final Outcome row said
        // "Failed" in red under a header pill that correctly said "Cancelled". Overridden here
        // rather than in `finalOutcomeStatus`, which the spine and the pending/awaiting logic also
        // read and which are right as they are.
        // Same override pattern for UNKNOWN (WF-UI1): a record stamped by a newer build derives
        // `.completed` from its settled nodes, so the row asserted a green "Completed" one line
        // under a pill honestly saying "Unknown". The spine/awaiting logic still read `status`.
        let isUnknown = displayData.hasUnknownPersistedStatus
        // [WF-RU4] Same override pattern again: `status` (`finalOutcomeStatus`) still reads
        // `.failed` for this run underneath (unchanged — the node evidence is real), so the run's
        // own softened verdict is layered on here rather than in `finalOutcomeStatus` itself.
        let isCompletedWithWarnings = displayData.pillVerdict == .completedWithWarnings
        let statusColor = isCancelled ? theme.warningColor
            : isUnknown ? theme.secondaryText
            : isCompletedWithWarnings ? theme.warningColor
            : status.color(theme)
        // ⚠️ [WF-RU3] One shared computation drives both the visible tag and what VoiceOver
        // speaks — see `finalOutcomeTagLabel`'s doc for what used to diverge.
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
                    // ⚠️ [XUI-13] `statusColor`, not `status`. The panel used to re-derive its own
                    // edge from the raw status and so bypassed this row's whole override chain —
                    // a Stop got a red edge under an amber tag, an `.other` record got a GREEN
                    // success edge under a grey "Unknown" tag (the false success claim WF-UI1
                    // exists to prevent, re-entering through the edge), and a
                    // `.completedWithWarnings` record got a red edge under an amber tag, undoing
                    // WF-RU4's softening. One colour decision per row, computed above.
                    finalOutcomeExpanded(status: status, edgeColor: statusColor)
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

            // [XUI-10] Attach a gesture ONLY when there is something to invoke. A descendant
            // TapGesture takes precedence over an ancestor's — that is what `highPriorityGesture`
            // exists to invert — so an unconditional `.onTapGesture { tagAction?() }` made this pill
            // a dead zone on every ordinary row: the closure did nothing and the row's own selection
            // tap never fired. Also covers the Final Outcome row, which passes `tagAction: nil`.
            if let tagAction {
                statusTag(label: tagLabel, color: tagColor, icon: tagIcon)
                    .onTapGesture { tagAction() }
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

    /// [CF-59] Memo key for `errorBodyIsDuplicated`.
    ///
    /// ⚠️ `traceLength` is what makes it safe to cache a TRACE-dependent answer: an appended event
    /// can flip the answer from false to true — trace hydration replaces the whole array, and the
    /// last events of a run can land after the node has settled — and both always change the count.
    /// Keying on the node id alone would pin the first answer for the life of the process.
    ///
    /// ⚠️ `traceTailID` is what makes it safe to cache it ACROSS RUNS, and `nodeID` alone is not:
    /// `nodeID` is the persistent LAYOUT node id (the same stability `WorkflowNodeSkipStore` relies
    /// on to key a skip preference), so a Re-run — or the same workflow run in another conversation
    /// — presents the identical node id to a process-lifetime cache. With only `body` and
    /// `traceLength` varying, a node that fails the same way twice with the same event count is an
    /// outright cache hit, and the two answers are NOT interchangeable: the second run's trace tail
    /// may or may not echo the sentence. A stale `true` suppresses the red error paragraph entirely
    /// — a "Failed" node whose expanded panel never says why — and a stale `false` prints the
    /// sentence twice, which is the duplication this predicate exists to remove. Event ids are
    /// generated per event (and persisted, so a hydrated trace keeps its own), so the tail id
    /// changes with the run while staying stable within it.
    ///
    /// ⚠️ NOT keyed on event CONTENT, and that is a deliberate limit rather than an oversight: a
    /// trailing `.toolExecution` row mutated IN PLACE (same id, same count, new output) keeps the
    /// previous answer. That needs a row still being written after its node has settled to
    /// `.failed`, which `DanglingToolRowCloser` rules out — and hashing four 32 KB outputs per body
    /// pass would reinstate exactly the cost this memo exists to remove.
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

    /// Memoised `isDuplicatedInTimeline` (register CF-59).
    ///
    /// The predicate lowercases, splits and rejoins up to four 32 KB `.toolExecution` outputs, and
    /// its only call site is inside `expandedContent`'s `@ViewBuilder` — so it ran on EVERY body
    /// pass of the timeline, and `hoveredRowKey` is `@State` on this view, meaning every hover
    /// transition anywhere in the list paid for it. The answer only changes when the node's error
    /// text or its trace does, which is exactly what `DuplicationKey` carries.
    ///
    /// MainActor-isolated static, mirroring `AsyncHighlightedCodeView.monoFont`: the only callers
    /// are view bodies, already on the main actor.
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

    /// True when the error body is already told by the tail of the node's timeline (e.g. the
    /// circuit-breaker's LOOP GUARD card carries the same sentence) — showing it again below the
    /// trace is pure duplication.
    ///
    /// ⚠️ Call `errorBodyIsDuplicated` from view code, never this — see its note on why the raw
    /// predicate must not run per body pass. `nonisolated static` so the memo above can be the
    /// only caller that is not a test.
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

    /// Inline detail for the selected node — reuses the exact rendering pipeline the output panel
    /// used (AgentTimelineView + WorkflowMarkdownView), but embedded in the timeline so the active
    /// step is the hero. No inner ScrollView: the outer timeline scroll owns scrolling.
    /// - Parameter edgeColor: the ROW's already-overridden colour. ⚠️ Never re-derive it from
    ///   `node.status` here (register CF-56, and XUI-13 for the identical fix on the Final Outcome
    ///   row): every override — did-not-run, degraded success, awaiting input — is applied once at
    ///   the call site, and re-deriving here silently dropped all but the first.
    @ViewBuilder
    private func expandedContent(for node: WorkflowRunDisplayData.NodeDisplayData,
                                 edgeColor: Color) -> some View {
        detailContainer(edgeColor: edgeColor) {
            // ⚠️ Only a node that NEVER STARTED gets the bare one-line treatment. A node the user
            // skipped MID-FLIGHT has a real trace — reasoning, tool calls, the model response —
            // which is captured live AND persisted by `freeze`. Suppressing it here is why the
            // same run showed an 829ms model call in the Run Report and nothing at all in the
            // timeline (observed 2026-08-23): the label fix alone would have made the tag honest
            // while still hiding the evidence behind it.
            if isNotRun(node), !displayData.nodeRanBeforeSkip(node) {
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
                            streamingStartedAt: displayData.timestamp,
                            conversationID: conversationID
                        )
                    } else {
                        inlineStatusLine(message: "Generating output…", showsSpinner: true)
                    }

                case .pending:
                    inlineStatusLine(message: "Waiting for execution", showsSpinner: false)

                // XUI-1: a node skipped MID-FLIGHT or cancelled while executing HAS a trace —
                // that is the whole reason the :697 guard exists — but these arms rendered only
                // the one-liner, making the guard a no-op for its own case. Same shape as the
                // settled arm: captured evidence above, the reason line beneath it. No
                // `finalContentText`: the detail here is the skip/cancel REASON, not the model's
                // answer, and must not render as one (AgentTimelineView uses it only to dedupe a
                // trailing reasoning event against an answer rendered below — passing the reason
                // would wrongly suppress the trace's real tail).
                //
                // ⚠️ UNOBSERVABLE ARM ROUTING: whether an arm renders the trace at all is
                // `@ViewBuilder` code no unit test can reach — `nodeShowsCapturedTrace` (the
                // gate's truth table) is the testable half. A future re-suppression of these two
                // arms would be invisible to the suite; that blind spot is exactly what let
                // XUI-1 ship, so treat any edit here as needing an on-device check.
                case .skipped:
                    VStack(alignment: .leading, spacing: 14) {
                        if displayData.nodeShowsCapturedTrace(node) {
                            AgentTimelineView(
                                events: node.nodeTimeline,
                                isStreaming: false,
                                chatFidelity: true,
                                conversationID: conversationID
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
                                conversationID: conversationID
                            )
                        }
                        inlineStatusLine(message: String(localized: "Cancelled before this node finished."), showsSpinner: false)
                    }

                // `.unknown` routes with the settled arms: the node FINISHED under a newer build,
                // so its detail, duration and full agent trace must render — suppressing them was
                // the WF-UI3 defect ("Waiting" over a node that finished days ago).
                case .completed, .failed, .unknown:
                    let isError = node.status == .failed
                    let (errorBody, suggestion) = isError ? splitDetail(node.detail) : (node.detail, nil)
                    // [CF-59] Through the memo, never the raw predicate: this line is evaluated on
                    // every body pass of the timeline, hover transitions included.
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
                                conversationID: conversationID
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
    /// - Parameter edgeColor: the ROW's already-overridden colour. ⚠️ Never re-derive it from
    ///   `status` here (register XUI-13) — `status` is deliberately left un-overridden because the
    ///   spine and the awaiting logic read it, and every override lives at the call site.
    private func finalOutcomeExpanded(
        status: WorkflowRunDisplayData.NodeDisplayData.NodeStatus,
        edgeColor: Color
    ) -> some View {
        // ⚠️ WHICH panel shows is decided on `WorkflowRunDisplayData.finalOutcomePanel` (XUI-2,
        // the WF-UI5 shape) — the branch ORDER was the defect and it is now testable there. This
        // switch only renders; do not grow decisions back into it.
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

/// The timeline's copy affordance. It was duplicated from an identical one private to
/// `WorkflowOutputView`, deliberately, so the prototype arm could be reverted without touching that
/// view — and `WorkflowOutputView` was then deleted with the rest of the strip + output layout, so
/// there is nothing left to mirror and this is the only copy.
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

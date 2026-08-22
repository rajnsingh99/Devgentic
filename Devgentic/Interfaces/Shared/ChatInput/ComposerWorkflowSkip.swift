//
//  ComposerWorkflowSkip.swift
//  Devgentic
//
//  The composer's per-node SKIP surface — Phase B increment 7 of the per-node skip design
//  (`LLM_Execution_Concurrency_Design.md` §0.6 D2.1). The composer renders OUTSIDE the interface
//  mode switch, so it is the ONLY skip surface for a workflow run started from chat mode, where
//  the timeline is off-screen.
//
//  Two pieces, split on the `ForegroundRunResolver` shape (policy in a pure function, effects in
//  the view): `ComposerSkipResolver` decides WHAT the button is from plain values —
//  fully unit-testable without SwiftUI or the executor — and `ComposerWorkflowSkipButton` is a
//  LEAF view that does all the observable reads in its own `body`.
//
//  ⚠️ OBSERVATION CONFINEMENT IS THE POINT OF THE LEAF VIEW. `WorkflowExecutionState.nodeResults`
//  mutates on every node event; reading it in `ChatInputAreaView.body` would re-run the whole
//  composer (text editor, gauge, suggestion pipelines) per event and per keystroke-scale timeline
//  append. The composer passes a plain `UUID?` down and this view pays the re-evaluation alone —
//  a capsule's worth of body per workflow event.
//

import SwiftUI

private let logger = DGLogger(category: "ComposerWorkflowSkip")

// MARK: - Policy

enum ComposerSkipResolver {

    /// One RUNNING node, snapshotted to plain values by the view.
    struct RunningNode: Equatable, Sendable {
        let nodeID: UUID
        let displayName: String
        /// Bot/agent only — sub-workflow nodes run down the structural path the running-skip
        /// racer never enters, so offering them here would offer an action the engine cannot
        /// honour. The caller derives this from the layout join (same rule as the timeline's
        /// `isRunningSkippable`).
        let isRunningSkippable: Bool
    }

    enum Verdict: Equatable {
        /// No live run, or nothing skippable is running — render nothing.
        case hidden
        /// Several skippable nodes are running (parallel lanes). NEVER silently pick one
        /// (owner rule, D2.1): the button renders disabled with this reason, pointing at the
        /// timeline where each row has its own button.
        case disabled(reason: String)
        /// The one candidate's skip is already in flight — disabled "Skipping…" feedback, so a
        /// second click cannot run teardown twice and the user sees the press took.
        case inFlight(nodeName: String)
        /// Exactly one skippable node is running — the button targets it by name.
        case enabled(nodeID: UUID, nodeName: String)
    }

    /// Pure: verdict from plain values. The view re-resolves at PRESS time too — render-time
    /// state may be a whole node-transition stale by the time the user clicks (the
    /// `MessagingCoordinator.cancelStreamingResponse` pattern: never trust the rendered target).
    nonisolated static func resolve(
        runIsLive: Bool,
        runningNodes: [RunningNode],
        inFlightNodeIDs: Set<UUID>
    ) -> Verdict {
        guard runIsLive else { return .hidden }
        let candidates = runningNodes.filter(\.isRunningSkippable)
        guard let only = candidates.first else { return .hidden }
        guard candidates.count == 1 else {
            return .disabled(reason: "\(candidates.count) nodes are running — skip from the timeline, where each row has its own button")
        }
        if inFlightNodeIDs.contains(only.nodeID) { return .inFlight(nodeName: only.displayName) }
        return .enabled(nodeID: only.nodeID, nodeName: only.displayName)
    }
}

// MARK: - Leaf view

struct ComposerWorkflowSkipButton: View {

    /// Plain value from the composer — the ONLY thing it passes down, so its own body never
    /// registers on workflow state.
    let conversationID: UUID?

    @Environment(MainApplicationViewModel.self) private var mainViewModel
    @Environment(\.appTheme) private var theme

    /// Layout cache for the kind join (`nodeResults` carries no node kind — running rows must be
    /// joined against the canvas layout to know bot/agent from structural/sub-workflow).
    /// Keyed by profile so a different workflow re-loads; a store read per body would be a disk
    /// decode per node event.
    @State private var cachedLayout: (profileID: UUID, layout: WorkflowLayout)?

    var body: some View {
        if let conversationID {
            let verdict = currentVerdict(conversationID: conversationID)
            switch verdict {
            case .hidden:
                EmptyView()
            case .disabled(let reason):
                skipCapsule(text: "Skip", disabled: true)
                    .help(reason)
                    .accessibilityLabel("Skip unavailable: \(reason)")
            case .inFlight(let nodeName):
                skipCapsule(text: "Skipping…", disabled: true)
                    .help("Skip of '\(nodeName)' is in progress — its in-flight work is being torn down")
                    .accessibilityLabel("Skipping \(nodeName)")
            case .enabled(let nodeID, let nodeName):
                Button {
                    press(renderedNodeID: nodeID, conversationID: conversationID)
                } label: {
                    capsuleLabel(text: "Skip", disabled: false)
                }
                .buttonStyle(.plain)
                .help("Skip '\(nodeName)' now — its in-flight work is discarded and its input is passed downstream unchanged (not undoable)")
                .accessibilityLabel("Skip \(nodeName) now")
            }
        }
    }

    // MARK: Reads (all confined to this body)

    private func currentVerdict(conversationID: UUID) -> ComposerSkipResolver.Verdict {
        guard let state = mainViewModel.workflowExecutionStates[conversationID],
              state.isRunning else {
            // Presence alone includes finished runs — the state object outlives the run.
            return .hidden
        }
        let layout = layout(for: state.workflowProfileID)
        let running = state.nodeResults
            .filter { $0.status == .running }
            .map { row -> ComposerSkipResolver.RunningNode in
                let node = layout?.nodes.first(where: { $0.id == row.nodeID })
                let isProfile: Bool = {
                    if case .profile = node?.kind { return true }
                    return false
                }()
                return ComposerSkipResolver.RunningNode(
                    nodeID: row.nodeID,
                    displayName: row.profileName,
                    isRunningSkippable: isProfile && node?.profileType != .workflow
                )
            }
        let inFlight = Set(running.map(\.nodeID).filter {
            WorkflowNodeSkipStore.shared.runningSkipInFlight(nodeID: $0, conversationID: conversationID)
        })
        return ComposerSkipResolver.resolve(
            runIsLive: state.isRunning,
            runningNodes: running,
            inFlightNodeIDs: inFlight
        )
    }

    private func layout(for profileID: UUID?) -> WorkflowLayout? {
        guard let profileID else { return nil }
        if let cached = cachedLayout, cached.profileID == profileID { return cached.layout }
        let loaded = WorkflowLayoutStore.shared.load(for: profileID)
        // ⚠️ Not assigned during body — @State writes mid-render are discarded with a runtime
        // warning. Defer to the next tick; until it lands, each body pays one load (bounded by
        // how often the verdict is non-hidden with a cold cache).
        Task { @MainActor in cachedLayout = (profileID, loaded) }
        return loaded
    }

    // MARK: Action

    private func press(renderedNodeID: UUID, conversationID: UUID) {
        // Re-resolve at press time: the rendered target may have finished (and another node
        // started) between render and click — skipping the WRONG node on stale state would be
        // worse than a no-op.
        let verdict = currentVerdict(conversationID: conversationID)
        guard case .enabled(let nodeID, let nodeName) = verdict else {
            logger.warning("[NODE-SKIP] Composer skip press resolved to \(String(describing: verdict)) at press time (rendered target \(renderedNodeID.uuidString.prefix(8)) is stale). CONSEQUENCE: no-op — nothing is skipped; the button re-renders from current state.")
            return
        }
        if nodeID != renderedNodeID {
            logger.notice("[NODE-SKIP] Composer skip target changed between render and press (\(renderedNodeID.uuidString.prefix(8)) → \(nodeID.uuidString.prefix(8)) '\(nodeName)'). Honouring the PRESS-time target — it is the node the user is watching run.")
        }
        WorkflowNodeSkipStore.shared.requestRunningSkip(nodeID: nodeID, conversationID: conversationID)
    }

    // MARK: Label

    @ViewBuilder
    private func skipCapsule(text: String, disabled: Bool) -> some View {
        Button {} label: { capsuleLabel(text: text, disabled: disabled) }
            .buttonStyle(.plain)
            .disabled(true)
    }

    private func capsuleLabel(text: String, disabled: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "forward.end")
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(disabled ? theme.tertiaryText : theme.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(theme.surfaceOverlay))
    }
}

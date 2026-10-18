// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileNodeInspectorView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

private let logger = DGLogger(category: "ProfileNodeInspector")

/// Inspector sheet for profile-backed workflow nodes (Bot, Agent, Workflow, ImageGen): workflow orchestration overrides
/// (failure cascade, timeout, whole-node retries) plus the node's profile details embedded inline.
/// Inspector sheet for profile-backed workflow nodes (Bot, Agent, Workflow, ImageGen): workflow orchestration overrides
/// (failure cascade, timeout, whole-node retries) plus the node's profile details embedded inline.
/// Inspector sheet for profile-backed workflow nodes (Bot, Agent, Workflow, ImageGen): workflow orchestration overrides
/// (failure cascade, timeout, whole-node retries) plus the node's profile details embedded inline.
struct ProfileNodeInspectorView: View {
    @Binding var node: WorkflowNode
    let profile: BackendProfileModel?
    /// Ends the canvas's undo-coalescing run, so Cancel's restore becomes its own undo step rather
    /// than folding into the edits it discards (register INS-2). A closure rather than a
    /// `WorkflowCanvasState` reference, so this panel keeps its single dependency on the node binding.
    var endCoalescingRun: () -> Void = {}
    @Environment(\.closeNodeInspector) private var closeInspector
    @Environment(BackendProfileService.self) private var profileService
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme

    // MARK: - State

    @State private var showGuide: Bool = false
    @State private var editBuffer: ProfileEditBuffer?
    @State private var inlineProfileError: String?

    // Why: orchestration controls write straight through the binding (live rename, undo coalescing, teardown safety);
    // do not buffer them in `@State`.
    /// The node as it stood when this panel opened, so Cancel can put it back; captured in `init` so it cannot miss an early
    /// write.
    private let openSnapshot: NodeInspectorOpenSnapshot

    var showsHeader: Bool = true

    // MARK: - Init

    init(
        node: Binding<WorkflowNode>,
        profile: BackendProfileModel?,
        endCoalescingRun: @escaping () -> Void = {},
        showsHeader: Bool = true
    ) {
        self._node = node
        self.profile = profile
        self.endCoalescingRun = endCoalescingRun
        self.showsHeader = showsHeader
        self.openSnapshot = NodeInspectorOpenSnapshot(node.wrappedValue)
        if let profile {
            self._editBuffer = State(initialValue: ProfileEditBuffer(profile: profile))
        } else {
            self._editBuffer = State(initialValue: nil)
        }
    }

    /// A node backed by a *workflow* profile runs as a nested sub-workflow: its steps come from
    /// that workflow's own canvas, and its input is this node's upstream output. Still used by the
    /// guide copy below, which explains that difference.
    private var isSubWorkflowNode: Bool {
        if case .profile(_, .workflow) = node.kind { return true }
        return false
    }

    // Why: this panel is borderless and has no Cancel: anything that can make `isValid` false would trap the user with
    // no exit.
    /// Currently always true; kept as the single place Done is gated, so a future required field has a home.
    private var isValid: Bool { true }

    // MARK: - Node Config Bindings
    // Each binding lazy-instantiates `nodeConfig` on write; reads surface the effective default (what the executor uses
    // when the override is unset).

    private func ensureNodeConfig() {
        guard node.nodeConfig == nil else { return }
        node.nodeConfig = WorkflowNodeConfig()
    }

    private var hardTimeoutBinding: Binding<TimeInterval?> {
        Binding(
            get: { node.nodeConfig?.hardTimeout },
            set: { newValue in
                ensureNodeConfig()
                node.nodeConfig?.hardTimeout = newValue
            }
        )
    }

    private var maxRetriesBinding: Binding<Int> {
        Binding(
            get: { node.nodeConfig?.maxNodeRetries ?? 0 },
            set: { newValue in
                ensureNodeConfig()
                node.nodeConfig?.maxNodeRetries = max(0, min(newValue, 5))
            }
        )
    }

    private var unattendedAutoApproveBinding: Binding<Bool> {
        Binding(
            get: { node.nodeConfig?.unattendedAutoApprove ?? false },
            set: { newValue in
                ensureNodeConfig()
                // nil (not false) when off — the default costs no bytes in the blob.
                node.nodeConfig?.unattendedAutoApprove = newValue ? true : nil
            }
        )
    }

    private var retryDelayBinding: Binding<TimeInterval> {
        Binding(
            get: { node.nodeConfig?.retryDelay ?? 0 },
            set: { newValue in
                ensureNodeConfig()
                node.nodeConfig?.retryDelay = max(0, min(newValue, 60))
            }
        )
    }


    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)
            }
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 24) {
                    guideCard
                    nodeConfigCard
                    profileSection
                }
                .padding(24)
            }
        }
        .frame(
            minWidth: showsHeader ? 800 : nil,
            idealWidth: showsHeader ? 950 : nil,
            maxWidth: .infinity,
            minHeight: showsHeader ? 540 : nil,
            idealHeight: showsHeader ? 680 : nil,
            maxHeight: .infinity
        )
        .background(theme.primaryBackground)
        .onAppear {
            loadFromNode()
            if editBuffer == nil, let profile {
                editBuffer = ProfileEditBuffer(profile: profile)
            }
        }
        .onDisappear {
            if !showsHeader, let editBuffer {
                Self.commitBufferedEdits(editBuffer, service: profileService, nodeDisplayName: node.displayName)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: profileIcon)
                .font(theme.fontSubheadline.weight(.semibold))
                .foregroundColor(theme.accentColor)
            // Editable node label; the node's name is independent of the underlying profile's name, so a node can display a
            // role-specific label.
            TextField(
                "",
                text: $node.displayName,
                prompt: Text("Node Name").foregroundColor(theme.placeholderText)
            )
            .font(theme.fontSubheadline.weight(.semibold))
            .textFieldStyle(.plain)
            .foregroundColor(theme.primaryText)
            Spacer()

            if let editBuffer, editBuffer.isDirty {
                GlassActionButton(title: "Revert Profile", icon: "arrow.counterclockwise", isAccent: false) {
                    editBuffer.revert()
                    inlineProfileError = nil
                }
            }

            // Cancel discards, as the other inspectors do (including an unsaved `ProfileEditBuffer`); this panel is borderless with
            // no other exit when a run auto-flips to Execution and removes the canvas.
            GlassActionButton(title: "Cancel", icon: "xmark", isAccent: false) {
                // Cancel is the one explicit discard: clear the teardown commit first, or the close it triggers would save the edits
                // being discarded.
                NodeInspectorPendingCommit.shared.clear()
                // Also put back what the write-through controls already committed; otherwise Cancel leaves the node's orchestration
                // overrides and rename in place.
                restoreOpenSnapshot()
                closeInspector()
            }

            GlassActionButton(title: "Done", icon: "checkmark", isAccent: true) { saveAndDismiss() }
                .disabled(!isValid)
                .opacity(isValid ? 1.0 : 0.4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Guide Card (Collapsible)

    /// The only inspector that lacked one — every other node kind documents itself in place.
    /// Content is split by what the node actually IS: an agent turn vs a nested sub-workflow run.
    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: $showGuide) {
                VStack(alignment: .leading, spacing: 8) {
                    if isSubWorkflowNode {
                        profileGuideLine("This node runs another workflow's canvas as a child. Its directive is the upstream output — there is no per-node task to write.")
                        profileGuideLine("Text-only handoff: the child receives this node's input as its message. Workflow variables and files do NOT cross into the child; files the child produces DO flow out.")
                        // Uses the label shown on the control below ('Per-Node Timeout'), not the model property name.
                        profileGuideLine("⚠️ Unlike every other node kind, \"Default\" here means NO timeout at all — the child canvas already bounds every one of its own nodes on its own terms. Setting the Per-Node Timeout below adds a ceiling over the child's ENTIRE run, not one step, and — with retries configured — ALL attempts share that ONE ceiling rather than each getting its own.")
                        profileGuideLine("Nesting is limited to 3 levels, and cycles (a workflow that ends up running itself) are blocked before the run starts.")
                        profileGuideLine("Approvals and gates INSIDE the child surface here exactly as if they were this workflow's own.")
                    } else {
                        profileGuideLine("Runs the bound profile for one turn. What it DOES is the profile's own system instructions — edit them below; there is no separate per-node task.")
                        profileGuideLine("What it acts on is its input: the message that started the run for ENTRY nodes, and upstream output for every node below one.")
                        profileGuideLine("An agent's tool confirmations pause the run for approval, scoped to THIS node. Waiting never counts against the node's timeout.")
                        profileGuideLine("Retries re-run the WHOLE turn — including tool side effects the agent already performed. Keep retries at 0 for agents whose tools write or send things.")
                        profileGuideLine("On failure the error port activates; wire it for recovery, or the branch stops with the reason in the final output.")
                    }
                }
                .padding(.top, 10)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed")
                        .font(.system(.caption, weight: .medium))
                        .foregroundColor(.blue)
                    Text(isSubWorkflowNode ? "How Sub-workflow Nodes Work" : "How Profile Nodes Work")
                        .font(theme.fontCaption.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                }
            }
            .disclosureGroupStyle(.automatic)
        }
        .padding(16)
        .background(theme.surfaceOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func profileGuideLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .font(theme.fontCaption2.weight(.bold))
                .foregroundColor(.blue)
            Text(text)
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)
                .lineSpacing(2.0)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Workflow Orchestration Card
    // Workflow-layer concerns around this node as part of the DAG; they do not duplicate the profile's own Execution
    // settings, which control how the agent behaves inside one run.

    private var nodeConfigCard: some View {
        SettingsCard(title: "Workflow Orchestration", icon: "gearshape", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                Text("These overrides apply only to this node's role in the workflow. The agent's own Execution settings (max iterations, parse-retries, etc.) stay untouched.")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2.5)
                    .padding(.bottom, 4)

                // Per-Node Timeout (optional; "Default" + Set button vs Stepper + Remove)
                behaviorRow(
                    label: "Per-Node Timeout",
                    explainer: "Overrides the agent's Execution Timeout for this node only."
                ) {
                    timeoutControl
                }

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)

                // Node-Level Retries
                behaviorRow(
                    label: "Node-Level Retries",
                    // For a nested workflow a retry re-runs the entire child, so the explainer says a child's side effects repeat.
                    // Surfaced, not enforced: the retry count you set is always honoured.
                    explainer: isSubWorkflowNode
                        ? "Re-runs the ENTIRE nested workflow from its first node. Any side effect the child already performed — a sent message, a written file — happens again."
                        : "Re-runs the whole node from scratch. Independent of the agent's parse-retry policy."
                ) {
                    Stepper(
                        "\(maxRetriesBinding.wrappedValue)",
                        value: maxRetriesBinding,
                        in: 0...5
                    )
                    .fixedSize()
                }

                // Retry Delay — contextual; only meaningful when retries > 0
                if maxRetriesBinding.wrappedValue > 0 {
                    Rectangle()
                        .fill(theme.dividerColor.opacity(0.3))
                        .frame(height: 0.5)

                    behaviorRow(
                        label: "Retry Delay",
                        explainer: "Seconds to wait between retry attempts. Useful for flaky external dependencies."
                    ) {
                        Stepper(
                            "\(Int(retryDelayBinding.wrappedValue))s",
                            value: retryDelayBinding,
                            in: 0...60,
                            step: 1
                        )
                        .fixedSize()
                    }
                }

                // The explicit unattended approval: the sanctioned way to let a scheduled run use a confirming tool. Hidden on
                // sub-workflow nodes, which never build a `WorkflowExecutionContext`, so nothing would read the setting.
                if !isSubWorkflowNode {
                    Rectangle()
                        .fill(theme.dividerColor.opacity(0.3))
                        .frame(height: 0.5)

                    behaviorRow(
                        label: "Unattended Auto-Approve",
                        // Wording differs from the Action node's twin row: on the agent path a refused confirmation is a failed observation and
                        // the node does not fail onto its error port, so no error port is promised here.
                        explainer: "Scheduled runs auto-approve this node's tool confirmations. Off: the tool is refused and the agent is told it could not run — the node itself still completes, so check its output rather than wiring the error port."
                    ) {
                        Toggle("", isOn: unattendedAutoApproveBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    /// Per-node timeout control: 'Default' with a Set button (nil) vs stepper + Remove (explicit). Default inherits
    /// `WorkflowConfig.nodeTimeout`, except for a sub-workflow node, where it means no outer ceiling since its child canvas
    /// bounds its own nodes.
    @ViewBuilder
    private var timeoutControl: some View {
        if let current = hardTimeoutBinding.wrappedValue {
            HStack(spacing: 8) {
                Stepper(
                    "\(Int(current))s",
                    value: Binding(
                        get: { current },
                        set: { hardTimeoutBinding.wrappedValue = $0 }
                    ),
                    in: 10...3600,
                    step: 10
                )
                .fixedSize()

                GlassActionButton(title: "Reset", icon: "arrow.counterclockwise", isAccent: false) {
                    hardTimeoutBinding.wrappedValue = nil
                }
            }
        } else {
            HStack(spacing: 8) {
                Text("Default")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                GlassActionButton(title: "Set", icon: "clock", isAccent: true) {
                    hardTimeoutBinding.wrappedValue = 120
                }
            }
        }
    }

    /// One row of the Workflow Orchestration card.
    @ViewBuilder
    private func behaviorRow<Control: View>(
        label: String,
        explainer: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Text(explainer)
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            control()
        }
    }

    // MARK: - Profile Details Section (Inline)

    @ViewBuilder
    private var profileSection: some View {
        if let editBuffer {
            VStack(alignment: .leading, spacing: 20) {
                if let error = inlineProfileError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(theme.fontCaption2)
                        Text(error)
                            .font(theme.fontCaption2)
                    }
                    .foregroundColor(theme.errorColor)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.errorColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }

                switch editBuffer.draft.details {
                case .bot:
                    BotConfigDetailView(editBuffer: editBuffer, isEmbedded: true)
                case .agent:
                    AgentConfigDetailView(editBuffer: editBuffer, isEmbedded: true)
                case .imageGen:
                    ImageGenConfigDetailView(editBuffer: editBuffer, isEmbedded: true)
                case .workflow:
                    subWorkflowCard
                case .code:
                    codeProfileCard
                }
            }
        } else {
            missingConfigurationCard
        }
    }

    /// Shown when this node's backing row cannot be resolved; the copy is kind-specific because the remedy is. A bot/agent
    /// node owns its configuration, so re-adding fixes it; a sub-workflow node references another canvas, so the copy names
    /// the situation instead.
    private var missingConfigurationCard: some View {
        SettingsCard(
            title: isSubWorkflowNode ? "Workflow Missing" : "Configuration Missing",
            icon: "exclamationmark.triangle",
            theme: theme
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(isSubWorkflowNode
                     ? WorkflowValidator.missingWorkflowMessage
                     : WorkflowValidator.missingConfigurationMessage)
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.errorColor)
                    .fixedSize(horizontal: false, vertical: true)

                Text(isSubWorkflowNode
                     ? "Its steps lived on that workflow's own canvas, so they cannot be recovered from here."
                     : "Its model, instructions and tools were stored with this node and are not recoverable.")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }

    private var subWorkflowCard: some View {
        SettingsCard(title: "Sub-Workflow Canvas", icon: "arrow.triangle.branch", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                Text("This node executes the nested workflow '\(editBuffer?.draft.displayName ?? "Workflow")'. Its steps, nodes, and routing logic are authored directly on that workflow's canvas.")
                    .font(theme.fontFootnote)
                    .foregroundColor(theme.secondaryText)

                Text("To modify the sub-workflow's execution graph, open it from the Workflows sidebar.")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(16)
        }
    }

    private var codeProfileCard: some View {
        SettingsCard(title: "Code Session", icon: "chevron.left.forwardslash.chevron.right", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Code sessions are configured via the Code interface.")
                    .font(theme.fontFootnote)
                    .foregroundColor(theme.secondaryText)
            }
            .padding(16)
        }
    }

    // MARK: - Computed Properties

    private var profileIcon: String {
        guard case .profile(_, let profileType) = node.kind else { return "questionmark.circle" }
        switch profileType {
        case .bot: return "bubble.left.fill"
        case .agent: return "cpu"
        case .workflow: return "arrow.triangle.branch"
        case .imageGen: return "photo"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }

    // MARK: - Load / Save

    private func loadFromNode() {
        // Nothing node-local to load: the orchestration fields below bind straight through to `node.nodeConfig`.

        // Registers the teardown commit: node deletion, a superseding inspector and canvas teardown bypass Done. The closure
        // captures the class instances, so it reads the live draft at fire time; Done and Cancel clear it first.
        if let editBuffer {
            let service = profileService
            let nodeName = node.displayName
            NodeInspectorPendingCommit.shared.register {
                Self.commitBufferedEdits(editBuffer, service: service, nodeDisplayName: nodeName)
            }
        }
    }

    // Why: the instructions-missing rule is not applied as Done applies it: a teardown cannot stay open to be fixed,
    // and discarding the draft loses edits.
    /// Persists a dirty buffered draft on a close route that bypassed Done. Static and headless: a refused save is logged
    /// with its consequence.
    @discardableResult
    static func commitBufferedEdits(
        _ editBuffer: ProfileEditBuffer,
        service: BackendProfileService,
        nodeDisplayName: String
    ) -> Bool {
        guard editBuffer.isDirty else { return false }
        do {
            _ = try service.saveProfile(editBuffer.draft)
            editBuffer.markSaved()
            // Every out-of-band save must rebase any open editor buffer (`BackendProfileService.rebaseEditBuffer`); matters for
            // sub-workflow nodes, whose draft is the shared workflow profile.
            service.rebaseEditBuffer(to: editBuffer.draft)
            logger.info("[WF_CANVAS] Node inspector closed without Done — COMMITTED the buffered profile edits for node '\(nodeDisplayName)' (profile \(editBuffer.draft.id.uuidString.prefix(8))). CONSEQUENCE: what the user typed is saved, matching Done; Cancel remains the one explicit discard.")
            return true
        } catch {
            logger.error("[WF_CANVAS] Node inspector closed without Done and the buffered profile edits for node '\(nodeDisplayName)' could NOT be saved: \(error.localizedDescription). CONSEQUENCE: those edits are LOST — the panel is gone, so there is no surface left to show the refusal on.")
            return false
        }
    }

    /// Puts the node back as it was when the panel opened, and says so.
    private func restoreOpenSnapshot() {
        guard let restored = openSnapshot.restored(into: node) else {
            logger.debug("[WF_CANVAS] Cancel on node inspector \(openSnapshot.nodeID.uuidString.prefix(8)): nothing to restore (\(openSnapshot.unchangedOrGoneReason(for: node))). CONSEQUENCE: no write, no undo step, and the canvas's unsaved state is untouched.")
            return
        }
        logger.notice("[WF_CANVAS] Cancel on node inspector \(openSnapshot.nodeID.uuidString.prefix(8)): restoring the node name and per-node orchestration settings written while the panel was open. CONSEQUENCE: timeout, retries, retry delay, unattended auto-approve and the node name go back to their values from when it opened; the profile edit buffer is discarded separately, and the whole discard is ONE undo step.")
        // Break the coalescing run first: the restore shares the `coalescingKey` of the edits it undoes, and writes to one node
        // inside a 3s window are folded, which would leave a no-op step or let Cmd-Z re-apply the cancelled edits.
        endCoalescingRun()
        node = restored
    }

    private func saveAndDismiss() {
        // Orchestration controls call `ensureNodeConfig()` on a real write, so Done does not materialize defaults (that would
        // dirty the canvas and burn an undo slot). If the profile was edited, validate and save.
        if let editBuffer, editBuffer.isDirty {
            var instructions: String?
            switch editBuffer.draft.details {
            case .bot(let config): instructions = config.instructions
            case .agent(let config): instructions = config.instructions
            default: break
            }

            if let instructions, ProfileValidator.instructionsAreMissing(instructions) {
                inlineProfileError = ProfileValidator.missingInstructionsMessage
                toastManager.show(ProfileValidator.missingInstructionsMessage, style: .error)
                return
            }

            do {
                _ = try profileService.saveProfile(editBuffer.draft)
                editBuffer.markSaved()
                // The rebase contract — see `commitBufferedEdits`. Done was the missing call site.
                profileService.rebaseEditBuffer(to: editBuffer.draft)
                inlineProfileError = nil
            } catch {
                inlineProfileError = error.localizedDescription
                toastManager.show(error.localizedDescription, style: .error)
                return
            }
        }

        // Done just saved — the teardown commit has nothing left to do, and letting it fire on the
        // close below would re-save (a redundant write that bumps `lastSelected`).
        NodeInspectorPendingCommit.shared.clear()
        closeInspector()
    }
}

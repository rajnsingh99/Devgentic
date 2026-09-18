// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileNodeInspectorView.swift
//  Devgentic
//
//  Created by Claude on 13/04/26.
//
//  Inspector sheet for profile-backed workflow nodes (Bot, Agent, Workflow, ImageGen).
//  Three sections:
//    1. Node Task — per-node directive ("what this node does"). Combined with
//       the agent's system prompt at run time. Persona stays on the profile;
//       the task changes per node.
//    2. Workflow Orchestration — node-level overrides for failure cascade,
//       timeout, and whole-node retries. These are workflow-layer concerns
//       and do *not* duplicate the agent's own Execution settings (which
//       govern within-execution behaviour like parse-retry).
//    3. Profile Details — the actual profile configuration (model, persona,
//       tools, capabilities, knowledge, execution, advanced settings)
//       embedded directly inline.
//

import SwiftUI

private let logger = DGLogger(category: "ProfileNodeInspector")

struct ProfileNodeInspectorView: View {
    @Binding var node: WorkflowNode
    let profile: BackendProfileModel?
    /// The workflow-level retry count this node INHERITS when it carries no count of its own
    /// (register INS-8). Same value and same reason as the Action inspector's.
    var inheritedRetryDefault: Int = 0
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

    /// [INS-2] The node as it stood when this panel opened, so Cancel can put it back.
    ///
    /// ⚠️ The orchestration controls deliberately write STRAIGHT THROUGH the binding — that is what
    /// makes the live canvas rename work, what the 3s undo coalescing was engineered for, and what
    /// stops the Run auto-flip teardown (which never reaches Done) from losing an edit. So the fix
    /// is NOT to buffer them in `@State`; that would reintroduce the exact loss
    /// `NodeInspectorPendingCommit` exists to prevent. The fix is to give Cancel the one thing it
    /// lacked: something to restore. Captured in `init`, not `onAppear`, so it cannot miss a write
    /// made before the first layout pass.
    private let openSnapshot: NodeInspectorOpenSnapshot

    // MARK: - Init

    init(
        node: Binding<WorkflowNode>,
        profile: BackendProfileModel?,
        inheritedRetryDefault: Int = 0,
        endCoalescingRun: @escaping () -> Void = {}
    ) {
        self._node = node
        self.profile = profile
        self.inheritedRetryDefault = inheritedRetryDefault
        self.endCoalescingRun = endCoalescingRun
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

    /// ⚠️ ALWAYS TRUE since the Node Task field was removed (2026-08-29). Kept as the single
    /// place Done is gated, so a future required field has an obvious home — and deliberately NOT
    /// deleted along with the condition it used to hold, because this panel is borderless,
    /// always-on-top and has no Cancel: anything that can make `isValid` false traps the user with
    /// no exit on a one-node canvas. That is what gating Done on a task description did to
    /// sub-workflow nodes, which had no use for one.
    private var isValid: Bool { true }

    // MARK: - Node Config Bindings
    //
    // Each binding lazy-instantiates `nodeConfig` on write so the user doesn't
    // need to remember to "enable" the section before editing. Reads always
    // surface the effective default (matches what the executor would pick up
    // from `WorkflowConfig` defaults if the per-node override is unset).

    private func ensureNodeConfig() {
        guard node.nodeConfig == nil else { return }
        // ⚠️ [INS-8] SEED the inherited retry count. `maxNodeRetries` is a non-optional Int, so the
        // executor's `?? workflowConfig.resolvedMaxRetries` fallback is reachable only while
        // `nodeConfig` is nil — materialising a BARE config therefore pins the node to 0 retries.
        // That fired from the timeout, retry-delay and auto-approve setters, none of which the user
        // thinks of as touching retries: on a legacy workflow the stepper visibly dropped from its
        // inherited value to 0 as a side effect of pressing "Set" on the timeout.
        node.nodeConfig = .materialised(inheritedRetryDefault: inheritedRetryDefault)
        if inheritedRetryDefault > 0 {
            logger.notice("[WF_CANVAS] Node '\(node.displayName)' [node \(node.id.uuidString.prefix(8))] had no per-node config; creating one and PINNING this workflow's retired default of \(inheritedRetryDefault) retries onto the node. CONSEQUENCE: the node keeps the retry count it was already running with, but it now carries its own copy — changing the workflow-level default will no longer move it.")
        }
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
            // [INS-8] `?? inheritedRetryDefault`, not `?? 0` — `maxNodeRetries` is a non-optional
            // Int, so the executor's `?? workflowConfig.resolvedMaxRetries` fallback is reachable
            // only while `nodeConfig` is nil. Showing 0 there claimed "no retries" for a node the
            // engine would retry, on the one control whose own explainer warns about duplicated
            // tool side effects.
            get: { node.nodeConfig?.maxNodeRetries ?? inheritedRetryDefault },
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
            header
            Divider()
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
            minWidth: 800,
            idealWidth: 950,
            maxWidth: .infinity,
            minHeight: 540,
            idealHeight: 680,
            maxHeight: .infinity
        )
        .background(theme.primaryBackground)
        .onAppear {
            loadFromNode()
            if editBuffer == nil, let profile {
                editBuffer = ProfileEditBuffer(profile: profile)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: profileIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.accentColor)
            // Editable node label — mirrors the inline-rename pattern from
            // `AgentConfigDetailView`'s identity header. The node's name is
            // independent of the underlying agent profile's name; a node
            // can use the same profile but display a role-specific label.
            TextField("Node Name", text: $node.displayName)
                .font(.system(size: 14, weight: .semibold))
                .textFieldStyle(.plain)
                .foregroundColor(theme.primaryText)
            Spacer()

            if let editBuffer, editBuffer.isDirty {
                GlassActionButton(title: "Revert Profile", icon: "arrow.counterclockwise", isAccent: false) {
                    editBuffer.revert()
                    inlineProfileError = nil
                }
            }

            // ⚠️ WF-CU9. This inspector was the ONE of five with no Cancel — see `isValid`'s comment
            // above, which names the trap: "the panel is borderless, always-on-top and has no
            // Cancel, so the only exits were typing text the user did not want or double-clicking
            // another node — impossible on a one-node canvas." That escape hatch needs the CANVAS,
            // which a run's auto-flip to Execution removes, so an empty task description left the
            // user with a floating panel, a disabled Done and nothing to click. Discarding on
            // Cancel is exactly what the other four inspectors already do — including discarding an
            // unsaved `ProfileEditBuffer`.
            GlassActionButton(title: "Cancel", icon: "xmark", isAccent: false) {
                // Cancel is the ONE explicit discard (Phase 2, option C) — clear the teardown
                // commit first, or the close it triggers would save the very edits being discarded.
                NodeInspectorPendingCommit.shared.clear()
                // [INS-2] …and put back what the write-through controls already committed. Without
                // this, Cancel discarded only the profile buffer while the node KEPT every
                // orchestration override and the rename — so "Cancel" left a 120s timeout and 3
                // retries on a node, which the next unrelated Save writes to disk.
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
                        // [CVV-7] "Hard Timeout" is the MODEL property name — the control 58 lines
                        // below is labelled "Per-Node Timeout", so this line sent the user hunting
                        // for a setting that appears on no screen, in the very panel that holds it.
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
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.blue)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Workflow Orchestration Card
    //
    // These are *workflow-layer* concerns — what happens around this node as
    // part of the DAG. They do NOT duplicate the agent profile's own
    // "Execution" settings (max iterations, parse-retries, history strategy,
    // etc.), which still control how the agent behaves *inside* one run.

    private var nodeConfigCard: some View {
        SettingsCard(title: "Workflow Orchestration", icon: "gearshape", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                Text("These overrides apply only to this node's role in the workflow. The agent's own Execution settings (max iterations, parse-retries, etc.) stay untouched.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .padding(.bottom, 4)

                // Per-Node Timeout (optional; "Default" + Set button vs Stepper + Remove)
                behaviorRow(
                    label: "Per-Node Timeout",
                    explainer: "Overrides the agent's Execution Timeout for this node only."
                ) {
                    timeoutControl
                }

                Divider().opacity(0.3)

                // Node-Level Retries
                behaviorRow(
                    label: "Node-Level Retries",
                    // ⚠️ Honest as of 2026-08-19. This stepper was rendered for sub-workflow nodes
                    // and did NOTHING for them (§9 N4) — they are dispatched structurally and that
                    // path had no retry loop. It now retries, which for a nested workflow means the
                    // ENTIRE child re-runs, so the explainer says so: a child that already sent a
                    // message or wrote a file does it again. Surfaced, not enforced — the retry
                    // count you set is always honoured.
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
                    Divider().opacity(0.3)

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

                // [WF-SE6/SE11] The EXPLICIT unattended approval — the sanctioned way to let a
                // scheduled run use a confirming tool. An interactive "Allow for this chat" grant
                // is never served to a run nobody can answer.
                //
                // ⚠️ HIDDEN on sub-workflow nodes: they dispatch STRUCTURALLY and never build a
                // `WorkflowExecutionContext`, so nothing reads THIS node's setting — the child
                // graph's own nodes carry their own. Rendering it there would persist a
                // security-relevant toggle that silently does nothing, which is worse than absent.
                if !isSubWorkflowNode {
                    Divider().opacity(0.3)

                    behaviorRow(
                        label: "Unattended Auto-Approve",
                        // ⚠️ Wording deliberately differs from the Action node's twin row. On the
                        // AGENT path a refused confirmation returns a failed OBSERVATION to the
                        // agent, which keeps running and usually still answers — the node does NOT
                        // fail onto its error port (only the Action arm does that). Promising an
                        // error port here would have users wire a branch that never fires.
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

    /// Per-node timeout control. Mirrors the agent's `ExecutionLimitsSection`
    /// pattern: "Default" with a Set button (nil state) vs stepper + Remove
    /// button (explicit state). Default = inherits `WorkflowConfig.resolvedNodeTimeout` —
    /// EXCEPT for a sub-workflow node (WF-EX3), where "Default" means NO outer ceiling at all;
    /// its child canvas already bounds every one of its own nodes independently. Pressing "Set"
    /// still seeds 120s as a starting point to adjust, same as any other node kind.
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
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Text(explainer)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
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
                            .font(.system(size: 11))
                        Text(error)
                            .font(theme.fontCaption)
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

    /// Shown when this node's backing row cannot be resolved.
    ///
    /// ⚠️ The copy is KIND-SPECIFIC because the remedy is. A bot/agent node OWNS its configuration
    /// (a private profile row created when the node was added), so re-adding the node genuinely
    /// fixes it. The sentence is `WorkflowValidator.missingConfigurationMessage` — SHARED, not
    /// copied, so this card and the validation panel cannot drift into describing what looks like
    /// two different problems.
    ///
    /// A SUB-WORKFLOW node is different: it REFERENCES another workflow's canvas, which is a real
    /// thing the user may still want back. Telling them to delete and re-add would discard the only
    /// record of which workflow this step ran, so it names the situation instead.
    ///
    /// ⚠️ This replaced "Profile not found or was deleted." — accurate once, but passive, and it
    /// described a dead end that no longer exists: before nodes owned their configuration there was
    /// nothing the user could do from here at all.
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
                    .font(.system(size: 11))
                    .foregroundColor(theme.errorColor)
                    .fixedSize(horizontal: false, vertical: true)

                Text(isSubWorkflowNode
                     ? "Its steps lived on that workflow's own canvas, so they cannot be recovered from here."
                     : "Its model, instructions and tools were stored with this node and are not recoverable.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }

    private var subWorkflowCard: some View {
        SettingsCard(title: "Sub-Workflow Canvas", icon: "arrow.triangle.branch", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                Text("This node executes the nested workflow '\(editBuffer?.draft.displayName ?? "Workflow")'. Its steps, nodes, and routing logic are authored directly on that workflow's canvas.")
                    .font(theme.fontBody)
                    .foregroundColor(theme.secondaryText)

                Text("To modify the sub-workflow's execution graph, open it from the Workflows sidebar.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(16)
        }
    }

    private var codeProfileCard: some View {
        SettingsCard(title: "Code Session", icon: "chevron.left.forwardslash.chevron.right", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Code sessions are configured via the Code interface.")
                    .font(theme.fontBody)
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
        // Nothing node-local left to load — the Node Task field was removed 2026-08-29 and the
        // orchestration fields below bind straight through to `node.nodeConfig`.

        // ⚠️ Register the teardown commit (Phase 2, option C). Three close routes bypass Done —
        // node deletion, a superseding inspector, and canvas teardown (including the Run
        // auto-flip) — and each used to discard the buffered profile draft silently. The closure
        // captures the CLASS instances (`ProfileEditBuffer`, the service), so it reads the live
        // draft at fire time; Done and Cancel clear it first, keeping their own semantics.
        if let editBuffer {
            let service = profileService
            let nodeName = node.displayName
            NodeInspectorPendingCommit.shared.register {
                Self.commitBufferedEdits(editBuffer, service: service, nodeDisplayName: nodeName)
            }
        }
    }

    /// Persists a dirty buffered draft on a close route that bypassed Done.
    ///
    /// ⚠️ Static and headless: the panel is gone (or going) when this fires, so there is no UI to
    /// show a validation error in — a refused save is LOGGED with its consequence rather than
    /// silently swallowed or crashed on. The instructions-missing rule is deliberately NOT applied
    /// here the way Done applies it: Done can refuse and stay open for the user to fix; a teardown
    /// cannot, and discarding the whole draft over a transiently empty field would reintroduce the
    /// exact loss this commit exists to prevent. `saveProfile`'s own validation still runs.
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
            // The rebase contract (`BackendProfileService.rebaseEditBuffer`'s doc): every
            // out-of-band save must rebase any open editor buffer. Matters for the sub-workflow
            // kind, whose draft IS the shared workflow profile.
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
        // ⚠️ Break the coalescing run FIRST. The restore writes through the same binding — and so the
        // same `coalescingKey` — as the edits it is undoing, and `pushUndoSnapshot` folds writes to
        // one node inside a 3s window. Inside the window the restore left a no-op step on the stack;
        // outside it, the snapshot captured the EDITED graph and ⌘Z re-applied what the user had just
        // cancelled.
        endCoalescingRun()
        node = restored
    }

    private func saveAndDismiss() {
        // [INS-11] The `if node.nodeConfig == nil { node.nodeConfig = WorkflowNodeConfig() }` that
        // stood here is GONE. Every orchestration control already calls `ensureNodeConfig()` on a
        // real write, so nothing below needs it — its only effect was to turn `nil` into
        // `.some(defaults)` on a Done the user made without editing anything, which
        // `replaceNode`'s equality guard cannot absorb. That dirtied the canvas, burned an undo
        // slot, AND pinned a legacy workflow's inherited retry budget to 0, because
        // `maxNodeRetries` is non-optional and the executor's `?? resolvedMaxRetries` fallback is
        // reachable only while `nodeConfig` is nil.
        // If profile was edited, validate and save
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

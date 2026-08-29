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

struct ProfileNodeInspectorView: View {
    @Binding var node: WorkflowNode
    let profile: BackendProfileModel?
    @Environment(\.closeNodeInspector) private var closeInspector
    @Environment(BackendProfileService.self) private var profileService
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme

    // MARK: - State

    @State private var showGuide: Bool = false
    @State private var editBuffer: ProfileEditBuffer?
    @State private var inlineProfileError: String?

    // MARK: - Init

    init(node: Binding<WorkflowNode>, profile: BackendProfileModel?) {
        self._node = node
        self.profile = profile
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
        if node.nodeConfig == nil {
            node.nodeConfig = WorkflowNodeConfig()
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
            GlassActionButton(title: "Cancel", icon: "xmark", isAccent: false) { closeInspector() }

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
                        profileGuideLine("⚠️ Unlike every other node kind, \"Default\" here means NO timeout at all — the child canvas already bounds every one of its own nodes on its own terms. Setting the Hard Timeout below adds a ceiling over the child's ENTIRE run, not one step, and — with retries configured — ALL attempts share that ONE ceiling rather than each getting its own.")
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
            SettingsCard(title: "Profile", icon: "person.circle", theme: theme) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Profile not found or was deleted.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.errorColor)
                }
                .padding(16)
            }
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
    }

    private func saveAndDismiss() {
        // Ensure nodeConfig exists before saving
        if node.nodeConfig == nil {
            node.nodeConfig = WorkflowNodeConfig()
        }

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
                inlineProfileError = nil
            } catch {
                inlineProfileError = error.localizedDescription
                toastManager.show(error.localizedDescription, style: .error)
                return
            }
        }

        closeInspector()
    }
}

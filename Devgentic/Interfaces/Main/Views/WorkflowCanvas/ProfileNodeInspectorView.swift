//
//  ProfileNodeInspectorView.swift
//  Devgentic
//
//  Created by Claude on 13/04/26.
//
//  Inspector sheet for profile-backed workflow nodes (Bot, Agent, Workflow, ImageGen).
//  Three cards:
//    1. Node Task — per-node directive ("what this node does"). Combined with
//       the agent's system prompt at run time. Persona stays on the profile;
//       the task changes per node.
//    2. Workflow Orchestration — node-level overrides for failure cascade,
//       timeout, and whole-node retries. These are workflow-layer concerns
//       and do *not* duplicate the agent's own Execution settings (which
//       govern within-execution behaviour like parse-retry).
//    3. Profile — the agent identity; "Edit Profile" opens the full agent
//       config editor (persona, model, tools, history strategy, etc.).
//

import SwiftUI

struct ProfileNodeInspectorView: View {
    @Binding var node: WorkflowNode
    let profile: BackendProfileModel?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    // MARK: - Constants

    private static let maxTaskDescriptionLength: Int = 500

    // MARK: - State

    @State private var taskDescription: String = ""
    @State private var showProfileEditor: Bool = false

    /// Trimmed task description for validation.
    private var trimmedTaskDescription: String {
        taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedTaskDescription.isEmpty
    }

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

    private var failurePolicyBinding: Binding<NodeFailurePolicy> {
        Binding(
            get: { node.nodeConfig?.onFailure ?? .skipDependents },
            set: { newValue in
                ensureNodeConfig()
                node.nodeConfig?.onFailure = newValue
            }
        )
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

    private var retryDelayBinding: Binding<TimeInterval> {
        Binding(
            get: { node.nodeConfig?.retryDelay ?? 0 },
            set: { newValue in
                ensureNodeConfig()
                node.nodeConfig?.retryDelay = max(0, min(newValue, 60))
            }
        )
    }

    private var joinModeBinding: Binding<JoinMode> {
        Binding(
            get: { node.nodeConfig?.joinMode ?? .all },
            set: { newValue in
                ensureNodeConfig()
                node.nodeConfig?.joinMode = newValue
            }
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    taskDescriptionCard
                    nodeConfigCard
                    JoinModeCard(joinMode: joinModeBinding)
                    profileCard
                }
                .padding(24)
            }
        }
        .frame(width: 560, height: 540)
        .background(theme.primaryBackground)
        .onAppear { loadFromNode() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: profileIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.accentColor)
            // Editable node label — mirrors the inline-rename pattern from
            // `AgentConfigDetailView`'s identity header. The node's name is
            // independent of the underlying agent profile's name (which is
            // edited via the Profile card's "Edit Profile" sheet); a node
            // can use the same profile but display a role-specific label.
            TextField("Node Name", text: $node.displayName)
                .font(.system(size: 14, weight: .semibold))
                .textFieldStyle(.plain)
                .foregroundColor(theme.primaryText)
            Spacer()
            Button("Done") { saveAndDismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!isValid)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Task Description Card

    private var taskDescriptionCard: some View {
        /// Approaching limit: warn at 90%+ usage
        let isNearLimit = taskDescription.count >= (Self.maxTaskDescriptionLength * 9 / 10)

        return SettingsCard(title: "Node Task (Required)", icon: "text.alignleft", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What this node should do with its input. Combined at run time with the agent's persona — the task changes per node; the agent profile stays the same.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $taskDescription)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120, maxHeight: 200)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.secondaryBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    trimmedTaskDescription.isEmpty ? theme.warningColor.opacity(0.4)
                                    : theme.surfaceOverlayStrong.opacity(0.3),
                                    lineWidth: trimmedTaskDescription.isEmpty ? 1 : 0.5
                                )
                        )
                        .onChange(of: taskDescription) { _, newValue in
                            // Enforce hard limit — prevent typing beyond max
                            if newValue.count > Self.maxTaskDescriptionLength {
                                taskDescription = String(newValue.prefix(Self.maxTaskDescriptionLength))
                            }
                        }

                    if taskDescription.isEmpty {
                        Text("Describe what this node should do with the provided input...")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

                HStack {
                    if trimmedTaskDescription.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(theme.warningColor)
                        Text("Node task is required")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.warningColor)
                    }
                    Spacer()
                    Text("\(taskDescription.count)/\(Self.maxTaskDescriptionLength)")
                        .font(.system(size: 10))
                        .foregroundColor(isNearLimit ? theme.warningColor : theme.tertiaryText)
                }
            }
        }
    }

    // MARK: - Workflow Orchestration Card
    //
    // These are *workflow-layer* concerns — what happens around this node as
    // part of the DAG. They do NOT duplicate the agent profile's own
    // "Execution" settings (max iterations, parse-retries, history strategy,
    // etc.), which still control how the agent behaves *inside* one run.
    // For agent-side knobs, use "Edit Profile" below.

    private var nodeConfigCard: some View {
        SettingsCard(title: "Workflow Orchestration", icon: "gearshape", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                Text("These overrides apply only to this node's role in the workflow. The agent's own Execution settings (max iterations, parse-retries, etc.) stay untouched.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .padding(.bottom, 4)

                // On Failure → Downstream
                behaviorRow(
                    label: "On Failure → Downstream",
                    explainer: "What happens to downstream nodes when this one fails."
                ) {
                    Picker("", selection: failurePolicyBinding) {
                        ForEach(NodeFailurePolicy.allCases, id: \.self) { policy in
                            Text(displayName(for: policy)).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                Divider().opacity(0.3)

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
                    explainer: "Re-runs the whole node from scratch. Independent of the agent's parse-retry policy."
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
            }
        }
    }

    /// Per-node timeout control. Mirrors the agent's `ExecutionLimitsSection`
    /// pattern: "Default" with a Set button (nil state) vs stepper + Remove
    /// button (explicit state). Default = inherits `WorkflowConfig.resolvedNodeTimeout`.
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
                    in: 10...600,
                    step: 10
                )
                .fixedSize()

                Button("Reset") {
                    hardTimeoutBinding.wrappedValue = nil
                }
                .font(.system(size: 10))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            HStack(spacing: 8) {
                Text("Default")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                Button("Set") {
                    hardTimeoutBinding.wrappedValue = 120
                }
                .font(.system(size: 10))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// One row of the Workflow Orchestration card. Label + small explainer on
    /// the left so the meaning is unambiguous; control flush-right (Picker /
    /// Stepper / context-specific button group).
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

    /// Display label for a NodeFailurePolicy — used only inside the Picker's
    /// ForEach. The data model stores raw values; this is purely cosmetic.
    private func displayName(for policy: NodeFailurePolicy) -> String {
        switch policy {
        case .skipDependents: return "Skip Dependents"
        case .stopWorkflow:   return "Stop Workflow"
        case .continueAll:    return "Continue All"
        }
    }

    // MARK: - Profile Card

    private var profileCard: some View {
        SettingsCard(title: "Profile", icon: "person.circle", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                if let profile = profile {
                    HStack {
                        Text(profile.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        Text(profile.profileType.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(theme.accentColor.opacity(0.1))
                            )
                    }

                    Button {
                        showProfileEditor = true
                    } label: {
                        Label("Edit Profile", systemImage: "pencil.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Text("Profile not found")
                        .font(.system(size: 11))
                        .foregroundColor(theme.errorColor)
                }
            }
        }
        .sheet(isPresented: $showProfileEditor) {
            if let profile = profile {
                WorkflowProfileEditorView(profile: profile)
            }
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
        taskDescription = node.nodeConfig?.taskDescription ?? ""
    }

    private func saveAndDismiss() {
        // Ensure nodeConfig exists before saving
        if node.nodeConfig == nil {
            node.nodeConfig = WorkflowNodeConfig()
        }
        // Trim whitespace to prevent spaces-only from passing validation downstream
        node.nodeConfig?.taskDescription = trimmedTaskDescription
        dismiss()
    }
}

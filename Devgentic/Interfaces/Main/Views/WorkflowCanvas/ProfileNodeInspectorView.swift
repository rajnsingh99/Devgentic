//
//  ProfileNodeInspectorView.swift
//  Devgentic
//
//  Created by Claude on 13/04/26.
//
//  Inspector sheet for profile-backed workflow nodes (Bot, Agent, Workflow, ImageGen).
//  Provides a task description editor (per-node directive for workflow execution)
//  and a button to open the full profile editor for persona/model configuration.
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

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    taskDescriptionCard
                    nodeConfigCard
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
            Text(node.displayName)
                .font(.system(size: 14, weight: .semibold))
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

        return SettingsCard(title: "Task Description (Required)", icon: "text.alignleft", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Define what this node should do with its input. This is the primary directive for workflow execution.")
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
                        Text("Task description is required")
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

    // MARK: - Node Config Card

    private var nodeConfigCard: some View {
        SettingsCard(title: "Execution", icon: "gearshape", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Failure Policy")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    Text(failurePolicyLabel)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
                HStack {
                    Text("Timeout")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    Text(timeoutLabel)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
                HStack {
                    Text("Retries")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    Text("\(node.nodeConfig?.maxNodeRetries ?? 0)")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }
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

    private var failurePolicyLabel: String {
        switch node.nodeConfig?.onFailure ?? .skipDependents {
        case .skipDependents: return "Skip Dependents"
        case .stopWorkflow: return "Stop Workflow"
        case .continueAll: return "Continue All"
        }
    }

    private var timeoutLabel: String {
        if let timeout = node.nodeConfig?.hardTimeout {
            return "\(Int(timeout))s"
        }
        return "Default"
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

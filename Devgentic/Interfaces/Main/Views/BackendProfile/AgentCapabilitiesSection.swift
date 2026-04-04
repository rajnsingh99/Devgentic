//
//  AgentCapabilitiesSection.swift
//  Devgentic
//
//  Created for Agent Capabilities Migration (Phase 0).
//  Replaces the architecture picker with composable capability toggles.
//

import SwiftUI

struct AgentCapabilitiesSection: View {
    @Binding var capabilities: AgentCapabilities
    @Environment(\.appTheme) private var theme

    @State private var editingSubAgent: SubAgentConfig?
    @State private var showAddSubAgent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // MARK: - Planning

            capabilityToggle(
                label: "Planning",
                icon: "list.bullet.indent",
                description: "Plan before acting. Breaks task into subtasks.",
                isOn: Binding(
                    get: { capabilities.planning != nil },
                    set: { capabilities.planning = $0 ? PlanningCapabilityConfig() : nil }
                )
            ) {
                if var planning = capabilities.planning {
                    // Max subtasks
                    settingsRow(
                        title: "Max Subtasks",
                        description: "Maximum number of subtasks the planner can generate."
                    ) {
                        Stepper(
                            "\(planning.maxSubtasks)",
                            value: Binding(
                                get: { planning.maxSubtasks },
                                set: { newVal in
                                    planning.maxSubtasks = newVal
                                    capabilities.planning = planning
                                }
                            ),
                            in: 2...10
                        )
                        .fixedSize()
                    }

                    Divider().background(theme.dividerColor)

                    // Parallel subtasks
                    settingsRow(
                        title: "Parallel Subtasks",
                        description: "Run independent subtasks concurrently for faster execution."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { planning.parallelSubtasks },
                            set: { newVal in
                                planning.parallelSubtasks = newVal
                                capabilities.planning = planning
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    }

                    Divider().background(theme.dividerColor)

                    // Tool filtering
                    settingsRow(
                        title: "Tool Filtering",
                        description: "Give each subtask only its relevant tools to reduce noise."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { planning.subtaskToolFiltering },
                            set: { newVal in
                                planning.subtaskToolFiltering = newVal
                                capabilities.planning = planning
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    }

                    Divider().background(theme.dividerColor)

                    // Require plan approval
                    settingsRow(
                        title: "Require Plan Approval",
                        description: "Review and edit the generated plan before execution begins."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { planning.requiresPlanApproval },
                            set: { newVal in
                                planning.requiresPlanApproval = newVal
                                capabilities.planning = planning
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    }
                }
            }

            Divider().background(theme.dividerColor)

            // MARK: - Self-Reflection

            capabilityToggle(
                label: "Self-Reflection",
                icon: "arrow.trianglehead.2.counterclockwise",
                description: "Evaluate and retry with critique.",
                isOn: Binding(
                    get: { capabilities.selfReflection != nil },
                    set: { capabilities.selfReflection = $0 ? SelfReflectionConfig() : nil }
                )
            ) {
                if var reflection = capabilities.selfReflection {
                    settingsRow(
                        title: "Max Retries",
                        description: "Number of reflection trials before accepting the result."
                    ) {
                        Stepper(
                            "\(reflection.maxTrials)",
                            value: Binding(
                                get: { reflection.maxTrials },
                                set: { newVal in
                                    reflection.maxTrials = newVal
                                    capabilities.selfReflection = reflection
                                }
                            ),
                            in: 1...5
                        )
                        .fixedSize()
                    }
                }
            }

            Divider().background(theme.dividerColor)

            // MARK: - Agent Delegation

            capabilityToggle(
                label: "Agent Delegation",
                icon: "person.2.fill",
                description: "Delegate subtasks to inline sub-agents.",
                isOn: Binding(
                    get: { capabilities.agentDelegation != nil },
                    set: { capabilities.agentDelegation = $0 ? AgentDelegationConfig() : nil }
                )
            ) {
                if var delegation = capabilities.agentDelegation {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Sub-Agents")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(theme.primaryText)
                                Text("Specialist agents this agent can delegate tasks to.")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.secondaryText)
                            }
                            Spacer(minLength: 16)
                            Button {
                                showAddSubAgent = true
                            } label: {
                                Label("Add", systemImage: "plus.circle")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        if delegation.subAgents.isEmpty {
                            Text("No sub-agents configured yet.")
                                .font(.caption2)
                                .foregroundColor(theme.secondaryText)
                                .italic()
                                .padding(.vertical, 2)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(delegation.subAgents) { agent in
                                        SubAgentChipView(
                                            subAgent: agent,
                                            onConfigure: {
                                                editingSubAgent = agent
                                            },
                                            onDelete: {
                                                delegation.subAgents.removeAll { $0.id == agent.id }
                                                capabilities.agentDelegation = delegation
                                            }
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .sheet(isPresented: $showAddSubAgent) {
                        let newAgent = SubAgentConfig()
                        SubAgentConfigView(
                            subAgent: .constant(newAgent),
                            isNew: true,
                            onSave: { saved in
                                delegation.subAgents.append(saved)
                                capabilities.agentDelegation = delegation
                                showAddSubAgent = false
                            },
                            onCancel: { showAddSubAgent = false }
                        )
                    }
                    .sheet(item: $editingSubAgent) { agent in
                        let index = delegation.subAgents.firstIndex(where: { $0.id == agent.id })
                        if let index {
                            SubAgentConfigView(
                                subAgent: Binding(
                                    get: { delegation.subAgents[index] },
                                    set: { newVal in
                                        delegation.subAgents[index] = newVal
                                        capabilities.agentDelegation = delegation
                                    }
                                ),
                                isNew: false,
                                onSave: { _ in
                                    editingSubAgent = nil
                                },
                                onCancel: { editingSubAgent = nil }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Capability Toggle Component

    @ViewBuilder
    private func capabilityToggle(
        label: String,
        icon: String,
        description: String,
        isOn: Binding<Bool>,
        @ViewBuilder detail: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Toggle row — icon + labels on left, switch on right
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(isOn.wrappedValue ? .accentColor : theme.secondaryText)
                    .frame(width: 24, alignment: .center)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text(description)
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 16)

                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(.accentColor)
            }

            // Expanded detail — inside a nested card for visual distinction
            if isOn.wrappedValue {
                VStack(spacing: 0) {
                    detail()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.secondaryBackground.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.surfaceOverlayStrong.opacity(0.6), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.leading, 34)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isOn.wrappedValue)
    }

    // MARK: - Settings Row (matches SettingsRow pattern from GeneralSettingsView)

    @ViewBuilder
    private func settingsRow<Control: View>(
        title: String,
        description: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            VStack {
                Spacer(minLength: 0)
                control()
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

//
//  AgentCapabilitiesSection.swift
//  Devgentic
//
//  Created for Agent Capabilities Migration (Phase 0).
//  Replaces the architecture picker with composable capability toggles.
//

import SwiftUI

private let logger = DGLogger(category: "AgentCapabilities")

struct AgentCapabilitiesSection: View {
    @Binding var capabilities: AgentCapabilities
    @Environment(\.appTheme) private var theme

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

                    // Parallel subtasks — HIDDEN from UI
                    // Parallel subtask execution serializes at the LLM layer (single GPU for
                    // local models, rate-limited for cloud). The parallelism is illusory and
                    // adds complexity without throughput gain. The config field is preserved
                    // for future use when batch inference or multi-model routing makes true
                    // parallelism viable.
                    //
                    // ⚠️ Register A67. This comment used to end "Default is forced to false
                    // below" — and nothing below forced anything. The tolerant decoder defaults
                    // the field only when the key is ABSENT, so a profile saved while the toggle
                    // still existed decoded `true` and took the parallel branch, uncontrollably.
                    // Enforcement now lives at the consumption point, in
                    // `PlanningCapability.parallelSubtasksSupported` — one constant to flip when
                    // parallelism becomes real. A stored `true` is logged and ignored, not
                    // rewritten, so the preference survives for that day.

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

                    // Clarify before planning
                    settingsRow(
                        title: "Clarify Before Planning",
                        description: "Let the planner ask you one question when the task is too vague to plan."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { planning.clarifyBeforePlanning },
                            set: { newVal in
                                planning.clarifyBeforePlanning = newVal
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

            // MARK: - Agent Delegation — HIDDEN from UI, except as an OFF switch
            // Agent delegation spawns concurrent sub-agents that all share the same LLM.
            // On local models (MLX/Ollama) this serializes at the GPU actor, and on cloud
            // providers it competes with the parent for rate-limit tokens. The result is
            // illusory parallelism with added overhead. Hidden until true parallel inference
            // (batch, multi-model, or dedicated cloud concurrency) is supported.
            // The backend code (CallAgentTool, ConcurrencyLimiter, AgentConnect injection)
            // is fully implemented and preserved — only the UI toggle is removed.
            //
            // ⚠️ Register A66. Removing the toggle removed the OFF switch too, and the gate in
            // `AgentConnect.resolveTools` is the mere PRESENCE of `capabilities.agentDelegation`
            // — there is no `isEnabled` flag. `ProfileMigrator` created that config for legacy
            // "Supervisor" profiles, so those agents inject `call_agent` on every single run,
            // permanently, with nothing on screen to say so and no way to stop it.
            //
            // ⚠️ This row appears ONLY when the profile already has delegation, and turning it
            // off nils the config so the row disappears for good. That gives existing profiles
            // control without re-offering the capability to new ones — which is what the hide
            // decision above is about. It is not a toggle; it is an exit.
            if capabilities.agentDelegation != nil {
                Divider().background(theme.dividerColor)

                settingsRow(
                    title: "Agent Delegation",
                    description: "This agent can spawn sub-agents (call_agent). Devgentic no longer offers this — sub-agents share one model, so they queue rather than run in parallel. Turning it off removes the tool; it can't be turned back on."
                ) {
                    Button("Turn Off") {
                        logger.notice(
                            "[PROFILE] User turned OFF agent delegation for this profile. "
                            + "CONSEQUENCE: `call_agent` will no longer be injected on runs, and the "
                            + "capability cannot be re-enabled from the UI — it is hidden by design."
                        )
                        capabilities.agentDelegation = nil
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Turn off agent delegation")
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
                    .font(.system(.body))
                    .foregroundColor(isOn.wrappedValue ? .accentColor : theme.secondaryText)
                    .frame(width: 24, alignment: .center)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(theme.fontBody.weight(.medium))
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
                    .font(theme.fontSubheadline.weight(.medium))
                    .foregroundColor(theme.primaryText)
                Text(description)
                    .font(.system(.caption))
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

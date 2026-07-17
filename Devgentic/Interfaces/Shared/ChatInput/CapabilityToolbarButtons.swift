//
//  CapabilityToolbarButtons.swift
//  Devgentic
//
//  Composer-level quick access to an agent profile's Planning and Self-Reflection
//  capabilities: two icon buttons beside the backend selector. Each shows the
//  capability's on/off state at a glance and opens a popover to enable/disable and
//  configure it. Changes persist to the profile immediately, so the next send
//  honors them (getRequestConfig() re-reads the profile from the store by ID).
//
//  Only rendered for `.agent` profiles — planning/reflection are agent-only
//  capabilities (bot/workflow/imageGen don't stack them; code mode runs plain ReAct).
//

import SwiftUI

struct CapabilityToolbarButtons: View {
    /// The composer's selected profile. A binding so a toggle updates the composer's
    /// state (instant chip refresh) in addition to persisting to the store.
    @Binding var profile: BackendProfileModel?
    /// Dimmed + disabled while a request is in flight (mirrors the picker).
    var isEnabled: Bool = true

    @Environment(\.appTheme) private var theme

    /// The agent config, when the selected profile is an agent — otherwise nil and
    /// the whole control renders nothing.
    private var agentConfig: AgentConfig? {
        guard let profile, case .agent(let cfg) = profile.details else { return nil }
        return cfg
    }

    var body: some View {
        if let cfg = agentConfig {
            HStack(spacing: 4) {
                CapabilityChipButton(
                    color: .planning,
                    icon: "list.bullet.clipboard",
                    label: "Planning",
                    isOn: cfg.capabilities.planning != nil,
                    isEnabled: isEnabled
                ) {
                    PlanningCapabilityPopover(capabilities: capabilitiesBinding)
                }

                CapabilityChipButton(
                    color: .reflection,
                    icon: "arrow.trianglehead.2.counterclockwise",
                    label: "Self-Reflection",
                    isOn: cfg.capabilities.selfReflection != nil,
                    isEnabled: isEnabled
                ) {
                    ReflectionCapabilityPopover(capabilities: capabilitiesBinding)
                }
            }
        }
    }

    /// A binding into the profile's `AgentCapabilities`. Reads derive from the current
    /// profile; writes mutate the profile in place, push it back to the composer's
    /// state, and persist — so a change is reflected instantly and effective next send.
    private var capabilitiesBinding: Binding<AgentCapabilities> {
        Binding(
            get: { agentConfig?.capabilities ?? AgentCapabilities() },
            set: { newCaps in
                guard var updated = profile, case .agent(var cfg) = updated.details else { return }
                cfg.capabilities = newCaps
                updated.details = .agent(cfg)
                profile = updated
                do {
                    try BackendProfileStore.shared.saveProfile(updated)
                } catch {
                    // Non-fatal: the in-memory toggle still took effect for this session;
                    // it just didn't persist (e.g. a transient validation/store error).
                    DGLogger(category: "CapabilityToolbar").warning(
                        "Failed to persist capability change: \(error.localizedDescription)")
                }
            }
        )
    }
}

// MARK: - Chip Button

private struct CapabilityChipButton<PopoverContent: View>: View {
    let color: CapabilityMilestoneKind.MilestoneColor
    let icon: String
    let label: String
    let isOn: Bool
    let isEnabled: Bool
    @ViewBuilder let popover: () -> PopoverContent

    @State private var showing = false
    @State private var hovering = false
    @Environment(\.appTheme) private var theme

    private var tint: Color { theme.capabilityColor(for: color) }

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isOn ? tint : theme.secondaryText.opacity(0.8))
                .frame(width: 15, height: 15)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isOn ? tint.opacity(0.14) : (hovering ? theme.surfaceOverlay : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isOn ? tint.opacity(0.30) : Color.clear, lineWidth: 1)
                )
                .scaleEffect(hovering && isEnabled ? 1.04 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.5)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = h } }
        .popover(isPresented: $showing, arrowEdge: .bottom) { popover() }
        .help("\(label): \(isOn ? "On" : "Off") — tap to configure")
        .accessibilityLabel("\(label) capability, \(isOn ? "enabled" : "disabled"). Tap to configure.")
    }
}

// MARK: - Planning Popover

private struct PlanningCapabilityPopover: View {
    @Binding var capabilities: AgentCapabilities
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CapabilityPopoverHeader(
                icon: "list.bullet.clipboard",
                title: "Planning",
                subtitle: "Decompose the task into subtasks before acting.",
                color: theme.capabilityColor(for: .planning),
                isOn: Binding(
                    get: { capabilities.planning != nil },
                    set: { capabilities.planning = $0 ? (capabilities.planning ?? PlanningCapabilityConfig()) : nil }
                )
            )

            if let planning = capabilities.planning {
                Divider().background(theme.dividerColor.opacity(0.4))

                CapabilityRow(title: "Max subtasks", subtitle: "Cap on generated steps.") {
                    Stepper(
                        "\(planning.maxSubtasks)",
                        value: Binding(
                            get: { planning.maxSubtasks },
                            set: { var p = planning; p.maxSubtasks = $0; capabilities.planning = p }
                        ),
                        in: 2...10
                    )
                    .fixedSize()
                }

                CapabilityToggleRow(
                    title: "Tool filtering",
                    subtitle: "Give each subtask only its relevant tools.",
                    isOn: Binding(
                        get: { planning.subtaskToolFiltering },
                        set: { var p = planning; p.subtaskToolFiltering = $0; capabilities.planning = p }
                    )
                )

                CapabilityToggleRow(
                    title: "Clarify before planning",
                    subtitle: "Ask one question when the task is too vague.",
                    isOn: Binding(
                        get: { planning.clarifyBeforePlanning },
                        set: { var p = planning; p.clarifyBeforePlanning = $0; capabilities.planning = p }
                    )
                )

                CapabilityToggleRow(
                    title: "Require plan approval",
                    subtitle: "Review and edit the plan before it runs.",
                    isOn: Binding(
                        get: { planning.requiresPlanApproval },
                        set: { var p = planning; p.requiresPlanApproval = $0; capabilities.planning = p }
                    )
                )
            }
        }
        .padding(16)
        .frame(width: 288)
    }
}

// MARK: - Reflection Popover

private struct ReflectionCapabilityPopover: View {
    @Binding var capabilities: AgentCapabilities
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CapabilityPopoverHeader(
                icon: "arrow.trianglehead.2.counterclockwise",
                title: "Self-Reflection",
                subtitle: "Evaluate the result and retry with critique.",
                color: theme.capabilityColor(for: .reflection),
                isOn: Binding(
                    get: { capabilities.selfReflection != nil },
                    set: { capabilities.selfReflection = $0 ? (capabilities.selfReflection ?? SelfReflectionConfig()) : nil }
                )
            )

            if let reflection = capabilities.selfReflection {
                Divider().background(theme.dividerColor.opacity(0.4))

                CapabilityRow(title: "Max retries", subtitle: "Reflection trials before accepting.") {
                    Stepper(
                        "\(reflection.maxTrials)",
                        value: Binding(
                            get: { reflection.maxTrials },
                            set: { var r = reflection; r.maxTrials = $0; capabilities.selfReflection = r }
                        ),
                        in: 1...5
                    )
                    .fixedSize()
                }
            }
        }
        .padding(16)
        .frame(width: 288)
    }
}

// MARK: - Shared popover pieces

private struct CapabilityPopoverHeader: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    @Binding var isOn: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(.body))
                .foregroundColor(isOn ? color : theme.secondaryText)
                .frame(width: 22, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.fontBody.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(color)
        }
    }
}

private struct CapabilityRow<Control: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let control: () -> Control
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.fontSubheadline.weight(.medium))
                    .foregroundColor(theme.primaryText)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
        }
    }
}

private struct CapabilityToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        CapabilityRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
        }
    }
}

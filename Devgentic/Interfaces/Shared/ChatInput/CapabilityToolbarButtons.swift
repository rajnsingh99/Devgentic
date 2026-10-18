// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CapabilityToolbarButtons.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Composer quick access to an agent profile's Planning and Self-Reflection capabilities: two icon buttons beside the
/// backend selector showing on/off state and opening a popover to configure. Changes persist to the profile
/// immediately; rendered only for `.agent` profiles.
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

    /// A binding into the profile's `AgentCapabilities`: reads derive from the current profile, and writes apply the
    /// capability delta to a freshly read row and persist. Writing the composer's cached snapshot back wholesale would
    /// revert edits made in the editor and could resurrect a deleted profile.
    private var capabilitiesBinding: Binding<AgentCapabilities> {
        Binding(
            get: { agentConfig?.capabilities ?? AgentCapabilities() },
            set: { newCaps in
                guard let cached = profile else { return }
                let logger = DGLogger(category: "CapabilityToolbar")

                // Re-read the row so the delta lands on current bytes, not on this view's cache.
                let stored: BackendProfileModel?
                do {
                    stored = try BackendProfileStore.shared.fetchProfile(byId: cached.id)
                } catch {
                    logger.error(
                        "[PROFILE] Could not re-read profile \(cached.id) before applying a "
                        + "capability change: \(error.localizedDescription). CONSEQUENCE: the "
                        + "toggle is not persisted — refusing to write a possibly stale snapshot "
                        + "over newer edits."
                    )
                    return
                }

                // Deleted out from under the composer. Writing here would recreate it.
                guard var updated = stored else {
                    logger.notice(
                        "[PROFILE] Capability change ignored — profile \(cached.id) no longer "
                        + "exists. CONSEQUENCE: the chip does not persist and the deleted profile "
                        + "is not resurrected; the composer still shows its cached name until a "
                        + "profile is reselected."
                    )
                    return
                }
                guard case .agent(var cfg) = updated.details else {
                    logger.notice(
                        "[PROFILE] Capability change ignored — stored profile \(cached.id) is no "
                        + "longer an agent. CONSEQUENCE: the toggle does not persist."
                    )
                    return
                }

                cfg.capabilities = newCaps
                updated.details = .agent(cfg)

                do {
                    // The advisories are logged rather than discarded, and deliberately not toasted: a chip toggle is instant and
                    // reversible, and the send path surfaces the user-facing version through `AdvisoryCenter`.
                    let advisories = try BackendProfileStore.shared.saveProfile(updated)
                    for advisory in advisories where advisory.severity == .advisory {
                        logger.notice(
                            "[PROFILE] Capability chip saved with an advisory for \(cached.id): "
                            + "\(advisory.message) CONSEQUENCE: the toggle took effect and was "
                            + "persisted; the advisory is surfaced to the user on the next send."
                        )
                    }
                    // Refresh the composer's cache from what was actually written, so the chip
                    // reflects disk and the next toggle starts from current bytes.
                    profile = updated
                } catch {
                    // Non-fatal, but the cache is not updated: the chip must not claim a state that is not on disk.
                    logger.warning(
                        "[PROFILE] Failed to persist capability change for \(cached.id): "
                        + "\(error.localizedDescription). CONSEQUENCE: the chip stays in its "
                        + "previous state and the change is not effective on the next send."
                    )
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

    private var activeShadowColor: Color {
        guard hovering && isEnabled else { return .clear }
        return isOn ? tint.opacity(0.4) : Color.black.opacity(0.2)
    }

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isOn ? tint : (hovering ? theme.primaryText : theme.secondaryText.opacity(0.85)))
                .frame(width: 13, height: 13)
                .padding(5.5)
                .composerControlSurface(
                    in: RoundedRectangle(cornerRadius: 6.5, style: .continuous),
                    isHovered: hovering && isEnabled,
                    isSelected: isOn,
                    selectedTint: tint
                )
                .shadow(color: activeShadowColor, radius: 4, x: 0, y: 1)
                .scaleEffect(hovering && isEnabled ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.5)
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hovering = h } }
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

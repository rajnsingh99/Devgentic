//
//  GateNodeInspectorView.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Configuration sheet for Gate (HITL) nodes — card-based layout.
//  Allows the user to edit the approval prompt, customize option labels,
//  and set an optional timeout.
//  Uses SettingsCard components for visual consistency with other inspector views.
//

import SwiftUI

struct GateNodeInspectorView: View {
    @Binding var node: WorkflowNode
    @Environment(\.closeNodeInspector) private var closeInspector
    @Environment(\.appTheme) private var theme

    @State private var prompt: String = "Approve this workflow step?"
    @State private var options: [String] = ["Approve", "Reject"]
    @State private var hasTimeout: Bool = false
    @State private var timeoutSeconds: Double = 300
    @State private var joinMode: JoinMode = .all
    @State private var showGuide: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    guideCard
                    approvalPromptCard
                    optionsCard
                    timeoutCard
                    JoinModeCard(joinMode: $joinMode)
                }
                .padding(24)
            }
        }
        .frame(
            minWidth: 800,
            idealWidth: 950,
            maxWidth: .infinity,
            minHeight: 560,
            idealHeight: 700,
            maxHeight: .infinity
        )
        .background(theme.primaryBackground)
        .onAppear { loadFromNode() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.red)
            Text("HITL Gate")
                .font(theme.fontSubheadline.weight(.semibold))
                .foregroundColor(theme.primaryText)
            Text("\u{00B7}")
                .foregroundColor(theme.tertiaryText)
            // Inline-editable node label — same pattern as the agent profile
            // editor's identity-header rename.
            TextField("Node Name", text: $node.displayName)
                .font(theme.fontCaption)
                .textFieldStyle(.plain)
                .foregroundColor(theme.secondaryText)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showGuide.toggle() }
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(theme.fontBody)
                    .foregroundColor(theme.secondaryText)
            }
            GlassActionButton(title: "Cancel", icon: "xmark", isAccent: false) { closeInspector() }
            GlassActionButton(title: "Save", icon: "checkmark", isAccent: true) { saveAndDismiss() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.secondaryBackground.opacity(0.5))
    }

    // MARK: - 1. Guide Card (Collapsible)

    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: $showGuide) {
                VStack(alignment: .leading, spacing: 12) {
                    guideStep(
                        number: "1",
                        title: "Approval Prompt",
                        subtitle: "user-facing",
                        description: "The text shown to the user when the workflow pauses for review.",
                        color: .red
                    )
                    guideStep(
                        number: "2",
                        title: "Options",
                        subtitle: "actions",
                        description: "Buttons presented to the user. The first option approves, others reject.",
                        color: .blue
                    )
                    guideStep(
                        number: "3",
                        title: "Timeout",
                        subtitle: "optional",
                        description: "Optionally auto-reject if the user doesn't respond in time.",
                        color: .orange
                    )

                    guideTip("The gate suspends the entire workflow execution until the user responds. Other parallel branches continue running.")
                }
                .padding(.top, 10)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed")
                        .font(.system(.caption, weight: .medium))
                        .foregroundColor(.red)
                    Text("How Gate Nodes Work")
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

    private func guideStep(number: String, title: String, subtitle: String, description: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(color))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(theme.fontCaption.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .italic()
                }
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func guideTip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .font(theme.fontCaption)
                .foregroundColor(.yellow)
                .padding(.top, 2)
            Text(text)
                .font(.system(.caption))
                .foregroundColor(theme.secondaryText)
                .italic()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.yellow.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.yellow.opacity(0.15), lineWidth: 0.5)
        )
    }

    // MARK: - 2. Approval Prompt Card

    private var approvalPromptCard: some View {
        SettingsCard(title: "Approval Prompt", icon: "text.bubble", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $prompt)
                    .font(.system(size: 13))
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                            .fill(theme.controlBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                            .stroke(theme.surfaceOverlayStrong.opacity(0.3), lineWidth: 0.5)
                    )
                Text("Shown to the user when the gate pauses execution.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    // MARK: - 3. Options Card

    private var optionsCard: some View {
        SettingsCard(title: "Options", icon: "list.bullet", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(options.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        Image(systemName: index == 0 ? "checkmark.circle" : "xmark.circle")
                            .foregroundColor(index == 0 ? .green : .red)
                            .font(.system(size: 14))
                        TextField("Option \(index + 1)", text: Binding(
                            get: { options[index] },
                            set: { options[index] = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                                .fill(theme.controlBackground)
                        )

                        if options.count > 2 {
                            Button {
                                options.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(theme.tertiaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if options.count < 4 {
                    GlassActionButton(title: "Add Option", icon: "plus", isAccent: true) {
                        options.append("Option \(options.count + 1)")
                    }
                }

                Text("First option is treated as approval, others as rejection.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    // MARK: - 4. Timeout Card

    private var timeoutCard: some View {
        SettingsCard(title: "Timeout", icon: "clock", theme: theme) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Timeout")
                            .font(theme.fontBody.weight(.medium))
                            .foregroundColor(theme.primaryText)
                        Text("Auto-rejects if no response within this time.")
                            .font(.system(.caption))
                            .foregroundColor(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 24)
                    Toggle("", isOn: $hasTimeout)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                if hasTimeout {
                    Divider()
                        .padding(.vertical, 12)

                    HStack {
                        Slider(value: $timeoutSeconds, in: 30...900, step: 30)
                        Text("\(Int(timeoutSeconds))s")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Helpers

    private func loadFromNode() {
        joinMode = node.nodeConfig?.joinMode ?? .all
        guard case .gate(let config) = node.kind else { return }
        prompt = config.prompt
        options = config.options
        if let t = config.timeout {
            hasTimeout = true
            timeoutSeconds = t
        }
    }

    private func saveAndDismiss() {
        let config = GateNodeConfig(
            prompt: prompt.isEmpty ? "Approve this workflow step?" : prompt,
            options: options.filter { !$0.isEmpty },
            timeout: hasTimeout ? timeoutSeconds : nil
        )
        node.kind = .gate(config)

        // Persist fan-in behaviour on the shared per-node config.
        if node.nodeConfig == nil { node.nodeConfig = WorkflowNodeConfig() }
        node.nodeConfig?.joinMode = joinMode

        closeInspector()
    }
}

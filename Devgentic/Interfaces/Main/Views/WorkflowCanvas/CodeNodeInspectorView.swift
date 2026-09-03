//
//  CodeNodeInspectorView.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Configuration sheet for Code/Transform nodes — card-based layout.
//  Allows the user to edit the template string (Mustache-like placeholders)
//  and set an optional output variable name.
//  Uses SettingsCard components for visual consistency with other inspector views.
//

import SwiftUI

struct CodeNodeInspectorView: View {
    @Binding var node: WorkflowNode
    @Environment(\.closeNodeInspector) private var closeInspector
    @Environment(\.appTheme) private var theme

    // MARK: - State

    @State private var template: String = "{{ input }}"
    @State private var outputVariable: String = ""
    @State private var showGuide: Bool = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    guideCard
                    templateCard
                    outputVariableCard
                }
                .padding(24)
            }
        }
        .frame(
            minWidth: 800,
            idealWidth: 950,
            maxWidth: .infinity,
            minHeight: 520,
            idealHeight: 650,
            maxHeight: .infinity
        )
        .background(theme.primaryBackground)
        .onAppear { loadFromNode() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.cyan)
            Text("Code / Transform")
                .font(theme.fontSubheadline.weight(.semibold))
                .foregroundColor(theme.primaryText)
            Text("\u{00B7}")
                .foregroundColor(theme.tertiaryText)
            // Inline-editable node label. Matches the rename pattern in the
            // agent profile editor — type to rename, no separate edit mode.
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
                        title: "Template",
                        subtitle: "text transform",
                        description: "Write a text template with placeholders. The node applies substitutions and outputs the result.",
                        color: .cyan
                    )
                    guideStep(
                        number: "2",
                        title: "Placeholders",
                        subtitle: "variable substitution",
                        description: "{{ input }} = upstream text · {{ input.json.path }} = a field of upstream JSON · {{ input.parsed.path }} = a field of this node's own input, parsed as JSON · {{ var.name }} = a workflow variable.",
                        color: .blue
                    )
                    guideStep(
                        number: "3",
                        title: "Output Variable",
                        subtitle: "optional",
                        description: "Optionally store the result in a named variable. Code nodes are the ONLY writers of workflow variables — Routers can test them, and other templates can substitute them.",
                        color: .green
                    )

                    guideTip("A placeholder that can't be resolved — a misspelled variable, say — is left in the output VERBATIM, and validation does not catch it: check spelling. The template renders in a single pass, so upstream text can never inject new placeholders. Deterministic; never retries; a failure routes to the error port.")
                }
                .padding(.top, 10)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed")
                        .font(.system(.caption, weight: .medium))
                        .foregroundColor(.cyan)
                    Text("How Code Nodes Work")
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

    // MARK: - 2. Template Card

    private var templateCard: some View {
        SettingsCard(title: "Template", icon: "text.alignleft", theme: theme) {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $template)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 200)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                            .fill(theme.controlBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                            .stroke(theme.surfaceOverlayStrong.opacity(0.3), lineWidth: 0.5)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Available placeholders:")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(theme.secondaryText)
                    HStack(spacing: 12) {
                        placeholderChip("{{ input }}", description: "Upstream output")
                        placeholderChip("{{ var.name }}", description: "Workflow variable")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    // MARK: - 3. Output Variable Card

    private var outputVariableCard: some View {
        SettingsCard(title: "Output Variable", icon: "tray.and.arrow.down", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Variable name (optional)", text: $outputVariable)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                            .fill(theme.controlBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                            .stroke(theme.surfaceOverlayStrong.opacity(0.3), lineWidth: 0.5)
                    )
                Text("If set, the result is stored as a shared workflow variable accessible by downstream nodes.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Placeholder Chip

    private func placeholderChip(_ code: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(code)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.accentColor.opacity(0.1))
                )
            Text(description)
                .font(.system(size: 9))
                .foregroundColor(theme.tertiaryText)
        }
    }

    // MARK: - Helpers

    private func loadFromNode() {
        guard case .code(let config) = node.kind else { return }
        template = config.template
        outputVariable = config.outputVariable ?? ""
    }

    private func saveAndDismiss() {
        let config = CodeNodeConfig(
            template: template.isEmpty ? "{{ input }}" : template,
            outputVariable: outputVariable.isEmpty ? nil : outputVariable
        )
        node.kind = .code(config)

        // [INS-11] The `if node.nodeConfig == nil { node.nodeConfig = WorkflowNodeConfig() }` that
        // stood here is GONE. Its comment claimed to "persist fan-in behaviour", but `joinMode` was
        // retired 2026-08-13 (decode/encode only) and a Code node has no other per-node config this
        // panel edits — so the line's only effect was turning `nil` into `.some(defaults)`, which
        // `replaceNode`'s equality guard cannot absorb. Opening a Code node, changing nothing and
        // pressing Save therefore dirtied the canvas and burned one of the 25 undo slots.

        closeInspector()
    }
}

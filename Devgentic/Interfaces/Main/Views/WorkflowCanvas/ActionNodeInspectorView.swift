// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ActionNodeInspectorView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Inspector for Action nodes, which invoke a tool deterministically with no LLM.
/// Pick a tool from the unified catalog, then bind each argument to a template resolved at run time.
/// Edits stay in local state and are written to `node.kind` only on Save, so Cancel discards.
struct ActionNodeInspectorView: View {
    @Binding var node: WorkflowNode
    /// Workflow variable names (Code-node outputs) surfaced in the binding menu.
    var availableVariables: [String] = []
    @Environment(\.closeNodeInspector) private var closeInspector
    @Environment(\.appTheme) private var theme

    /// Boolean argument input mode.
    private enum BoolMode: Hashable { case yes, no, custom }

    // Local editing state
    @State private var selectedTool: Tool? = nil
    @State private var bindings: [String: String] = [:]
    @State private var showToolPicker = false
    @State private var showGuide = false

    // Execution config (per-node orchestration — written to node.nodeConfig).
    @State private var maxRetries: Int = 0
    @State private var unattendedAutoApprove: Bool = false
    @State private var retryDelay: Double = 0
    @State private var hardTimeout: Double? = nil

    // Live tool catalog (native + MCP).
    private var toolSources: [ToolSource] { UnifiedToolStore.shared.sources }
    var showsHeader: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)
            }
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    guideCard
                    toolCard
                    if let tool = selectedTool {
                        argumentsCard(for: tool)
                    }
                    executionCard
                }
                .padding(24)
            }
        }
        .frame(
            minWidth: showsHeader ? 800 : nil,
            idealWidth: showsHeader ? 950 : nil,
            maxWidth: .infinity,
            minHeight: showsHeader ? 620 : nil,
            idealHeight: showsHeader ? 750 : nil,
            maxHeight: .infinity
        )
        .background(theme.primaryBackground)
        .onAppear {
            loadFromNode()
            if !showsHeader {
                NodeInspectorPendingCommit.shared.register {
                    persistConfigToNode()
                }
            }
        }
        .onDisappear {
            if !showsHeader {
                persistConfigToNode()
                NodeInspectorPendingCommit.shared.clear()
            }
        }
        .onChange(of: selectedTool) { persistIfEmbedded() }
        .onChange(of: bindings) { persistIfEmbedded() }
        .onChange(of: maxRetries) { persistIfEmbedded() }
        .onChange(of: unattendedAutoApprove) { persistIfEmbedded() }
        .onChange(of: retryDelay) { persistIfEmbedded() }
        .onChange(of: hardTimeout) { persistIfEmbedded() }
        .sheet(isPresented: $showToolPicker) { toolPickerSheet }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.fill")
                .font(theme.fontSubheadline.weight(.semibold))
                .foregroundColor(.teal)
            Text("Action")
                .font(theme.fontSubheadline.weight(.semibold))
                .foregroundColor(theme.primaryText)
            Text("\u{00B7}")
                .foregroundColor(theme.tertiaryText)
            TextField(
                "",
                text: $node.displayName,
                prompt: Text("Node Name").foregroundColor(theme.placeholderText)
            )
            .font(theme.fontSubheadline.weight(.semibold))
            .textFieldStyle(.plain)
            .foregroundColor(theme.primaryText)
            Spacer()
            TactileIconButton(
                icon: "questionmark.circle",
                tooltip: showGuide ? "Hide guide" : "Show guide",
                accessibilityLabel: showGuide ? "Hide guide" : "Show guide",
                size: .compact
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { showGuide.toggle() }
            }
            GlassActionButton(title: "Cancel", icon: "xmark", isAccent: false) { closeInspector() }
            GlassActionButton(title: "Save", icon: "checkmark", isAccent: true) { saveAndDismiss() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.secondaryBackground.opacity(0.5))
    }

    // MARK: - Guide

    @ViewBuilder
    private var guideCard: some View {
        if showGuide {
            VStack(alignment: .leading, spacing: 8) {
                Text("Action nodes call a tool directly — no LLM, instant, deterministic.")
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Text("Pick a tool, then bind each argument to a value. Use placeholders to pull from the workflow:")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                Group {
                    bindingHint("{{ input }}", "the upstream node's text output")
                    bindingHint("{{ input.json.field }}", "a field from upstream JSON output")
                    bindingHint("{{ input.parsed.field }}", "a field from this node's own input, parsed as JSON")
                    bindingHint("{{ var.name }}", "a workflow variable")
                }
                Text("Anything else is treated as a literal value.")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.tertiaryText)
                    .italic()
                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)
                    .padding(.vertical, 2)
                Text("Things to know")
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Group {
                    guideLine("Retries re-run a call that THREW (network drop, timeout). A tool that RETURNED an error is not retried — its side effect may already have happened.")
                    guideLine("Tools marked as requiring confirmation pause the run for your approval. In a scheduled run nobody can answer — prefer auto-allowed tools there.")
                    guideLine("A failure activates the error port; wire it for recovery, or the branch stops with the reason in the final output.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(theme.surfaceOverlay)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func guideLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .font(theme.fontCaption2.weight(.bold))
                .foregroundColor(.teal)
            Text(text)
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)
                .lineSpacing(2.0)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bindingHint(_ token: String, _ desc: String) -> some View {
        HStack(spacing: 6) {
            Text(token)
                .font(theme.fontCodeCaption.weight(.medium))
                .foregroundColor(.teal)
            Text("—  \(desc)")
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)
        }
    }

    // MARK: - Tool Card

    private var toolCard: some View {
        SettingsCard(title: "Tool", icon: "wrench.and.screwdriver", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                if let tool = selectedTool {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name)
                                .font(theme.fontFootnote.weight(.semibold))
                                .foregroundColor(theme.primaryText)
                            Text(tool.description)
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)
                                .lineSpacing(2.5)
                                .lineLimit(2)
                        }
                        Spacer()
                        GlassActionButton(title: "Change", icon: "arrow.triangle.2.circlepath", isAccent: false) { showToolPicker = true }
                    }
                } else {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.warningColor)
                        Text("No tool selected")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.warningColor)
                        Spacer()
                        GlassActionButton(title: "Select Tool", icon: "wrench.and.screwdriver", isAccent: true) { showToolPicker = true }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Arguments Card

    private func argumentsCard(for tool: Tool) -> some View {
        let argNames = sortedArgNames(for: tool)
        return SettingsCard(title: "Arguments", icon: "list.bullet.rectangle", theme: theme) {
            VStack {
                if argNames.isEmpty {
                    Text("This tool takes no arguments.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(argNames, id: \.self) { argName in
                            argumentRow(tool: tool, argName: argName)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private func argumentRow(tool: Tool, argName: String) -> some View {
        let prop = tool.parameters.properties[argName]
        let isRequired = tool.parameters.required.contains(argName)
        let isBoolean = (prop?.type.lowercased() == "boolean")
        let value = bindings[argName] ?? ""
        let unbalanced = !bracesBalanced(value)

        VStack(alignment: .leading, spacing: 4) {
            // Header: name, type, required, + token-insertion menu.
            HStack(spacing: 6) {
                Text(argName)
                    .font(theme.fontCode.weight(.medium))
                    .foregroundColor(theme.primaryText)
                if let type = prop?.type {
                    Text(type)
                        .font(theme.fontCaption2.weight(.medium))
                        .foregroundColor(.teal)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.teal.opacity(0.12)))
                }
                if isRequired {
                    Text("required")
                        .font(theme.fontCaption2.weight(.medium))
                        .foregroundColor(theme.warningColor)
                }
                Spacer()
                tokenMenu(argName: argName)
            }
            if let desc = prop?.description, !desc.isEmpty {
                Text(desc)
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isBoolean {
                // `isRequired` is threaded through so a required boolean keeps its required styling and placeholder.
                booleanControl(argName: argName, value: value, isRequired: isRequired)
            } else {
                bindingField(argName: argName, isRequired: isRequired, unbalanced: unbalanced)
            }

            if unbalanced {
                Label("Unbalanced \u{007B}\u{007B} \u{007D}\u{007D} — check the placeholder.", systemImage: "exclamationmark.triangle.fill")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.warningColor)
            }
        }
    }

    /// Plain/template text field for non-boolean arguments.
    private func bindingField(argName: String, isRequired: Bool, unbalanced: Bool) -> some View {
        let isEmptyRequired = isRequired && (bindings[argName] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let promptText = isRequired ? "Required — value or {{ input }}" : "Optional — leave blank to omit"
        return TextField(
            "",
            text: Binding(get: { bindings[argName] ?? "" }, set: { bindings[argName] = $0 }),
            prompt: Text(promptText).foregroundColor(theme.placeholderText)
        )
        .font(theme.fontCode)
        .textFieldStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: theme.cornerRadiusSmall).fill(theme.controlBackground))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                .stroke(
                    (isEmptyRequired || unbalanced) ? theme.warningColor.opacity(0.5) : theme.surfaceOverlayStrong.opacity(0.3),
                    lineWidth: 0.5
                )
        )
    }

    /// True/False/Custom control for boolean arguments. True/False write a literal;
    /// Custom reveals a text field for a template (e.g. `{{ var.flag }}`).
    @ViewBuilder
    private func booleanControl(argName: String, value: String, isRequired: Bool) -> some View {
        let mode = boolMode(value)
        Picker("", selection: Binding(
            get: { mode },
            set: { newMode in
                switch newMode {
                case .yes: bindings[argName] = "true"
                case .no: bindings[argName] = "false"
                case .custom:
                    let cur = bindings[argName] ?? ""
                    if cur == "true" || cur == "false" { bindings[argName] = "" }
                }
            }
        )) {
            Text("True").tag(BoolMode.yes)
            Text("False").tag(BoolMode.no)
            Text("Custom").tag(BoolMode.custom)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)

        if mode == .custom {
            bindingField(argName: argName, isRequired: isRequired, unbalanced: !bracesBalanced(value))
        }
    }

    /// Menu to insert a template placeholder into an argument binding.
    private func tokenMenu(argName: String) -> some View {
        Menu {
            Button("{{ input }}") { appendToken(argName, "{{ input }}") }
            // Inserts an unfinished `<field>` placeholder that cannot resolve by accident: an empty path would pass the whole
            // upstream document.
            Button("{{ input.json.… }}") { appendToken(argName, "{{ input.json.<field> }}") }
            // The explicit "parse my input as JSON" form; the incomplete `<field>` token fails loudly rather than resolving to the
            // whole document.
            Button("{{ input.parsed.… }}") { appendToken(argName, "{{ input.parsed.<field> }}") }
            if availableVariables.isEmpty {
                Button("{{ var.… }}") { appendToken(argName, "{{ var.<name> }}") }
            } else {
                Menu("Variable") {
                    ForEach(availableVariables, id: \.self) { v in
                        Button("{{ var.\(v) }}") { appendToken(argName, "{{ var.\(v) }}") }
                    }
                    Divider()
                    Button("{{ var.… }}") { appendToken(argName, "{{ var.<name> }}") }
                }
            }
        } label: {
            Image(systemName: "curlybraces")
                .font(theme.fontCodeCaption.weight(.medium))
                .foregroundColor(.teal)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .pointingHandCursor()
        .help("Insert a value from the workflow")
    }

    private func appendToken(_ argName: String, _ token: String) {
        let current = bindings[argName] ?? ""
        bindings[argName] = current.isEmpty ? token : current + token
    }

    private func boolMode(_ value: String) -> BoolMode {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true": return .yes
        case "false": return .no
        default: return .custom
        }
    }

    /// True when `{{` and `}}` occurrences are paired (a cheap malformed-template guard).
    private func bracesBalanced(_ s: String) -> Bool {
        let opens = s.components(separatedBy: "{{").count - 1
        let closes = s.components(separatedBy: "}}").count - 1
        return opens == closes
    }

    // MARK: - Execution Card

    private var executionCard: some View {
        SettingsCard(title: "Execution", icon: "gearshape", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                // Timeout
                execRow(
                    label: "Timeout",
                    explainer: "Max seconds before the tool call is aborted (and retried)."
                ) {
                    if let t = hardTimeout {
                        HStack(spacing: 8) {
                            Stepper("\(Int(t))s", value: Binding(get: { t }, set: { hardTimeout = $0 }), in: 5...3600, step: 5)
                                .fixedSize()
                            GlassActionButton(title: "Reset", icon: "arrow.counterclockwise", isAccent: false) { hardTimeout = nil }
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text("Default")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)
                            GlassActionButton(title: "Set", icon: "clock", isAccent: true) { hardTimeout = 120 }
                        }
                    }
                }

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)

                // Retries
                execRow(
                    label: "Retries",
                    explainer: "Re-run the tool on transient failure (network, timeout, MCP)."
                ) {
                    Stepper("\(maxRetries)", value: $maxRetries, in: 0...5).fixedSize()
                }

                if maxRetries > 0 {
                    Rectangle()
                        .fill(theme.dividerColor.opacity(0.3))
                        .frame(height: 0.5)
                    execRow(
                        label: "Retry Delay",
                        explainer: "Seconds to wait between attempts."
                    ) {
                        Stepper("\(Int(retryDelay))s", value: $retryDelay, in: 0...60, step: 1).fixedSize()
                    }
                }

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)

                // The explicit unattended approval: without it an unattended run refuses this tool's confirmation and the node fails
                // onto its error port.
                execRow(
                    label: "Unattended Auto-Approve",
                    explainer: "Scheduled runs auto-approve this tool's confirmation. Off: a run nobody can answer fails this node onto its error port immediately. (ChatOps runs still ask — the confirmation is mirrored to your chat app.)"
                ) {
                    Toggle("", isOn: $unattendedAutoApprove)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                // Failure routing is wiring, not a setting: connect the node's `error` port to handle a failure, or the branch stops.
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private func execRow<Control: View>(
        label: String,
        explainer: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Text(explainer)
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            control()
        }
    }

    // MARK: - Tool Picker Sheet

    private var toolPickerSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select a Tool")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                TactileButton(title: "Done", variant: .secondary, size: .compact) {
                    showToolPicker = false
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 0.5)
            if toolSources.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 28))
                        .foregroundColor(theme.tertiaryText)
                    Text("No tools available")
                        .font(theme.fontSubheadline.weight(.semibold))
                        .foregroundColor(theme.secondaryText)
                    Text("Connect an MCP server or check the Tool Library.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(toolSources) { source in
                            // A disabled server's tools are shown but not selectable: the executor's resolver refuses a disabled source, so a
                            // selection could only fail.
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 5) {
                                    Text(source.serverName.uppercased())
                                        .font(theme.fontCodeCaption.weight(.bold))
                                        .foregroundColor(theme.tertiaryText)
                                    if !source.isEnabled {
                                        Image(systemName: "pause.circle.fill")
                                            .font(theme.fontCaption2)
                                            .foregroundColor(theme.secondaryText.opacity(0.6))
                                        Text("Disabled — enable in Tool Library")
                                            .font(theme.fontCaption2)
                                            .foregroundColor(theme.tertiaryText)
                                    }
                                }
                                ForEach(source.tools) { def in
                                    toolPickerRow(source: source, def: def)
                                        .disabled(!source.isEnabled)
                                }
                            }
                            .opacity(source.isEnabled ? 1 : 0.55)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 460, height: 520)
        .background(theme.primaryBackground)
    }

    private func toolPickerRow(source: ToolSource, def: ToolDefinition) -> some View {
        let isSelected = selectedTool?.name == def.name && selectedTool?.sourceId == source.id
        return Button {
            selectTool(source: source, def: def)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(def.title ?? def.name)
                        .font(theme.fontFootnote.weight(.medium))
                        .foregroundColor(theme.primaryText)
                    Text(def.description)
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? theme.accentColor.opacity(0.1) : theme.surfaceOverlay.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - Logic

    private func sortedArgNames(for tool: Tool) -> [String] {
        // Required arguments first, then the rest — both alphabetical.
        let required = tool.parameters.required
        let all = tool.parameters.properties.keys.sorted()
        let req = all.filter { required.contains($0) }
        let opt = all.filter { !required.contains($0) }
        return req + opt
    }

    private func selectTool(source: ToolSource, def: ToolDefinition) {
        let tool = Tool(
            name: def.name,
            description: def.description,
            isEnabled: true,
            // Inherits the tool's own confirmation default (`def.requiresConfirmation`), so a destructive tool in an Action node
            // asks and a read-only one does not.
            requiresConfirmation: def.requiresConfirmation,
            sourceId: source.id,
            parameters: def.parameters
        )
        // Preserve any bindings whose argument names still exist on the new tool.
        let validKeys = Set(def.parameters.properties.keys)
        bindings = bindings.filter { validKeys.contains($0.key) }
        selectedTool = tool
        showToolPicker = false
    }

    /// Returns the execution config a Save should persist, or the stored value unchanged when the panel holds only
    /// defaults.
    /// An unedited Save must stay byte-identical, since `replaceNode` refuses no-op writes. Pure and `nonisolated`.
    nonisolated static func executionConfigToPersist(
        existing: WorkflowNodeConfig?,
        maxRetries: Int,
        retryDelay: TimeInterval,
        hardTimeout: TimeInterval?,
        unattendedAutoApprove: Bool
    ) -> WorkflowNodeConfig? {
        var updated = existing ?? WorkflowNodeConfig()
        updated.maxNodeRetries = maxRetries
        updated.retryDelay = retryDelay
        updated.hardTimeout = hardTimeout
        // nil (not false) when off — the default costs no bytes in the blob. [WF-SE6/SE11]
        updated.unattendedAutoApprove = unattendedAutoApprove ? true : nil
        // Nothing to write: the panel holds exactly what `nil` already means.
        if existing == nil, updated == WorkflowNodeConfig() { return nil }
        return updated
    }

    private func loadFromNode() {
        // Execution config lives on the shared per-node config.
        maxRetries = node.nodeConfig?.maxNodeRetries ?? 0
        unattendedAutoApprove = node.nodeConfig?.unattendedAutoApprove ?? false
        retryDelay = node.nodeConfig?.retryDelay ?? 0
        hardTimeout = node.nodeConfig?.hardTimeout

        guard case .action(let config) = node.kind else { return }
        selectedTool = config.tool
        bindings = config.argumentBindings
    }

    private func persistConfigToNode() {
        // Drop empty bindings so unconfigured optional args are omitted at run time.
        let cleaned = bindings.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        node.kind = .action(ActionNodeConfig(tool: selectedTool, argumentBindings: cleaned))

        // Persists execution config through one binding write via a pure helper that returns the stored value unchanged when
        // nothing was edited.
        node.nodeConfig = Self.executionConfigToPersist(
            existing: node.nodeConfig,
            maxRetries: maxRetries,
            retryDelay: retryDelay,
            hardTimeout: hardTimeout,
            unattendedAutoApprove: unattendedAutoApprove
        )
    }

    private func persistIfEmbedded() {
        guard !showsHeader else { return }
        persistConfigToNode()
    }

    private func saveAndDismiss() {
        persistConfigToNode()
        NodeInspectorPendingCommit.shared.clear()
        closeInspector()
    }
}

//
//  ConditionNodeInspectorView.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Configuration sheet for Condition nodes — card-based layout.
//  Pattern matching rules → AI Classifier → Static Fallback cascade.
//  Uses SettingsCard components for visual consistency with Bot/Agent config views.
//

import SwiftUI

struct ConditionNodeInspectorView: View {
    @Binding var node: WorkflowNode
    @Environment(\.closeNodeInspector) private var closeInspector
    @Environment(\.appTheme) private var theme

    // MARK: - State

    @State private var rules: [ConditionRule] = []
    @State private var fallbackLabel: String = "False"
    @State private var llmFallbackEnabled: Bool = false
    @State private var llmPrompt: String = ""
    @State private var llmModelName: String? = nil
    @State private var passthroughContent: Bool = true
    @State private var joinMode: JoinMode = .all
    @State private var installedModels: [MLXModelItem] = []
    @State private var showGuide: Bool = false

    private let maxPromptLength = 500

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    guideCard
                    outputBehaviorCard
                    patternRulesCard
                    staticFallbackCard
                    aiClassifierCard
                    JoinModeCard(joinMode: $joinMode)
                }
                .padding(24)
            }
        }
        .frame(
            minWidth: 800,
            idealWidth: 950,
            maxWidth: .infinity,
            minHeight: 680,
            idealHeight: 800,
            maxHeight: .infinity
        )
        .background(theme.primaryBackground)
        .onAppear {
            loadFromNode()
        }
        // ⚠️ `.task`, not `.onAppear`: A15 made the model scan asynchronous, so a synchronous
        // read right after a fire-and-forget refresh snapshots the EMPTY pre-scan list into
        // `@State` with nothing observing it afterwards. Opening this inspector before the
        // launch scan landed showed "No MLX models found" until it was closed and reopened.
        // Same fix as `MLXModelPickerView`.
        .task {
            await loadInstalledModels()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.yellow)
            Text("Condition")
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
                        title: "Pattern Rules",
                        subtitle: "exact match",
                        description: "Rules are checked top-to-bottom. The first rule whose condition matches activates that output port.",
                        color: .blue
                    )
                    guideStep(
                        number: "2",
                        title: "AI Classifier",
                        subtitle: "semantic",
                        description: "If no pattern matches and AI Classifier is enabled, a local MLX model semantically classifies the input into one of your rule labels.",
                        color: .purple
                    )
                    guideStep(
                        number: "3",
                        title: "Static Fallback",
                        subtitle: "catch-all",
                        description: "If nothing else matches, routes to the selected fallback label. This is your safety net.",
                        color: .orange
                    )

                    guideTip("Pattern rules define the output ports visible on the canvas. All three mechanisms route to the same set of ports.")
                }
                .padding(.top, 10)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed")
                        .font(.system(.caption, weight: .medium))
                        .foregroundColor(.yellow)
                    Text("How Condition Routing Works")
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

    // MARK: - 2. Output Behavior Card

    private var outputBehaviorCard: some View {
        SettingsCard(title: "Output Behavior", icon: "arrow.right.doc.on.clipboard", theme: theme) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pass Through Content")
                        .font(theme.fontBody.weight(.medium))
                        .foregroundColor(theme.primaryText)
                    Text(passthroughContent
                         ? "Downstream nodes receive the full upstream content."
                         : "Downstream nodes receive only the routing label.")
                        .font(.system(.caption))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 24)
                Toggle("", isOn: $passthroughContent)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    // MARK: - 3. Pattern Rules Card

    private var patternRulesCard: some View {
        SettingsCard(title: "Pattern Rules", icon: "list.bullet", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                // Counter
                HStack {
                    Text("Rules are evaluated top-to-bottom. First match wins.")
                        .font(.system(.caption))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    Text("\(rules.count) / \(ConditionNodeConfig.maxRules)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.surfaceOverlay))
                }

                // Rule cards
                ForEach($rules) { $rule in
                    ruleCard(rule: $rule, canDelete: rules.count > ConditionNodeConfig.minRules)
                }

                // Add Rule button
                if rules.count < ConditionNodeConfig.maxRules {
                    GlassActionButton(title: "Add Rule", icon: "plus", isAccent: true) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            rules.append(ConditionRule(label: nextAvailableLabel(), field: .upstreamOutput, op: .contains, value: ""))
                            syncFallbackLabel()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Rule Card

    @ViewBuilder
    private func ruleCard(rule: Binding<ConditionRule>, canDelete: Bool) -> some View {
        VStack(spacing: 8) {
            // Row 1: Label + Field + Op + Delete
            HStack(spacing: 6) {
                // Label
                TextField("Label", text: rule.label)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                            .fill(labelValidationColor(for: rule.wrappedValue))
                    )
                    .frame(maxWidth: 100)
                    .onChange(of: rule.wrappedValue.label) {
                        let sanitized = String(
                            rule.wrappedValue.label
                                .filter { $0.isLetter || $0.isNumber }
                                .prefix(10)
                        )
                        if rule.wrappedValue.label != sanitized {
                            rule.wrappedValue.label = sanitized
                        }
                        syncFallbackLabel()
                    }

                Spacer()

                // Field picker
                Picker("", selection: rule.field) {
                    Text("Output").tag(ConditionField.upstreamOutput)
                    Text("Variable").tag(ConditionField.variable)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.system(size: 11))
                .frame(width: 90)

                // Operator picker
                Picker("", selection: rule.op) {
                    ForEach(ConditionOp.allCases, id: \.self) { op in
                        Text(op.displayName).tag(op)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.system(size: 11))
                .frame(width: 130)

                // Delete
                if canDelete {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            rules.removeAll { $0.id == rule.wrappedValue.id }
                            syncFallbackLabel()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Validation text
            if !ConditionNodeConfig.isValidLabel(rule.wrappedValue.label) {
                Text("Label must be 1\u{2013}10 alphanumeric characters.")
                    .font(.system(size: 9))
                    .foregroundColor(.red.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if isDuplicateLabel(rule.wrappedValue) {
                Text("Duplicate label.")
                    .font(.system(size: 9))
                    .foregroundColor(.orange.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Variable name field (conditional)
            if rule.wrappedValue.field == .variable {
                TextField(
                    "Variable name",
                    text: Binding(
                        get: { rule.wrappedValue.variableName ?? "" },
                        set: { rule.wrappedValue.variableName = $0.isEmpty ? nil : $0 }
                    )
                )
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                        .fill(theme.accentColor.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                        .stroke(theme.accentColor.opacity(0.2), lineWidth: 0.5)
                )
            }

            // Match value field (hidden for isEmpty/isNotEmpty — those don't need a value)
            if rule.wrappedValue.op != .isEmpty && rule.wrappedValue.op != .isNotEmpty {
                TextField("Value (comma-separated for multiple)...", text: rule.value)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                            .fill(rule.wrappedValue.value.isEmpty ? Color.red.opacity(0.06) : theme.controlBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                            .stroke(rule.wrappedValue.value.isEmpty ? Color.red.opacity(0.3) : theme.surfaceOverlayStrong.opacity(0.3), lineWidth: 0.5)
                    )
                if rule.wrappedValue.value.isEmpty {
                    Text("Match value is required for \"\(rule.wrappedValue.op.displayName)\" operator.")
                        .font(.system(size: 9))
                        .foregroundColor(.red.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(theme.spacingMedium)
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                .fill(theme.secondaryBackground.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                .stroke(theme.surfaceOverlayStrong.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - 4. Static Fallback Card

    private var staticFallbackCard: some View {
        SettingsCard(title: "Static Fallback", icon: "arrow.uturn.right", theme: theme) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Catch-All Route")
                        .font(theme.fontBody.weight(.medium))
                        .foregroundColor(theme.primaryText)
                    Text("Used when no pattern matches and AI Classifier is disabled or fails.")
                        .font(.system(.caption))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 24)
                Picker("", selection: $fallbackLabel) {
                    ForEach(rules.map(\.label), id: \.self) { label in
                        Text(label).tag(label)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(maxWidth: 120)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    // MARK: - 5. AI Classifier Card

    private var aiClassifierCard: some View {
        SettingsCard(title: "AI Classifier", icon: "brain", theme: theme) {
            VStack(alignment: .leading, spacing: 14) {
                // Enable toggle
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Semantic Classification")
                            .font(theme.fontBody.weight(.medium))
                            .foregroundColor(theme.primaryText)
                        Text("A local MLX model classifies input into your rule labels when no pattern matches.")
                            .font(.system(.caption))
                            .foregroundColor(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 24)
                    Toggle("", isOn: $llmFallbackEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                if llmFallbackEnabled {
                    Divider()

                    // MLX Model picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MLX Model")
                            .font(theme.fontCaption.weight(.medium))
                            .foregroundColor(theme.secondaryText)

                        if installedModels.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                                Text("No MLX models found. Install a model first.")
                                    .font(theme.fontCaption)
                                    .foregroundColor(theme.tertiaryText)
                            }
                        } else {
                            Picker("", selection: Binding(
                                get: { llmModelName ?? "" },
                                set: { llmModelName = $0.isEmpty ? nil : $0 }
                            )) {
                                Text("Select model...").tag("")
                                ForEach(installedModels) { model in
                                    Text(model.displayName).tag(model.displayName)
                                }
                            }
                            .labelsHidden()
                            .font(.system(size: 12))
                        }
                    }

                    // Routing prompt
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Routing Prompt")
                                .font(theme.fontCaption.weight(.medium))
                                .foregroundColor(theme.secondaryText)
                            Spacer()
                            Text("\(llmPrompt.count)/\(maxPromptLength)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(llmPrompt.count > maxPromptLength ? .red : theme.tertiaryText)
                        }

                        TextEditor(text: $llmPrompt)
                            .font(.system(size: 12))
                            .frame(minHeight: 50, maxHeight: 80)
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
                            .onChange(of: llmPrompt) {
                                if llmPrompt.count > maxPromptLength {
                                    llmPrompt = String(llmPrompt.prefix(maxPromptLength))
                                }
                            }

                        Text("Describe what to classify. e.g., \"Is this a technical question or a general inquiry?\"")
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                            .italic()
                    }

                    guideTip("The classifier uses opaque tokens internally to prevent confusion with upstream content. It routes to the same labels defined in your pattern rules above.")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Helpers

    private func syncFallbackLabel() {
        let currentLabels = rules.map(\.label)
        if !currentLabels.contains(fallbackLabel) {
            fallbackLabel = currentLabels.last ?? "False"
        }
    }

    private func nextAvailableLabel() -> String {
        let existing = Set(rules.map(\.label))
        for i in 1...99 {
            let candidate = "Rule\(i)"
            if !existing.contains(candidate) { return candidate }
        }
        return "Rule\(rules.count + 1)"
    }

    private func isDuplicateLabel(_ rule: ConditionRule) -> Bool {
        rules.filter { $0.label == rule.label }.count > 1
    }

    private func labelValidationColor(for rule: ConditionRule) -> Color {
        if !ConditionNodeConfig.isValidLabel(rule.label) {
            return Color.red.opacity(0.08)
        } else if isDuplicateLabel(rule) {
            return Color.orange.opacity(0.08)
        }
        return theme.accentColor.opacity(0.08)
    }

    /// Awaits at least one completed scan before reading. An empty `installedModels` is
    /// indistinguishable from "nothing is installed", so it must never be snapshotted early.
    private func loadInstalledModels() async {
        let service = MLXModelService.shared
        await service.ensureLoaded()
        installedModels = service.installedModels
    }

    private func loadFromNode() {
        joinMode = node.nodeConfig?.joinMode ?? .all
        guard case .condition(let config) = node.kind else { return }
        rules = config.rules
        fallbackLabel = config.fallbackLabel
        llmFallbackEnabled = config.llmFallbackEnabled
        llmPrompt = config.llmPrompt
        llmModelName = config.llmModelName
        passthroughContent = config.passthroughContent

        while rules.count < ConditionNodeConfig.minRules {
            rules.append(ConditionRule(label: nextAvailableLabel(), field: .upstreamOutput, op: .contains, value: ""))
        }

        syncFallbackLabel()
    }

    private func saveAndDismiss() {
        var seen = Set<String>()
        for i in rules.indices {
            var label = rules[i].label
            if seen.contains(label) {
                for suffix in 2...99 {
                    let candidate = String("\(label)\(suffix)".prefix(10))
                    if !seen.contains(candidate) {
                        label = candidate
                        break
                    }
                }
            }
            rules[i].label = label
            seen.insert(label)
        }

        var config = ConditionNodeConfig()
        config.rules = rules
        config.fallbackLabel = fallbackLabel.isEmpty ? "False" : fallbackLabel
        config.llmFallbackEnabled = llmFallbackEnabled
        config.llmPrompt = String(llmPrompt.prefix(maxPromptLength))
        config.llmPortLabels = []
        config.llmModelName = llmModelName
        config.passthroughContent = passthroughContent
        node.kind = .condition(config)

        // Persist fan-in behaviour on the shared per-node config.
        if node.nodeConfig == nil { node.nodeConfig = WorkflowNodeConfig() }
        node.nodeConfig?.joinMode = joinMode

        closeInspector()
    }
}

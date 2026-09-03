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

private let inspectorLogger = DGLogger(category: "ConditionNodeInspector")

struct ConditionNodeInspectorView: View {
    @Binding var node: WorkflowNode
    @Environment(\.closeNodeInspector) private var closeInspector
    @Environment(\.appTheme) private var theme

    // MARK: - State

    /// The config as it was when the panel opened, so Save preserves fields this view does not edit.
    ///
    /// ⚠️ `fallbackLabel` is the one that bites: its picker was retired, but the stored value is
    /// still honoured by the engine, and rebuilding the config from scratch on Save wiped it.
    @State private var loadedConfig = ConditionNodeConfig()

    @State private var rules: [ConditionRule] = []
    @State private var llmFallbackEnabled: Bool = false
    @State private var llmPrompt: String = ""
    @State private var llmModelName: String? = nil
    @State private var askOnAmbiguity: Bool = true
    @State private var noMatchBehavior: RouterNoMatchBehavior = .failNode

    /// The unified "when routing can't decide" setting (2026-08-17 redesign). Seeded from the
    /// legacy pair when the node predates it — see `seedPolicyFromLegacy`.
    @State private var decisionPolicy: RouterDecisionPolicy = .ask(fallback: .failNode)
    /// The nested "if nobody can answer" control, held separately so switching away from Ask and
    /// back does not lose the user's fallback choice mid-edit.
    @State private var askFallback: RouterDecisionPolicy.AskFallback = .failNode
    @State private var installedModels: [MLXModelItem] = []
    @State private var showGuide: Bool = false

    /// ⚠️ Raised from 500 on 2026-08-17. The pre-filled default template plus any real editing
    /// does not fit under the old cap, and a field that silently truncates the text it just
    /// pre-filled is worse than no pre-fill.
    private let maxPromptLength = 1200

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    guideCard
                    patternRulesCard
                    routingDecisionCard
                    aiClassifierCard
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
            Text("Router")
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
                        subtitle: "checked top-to-bottom",
                        description: "Each rule's label is an output port. 'Contains' is case-insensitive and a comma-separated value matches ANY of its entries; 'equals' is exact. The first matching rule routes.",
                        color: .blue
                    )
                    guideStep(
                        number: "2",
                        title: "AI Classifier",
                        subtitle: "optional, semantic",
                        description: "If no pattern rule matches and the classifier is enabled, a local MLX model reads the input and names one of your rule labels. Its answer then follows exactly the same steps as a pattern match: one branch routes; none or several fall to step 3.",
                        color: .purple
                    )
                    guideStep(
                        number: "3",
                        title: "When Routing Can't Decide",
                        subtitle: "one setting, both cases",
                        description: "Whether SEVERAL rules matched or NONE did, this one setting decides: ask you to pick, route to a rule of your choosing, end the workflow here, or fail the node onto its error port. Unattended runs never pause — an Ask uses the 'If nobody can answer' fallback instead.",
                        color: .orange
                    )
                    guideStep(
                        number: "4",
                        title: "If the Classifier Fails",
                        subtitle: "not a routing choice",
                        description: "A classifier that could not RUN at all (no model, load failure) fails the node onto its error port regardless of the setting above — that setting answers 'no rule described this input', and a classifier that never answered did not read the input at all.",
                        color: .red
                    )

                    guideTip("The Router always passes the upstream content through unchanged — routing decides WHERE it goes, never WHAT it says. A failure (and only a failure) activates the error port.")
                }
                .padding(.top, 10)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed")
                        .font(.system(.caption, weight: .medium))
                        .foregroundColor(.yellow)
                    Text("How Routing Works")
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

    // MARK: - 2. Routing Decision Card (unified, 2026-08-17)

    /// ⚠️ REPLACES two adjacent cards — "When Rules Overlap" (an `askOnAmbiguity` Bool) and "When
    /// Nothing Matches" (a `noMatchBehavior` enum). They answered the SAME question in different
    /// shapes: what does the Router do when it cannot pick exactly one branch. The two triggers are
    /// mutually exclusive by construction (either zero rules matched or several did), so one
    /// setting is coherent rather than a false merge.
    ///
    /// ⚠️ Named for what it COVERS. "Unmatched Input" became a lie the moment the same setting also
    /// governed input that matched too MANY rules — the opposite of unmatched.
    private var routingDecisionCard: some View {
        SettingsCard(title: "When Routing Can't Decide", icon: "arrow.triangle.branch", theme: theme) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Undecided Input")
                            .font(theme.fontBody.weight(.medium))
                            .foregroundColor(theme.primaryText)
                        Text(decisionDescription)
                            .font(.system(.caption))
                            .foregroundColor(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 24)
                    Picker("", selection: $decisionPolicy) {
                        Text("Ask me which branch").tag(RouterDecisionPolicy.ask(fallback: askFallback))
                        ForEach(rules, id: \.id) { r in
                            Text("Route to: \(r.label)").tag(RouterDecisionPolicy.route(ruleID: r.id))
                        }
                        Text("End workflow here").tag(RouterDecisionPolicy.endBranch)
                        Text("Fail this node").tag(RouterDecisionPolicy.failNode)
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                // ⚠️ Shown only for Ask, because it only means anything there — and it is REQUIRED
                // rather than implicit: an unattended run (scheduled, or started from a chat bridge)
                // renders no banner anyone can see, so it never parks. Before the redesign that
                // degrade was hardcoded to "first match" and invisible; a 3am workflow author had no
                // way to see what would actually happen.
                if case .ask = decisionPolicy {
                    Divider()
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("If nobody can answer")
                                .font(theme.fontBody.weight(.medium))
                                .foregroundColor(theme.primaryText)
                            Text(askFallbackDescription)
                                .font(.system(.caption))
                                .foregroundColor(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 24)
                        Picker("", selection: $askFallback) {
                            Text("Fail this node").tag(RouterDecisionPolicy.AskFallback.failNode)
                            ForEach(rules, id: \.id) { r in
                                Text("Route to: \(r.label)").tag(RouterDecisionPolicy.AskFallback.route(ruleID: r.id))
                            }
                            Text("End workflow here").tag(RouterDecisionPolicy.AskFallback.endBranch)
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        // Keep the outer selection's payload in step, so the tag above still matches.
                        .onChange(of: askFallback) { _, newValue in
                            if case .ask = decisionPolicy { decisionPolicy = .ask(fallback: newValue) }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    /// ⚠️ Every caption names BOTH triggers, because one setting now governs both and a caption
    /// mentioning only one would repeat the mistake the old "Unmatched Input" label made.
    private var decisionDescription: String {
        switch decisionPolicy {
        case .ask:
            return "Whether several rules matched or none did, the run pauses and waits for you to pick a branch — for as long as it takes. Unattended runs never pause; they use the setting below."
        case .route(let ruleID):
            let label = rules.first(where: { $0.id == ruleID })?.label ?? "a deleted rule ⚠️"
            return "Whether several rules matched or none did, the input routes to '\(label)' as if that rule had matched. ⚠️ When several DID match, this overrides them — those branches will not run."
        case .endBranch:
            return "Whether several rules matched or none did, the workflow ends here gracefully: nothing downstream runs, nothing is reported as failed, and this node's content becomes the final output. Parallel branches still finish."
        case .failNode:
            return "Whether several rules matched or none did, this node fails and its error port activates — wire that port to handle it, or the branch stops with the reason in the final output. The reason says which case it was."
        }
    }

    private var askFallbackDescription: String {
        switch askFallback {
        case .failNode:
            return "A scheduled or chat-bridge run fails this node instead of waiting — the reason lands on the error port."
        case .route(let ruleID):
            let label = rules.first(where: { $0.id == ruleID })?.label ?? "a deleted rule ⚠️"
            return "A scheduled or chat-bridge run routes to '\(label)' instead of waiting."
        case .endBranch:
            return "A scheduled or chat-bridge run ends this branch instead of waiting."
        }
    }

    // MARK: - 3. Pattern Rules Card

    private var patternRulesCard: some View {
        SettingsCard(title: "Pattern Rules", icon: "list.bullet", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                // Counter
                HStack {
                    // ⚠️ NOT "first match wins" — that is the LEGACY arm (`decisionPolicy == nil`). On a node
                    // carrying a policy, which is every node ever saved from this panel,
                    // `decided = distinctMatched.count == 1 ? distinctMatched[0] : nil`, so several
                    // matches fall through to "When Routing Can't Decide" instead.
                    Text("Rules are evaluated top-to-bottom. Exactly one match routes to that rule's port; if several match, the setting below decides.")
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
                                .prefix(ConditionNodeConfig.maxLabelLength)
                        )
                        if rule.wrappedValue.label != sanitized {
                            rule.wrappedValue.label = sanitized
                        }
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
                //
                // [INS-10] The options are `allCases` PLUS the rule's own operator when that is not
                // in `allCases`. `ConditionOp.other(_)` is a real, reachable case — it holds a newer
                // build's operator (WF-PE3) and the RETIRED `always`, which the enum's own note says
                // "now decodes to `.other("always")`". With no matching tag the Picker rendered
                // BLANK, so a legacy catch-all rule showed an empty operator with nothing to explain
                // it, on a rule the engine treats as permanently inert.
                //
                // ⚠️ Offering it does NOT rewrite it: re-selecting the same value is a no-op, and
                // choosing a real operator is the user's explicit migration. That is the house
                // pattern for preserved-but-unknown values (`WorkflowNodeKind.unsupported`,
                // `StickyNoteColor.other`) — show it honestly, never silently replace it.
                Picker("", selection: rule.op) {
                    ForEach(Self.operatorOptions(including: rule.wrappedValue.op), id: \.self) { op in
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
            // ⚠️ Mirrors `WorkflowValidation`'s `requiresValue` switch. Two copies of one
            // predicate, in inverted form, in different files — adding an operator means editing
            // both or the value box and the validator disagree.
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
                        // ⚠️ Pre-fill on ENABLE only, and only into an empty field — never over
                        // text the user wrote. An empty prompt is also a genuine runtime fault the
                        // classifier guards on, so seeding it here is what makes the field's
                        // pre-filled state and the engine's expectation agree.
                        .onChange(of: llmFallbackEnabled) { _, enabled in
                            if enabled, llmPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                llmPrompt = ConditionNodeConfig.defaultRoutingPrompt
                            }
                        }
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
                            if llmPrompt != ConditionNodeConfig.defaultRoutingPrompt {
                                Button("Reset to default") {
                                    llmPrompt = ConditionNodeConfig.defaultRoutingPrompt
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 9))
                                .foregroundColor(theme.accentColor)
                            }
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

                        // ⚠️ The placeholder is the whole point: it expands to the CURRENT rule
                        // labels every run, so adding or renaming a rule never rewrites this text
                        // and never leaves it stale.
                        Text("\(ConditionNodeConfig.rulesPlaceholder) is replaced with your rule labels each run — edit the wording freely, but keep the placeholder so the model always sees the current branches.")
                            .font(.system(size: 9))
                            .foregroundColor(theme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)

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

    /// Seeds the unified control for a node that predates it (`decisionPolicy == nil`).
    ///
    /// ⚠️ THE MIGRATION TABLE, in code. It is a best-effort approximation and cannot be exact: the
    /// legacy pair is 2×3 and this axis is 4, so some combinations shift. Every shift is on the
    /// AMBIGUITY side, because the legacy ambiguity default was a silent "first matching rule" —
    /// implicit rule-order priority — and that option was deliberately dropped from the redesign
    /// (user decision 2026-08-17). Nothing is written until the user hits Save, so seeing this
    /// pre-selected IS the notice.
    ///
    /// ⚠️ A legacy catch-all (`fallbackLabel`) outranks `noMatchBehavior` at runtime today, so it
    /// seeds the route — otherwise saving would silently move where unmatched input goes.
    /// Which route target a policy names that no longer exists on this node, and what to write
    /// instead (register INS-7).
    ///
    /// ⚠️ Pure and `static` for the same reason `seedPolicy` is: a repair that CHANGES the author's
    /// stored routing decision must be provable from a test, and the `if case` chain it replaces
    /// lived inside `saveAndDismiss`, which a test cannot reach.
    ///
    /// ⚠️ EXHAUSTIVE, with no `default:` — a new `RouterDecisionPolicy` case must break this build
    /// rather than silently persist a target nothing checks.
    enum DanglingRouteRepair: Equatable {
        case none
        /// The policy itself pointed at `ruleID`; write `.failNode`.
        case policy(ruleID: UUID)
        /// The `ask` fallback pointed at `ruleID`; write `.ask(fallback: .failNode)`.
        case askFallback(ruleID: UUID)
    }

    /// The operator menu's options: every operator this build can evaluate, plus `current` when it is
    /// not one of them, so a preserved-but-unevaluable operator has a tag to bind to instead of
    /// rendering as an empty dropdown (register INS-10).
    ///
    /// The unavailable operator sorts LAST — it is not something to pick, only something to see.
    nonisolated static func operatorOptions(including current: ConditionOp) -> [ConditionOp] {
        ConditionOp.allCases.contains(current)
            ? ConditionOp.allCases
            : ConditionOp.allCases + [current]
    }

    nonisolated static func danglingRouteRepair(
        in policy: RouterDecisionPolicy,
        against rules: [ConditionRule]
    ) -> DanglingRouteRepair {
        func exists(_ id: UUID) -> Bool { rules.contains { $0.id == id } }
        switch policy {
        case .route(let ruleID):       return exists(ruleID) ? .none : .policy(ruleID: ruleID)
        case .ask(.route(let ruleID)): return exists(ruleID) ? .none : .askFallback(ruleID: ruleID)
        case .ask(.failNode), .ask(.endBranch), .endBranch, .failNode: return .none
        }
    }

    /// One line per silent repair, naming what the user loses.
    ///
    /// ⚠️ `when` is supplied by the caller because the three repairs do NOT share a consequence: the
    /// no-match repair patches `noMatchBehavior` (so only input matching NO rule is affected), while
    /// the policy and ask-fallback repairs patch `decisionPolicy` (which also governs input matching
    /// SEVERAL rules). A single blended sentence would be wrong for two of the three.
    private func logDanglingRepair(target ruleID: UUID, what: String, when: String) {
        inspectorLogger.notice("[WF_CANVAS] Router '\(node.displayName)' [node \(node.id.uuidString.prefix(8))]: the \(what) pointed at rule \(ruleID.uuidString.prefix(8)), which was deleted in this editing session — saving 'fail the node' instead. CONSEQUENCE: \(when) now FAILS onto this node's error port rather than routing to the branch you had chosen; pick a new target in 'When Routing Can't Decide' if that is not what you want.")
    }

    static func seedPolicy(from config: ConditionNodeConfig) -> RouterDecisionPolicy {
        if let existing = config.decisionPolicy { return existing }

        // Where does unmatched input go today? The catch-all wins if there is one.
        let noMatchTarget: RouterDecisionPolicy
        if !config.fallbackLabel.isEmpty,
           let rule = config.rules.first(where: { $0.label == config.fallbackLabel }) {
            noMatchTarget = .route(ruleID: rule.id)
        } else {
            switch config.noMatchBehavior {
            case .failNode:            noMatchTarget = .failNode
            case .endWorkflow:         noMatchTarget = .endBranch
            case .route(let ruleID):   noMatchTarget = .route(ruleID: ruleID)
            }
        }

        // `askOnAmbiguity` on → the author wanted to be asked, so Ask, with the no-match behaviour
        // as the fallback. Off → they wanted it resolved silently, so keep the no-match behaviour
        // for both triggers.
        guard config.askOnAmbiguity else { return noMatchTarget }
        switch noMatchTarget {
        case .failNode:          return .ask(fallback: .failNode)
        case .endBranch:         return .ask(fallback: .endBranch)
        case .route(let ruleID): return .ask(fallback: .route(ruleID: ruleID))
        case .ask:               return .ask(fallback: .failNode)   // unreachable
        }
    }

    private func loadFromNode() {
        guard case .condition(let config) = node.kind else { return }
        loadedConfig = config
        rules = config.rules
        llmFallbackEnabled = config.llmFallbackEnabled
        llmPrompt = config.llmPrompt
        llmModelName = config.llmModelName
        askOnAmbiguity = config.askOnAmbiguity
        noMatchBehavior = config.noMatchBehavior
        let seeded = Self.seedPolicy(from: config)
        decisionPolicy = seeded
        if case .ask(let f) = seeded { askFallback = f }

        while rules.count < ConditionNodeConfig.minRules {
            rules.append(ConditionRule(label: nextAvailableLabel(), field: .upstreamOutput, op: .contains, value: ""))
        }

    }

    private func saveAndDismiss() {
        // [INS-6] The de-dup is `ConditionNodeConfig.deduplicatedLabel`, which REPLACES the label's
        // tail with the suffix instead of appending-then-truncating. The old inline form no-opped for
        // any already-10-character label, writing the duplicate through to the validator as a
        // blocking error.
        //
        // ⚠️ A rewrite here RENAMES AN OUTPUT PORT — rule labels are ports, and
        // `WorkflowEdge.sourcePortLabel` matches them by exact string.
        //
        // ⚠️ And `portRenameMap` REFUSES this particular rename, every time, by construction: the
        // duplicate's twin KEEPS the shared label, and the map drops any rename away from a label
        // another rule still carries ("an edge on it may belong to the keeper"). That refusal is
        // CORRECT — an edge on a shared label genuinely has no single owner — but it means the edge
        // stays on the surviving rule rather than following the renamed one. The log says that
        // rather than promising a re-point that cannot happen.
        var seen = Set<String>()
        for i in rules.indices {
            let original = rules[i].label
            let deduped = ConditionNodeConfig.deduplicatedLabel(original, taken: seen)
            if deduped != original {
                inspectorLogger.notice("[WF_CANVAS] Router '\(node.displayName)' [node \(node.id.uuidString.prefix(8))]: rule label '\(original)' duplicated another rule and was renamed to '\(deduped)' on Save. CONSEQUENCE: the run no longer refuses to start on a duplicate-label error, and this rule now has its own output port — but any edge already drawn from the shared '\(original)' port STAYS on the rule that kept that label, because an edge on a shared label has no single owner. Re-wire this rule's branch if it should have followed the rename.")
            }
            rules[i].label = deduped
            seen.insert(deduped)
        }

        // ⚠️ Start from the config we LOADED, never a fresh one. Building from scratch silently
        // dropped every field this view does not edit — `fallbackLabel` above all, whose picker was
        // retired but whose stored value is still honoured by the engine. A legacy Router with a
        // catch-all label lost it on the first Save from this panel, and unmatched input stopped
        // routing to the catch-all and started FAILING the node instead. The same shape would drop
        // any field added to `ConditionNodeConfig` in future without touching this view.
        var config = loadedConfig
        config.rules = rules
        config.llmFallbackEnabled = llmFallbackEnabled
        config.llmPrompt = String(llmPrompt.prefix(maxPromptLength))
        config.llmPortLabels = []
        config.llmModelName = llmModelName
        config.askOnAmbiguity = askOnAmbiguity
        // ⚠️ A route target whose rule was deleted IN THIS EDITING SESSION falls back to failNode
        // rather than persisting a dangling id — the validator would flag it, but not writing it
        // is better than writing-then-flagging.
        if case .route(let ruleID) = noMatchBehavior, !rules.contains(where: { $0.id == ruleID }) {
            logDanglingRepair(target: ruleID, what: "'When nothing matches' target", when: "input that matches no rule")
            config.noMatchBehavior = .failNode
        } else {
            config.noMatchBehavior = noMatchBehavior
        }

        // ⚠️ THE MIGRATION HAPPENS HERE — on an explicit Save, never at decode. The legacy 2×3
        // matrix does not collapse onto this axis losslessly, so seeding at decode would silently
        // change stored workflows their author never opened. Writing it here means the user has
        // seen the merged control and its captions before it takes effect.
        var policyToWrite = decisionPolicy
        if case .ask = policyToWrite { policyToWrite = .ask(fallback: askFallback) }
        // Same dangling-target repair as above, for both the policy and its fallback.
        // [INS-7] These three repairs SILENTLY changed the author's stored routing decision — the
        // sibling repair 20 lines below (clearing a legacy catch-all) has always logged; these did
        // not. The decision is extracted so it can be truth-tabled.
        switch Self.danglingRouteRepair(in: policyToWrite, against: rules) {
        case .none:
            break
        case .policy(let ruleID):
            logDanglingRepair(target: ruleID, what: "routing policy target", when: "input the router cannot decide (no rule matched, or several did)")
            policyToWrite = .failNode
        case .askFallback(let ruleID):
            logDanglingRepair(target: ruleID, what: "'If nobody can answer' fallback", when: "input the router cannot decide, on a run where nobody answers the prompt,")
            policyToWrite = .ask(fallback: .failNode)
        }
        config.decisionPolicy = policyToWrite

        // ⚠️ The legacy catch-all is CLEARED once a policy governs, or it would silently pre-empt
        // it: `resolveRouterPort` honours a non-empty `fallbackLabel` before any no-match logic
        // runs, and on the classifier side it also displaces the no-match sentinel. Safe because
        // the decode-time repair guarantees it names a real rule, whose port survives as an
        // ordinary rule port with its edges intact.
        if !config.fallbackLabel.isEmpty {
            inspectorLogger.notice("[WF_CANVAS] Router '\(node.displayName)': clearing legacy catch-all '\(config.fallbackLabel)' because this node now carries a routing policy. CONSEQUENCE: unmatched input follows 'When Routing Can't Decide' instead of silently routing to that rule; the rule itself and its edges are untouched.")
            config.fallbackLabel = ""
        }
        node.kind = .condition(config)

        // [INS-11] The `if node.nodeConfig == nil { node.nodeConfig = WorkflowNodeConfig() }` that
        // stood here is GONE. Its comment said "persist fan-in behaviour", but `joinMode` was
        // retired 2026-08-13 (decode/encode only) and a Router has no other per-node config this
        // panel edits — so the line's only effect was to turn `nil` into `.some(defaults)`, which
        // `replaceNode`'s equality guard cannot absorb. That made every Save a real mutation:
        // opening a Router, changing nothing and pressing Save dirtied the canvas and burned an
        // undo slot. (Harmless at RUN time for this kind — only Profile and Action nodes read
        // retries — which is exactly why nothing was noticing.)

        closeInspector()
    }
}

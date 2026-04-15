//
//  WorkflowConfigSheet.swift
//  Devgentic
//
//  Created by Raj Singh on 13/04/26.
//
//  Configuration sheet for workflow-level execution defaults.
//  Mirrors the pattern established by ConditionNodeInspectorView —
//  header with cancel/save, scrollable form body, themed sections.
//  Changes persist through the canvas save flow (profile binding + markDirty).
//

import SwiftUI

struct WorkflowConfigSheet: View {
    @Binding var profile: BackendProfileModel
    let onDirty: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    // MARK: - Execution Defaults

    @State private var nodeTimeout: Double = 120
    @State private var failurePolicy: NodeFailurePolicy = .skipDependents
    @State private var maxRetries: Int = 0

    // MARK: - Context Pipeline

    @State private var contextBudgetPerNode: Int = 2000
    @State private var totalContextBudget: Int = 6000

    // MARK: - Advanced

    @State private var maxNestingDepth: Int = 5

    // MARK: - Guide

    @State private var showGuide: Bool = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    guideCard
                    executionDefaultsCard
                    contextPipelineCard
                    advancedCard
                }
                .padding(24)
            }
        }
        .frame(width: 540, height: 560)
        .background(theme.primaryBackground)
        .onAppear { loadFromProfile() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.purple)
            Text("Workflow Settings")
                .font(theme.fontSubheadline.weight(.semibold))
                .foregroundColor(theme.primaryText)
            Text("\u{00B7}")
                .foregroundColor(theme.tertiaryText)
            Text(profile.displayName)
                .font(theme.fontCaption)
                .foregroundColor(theme.secondaryText)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showGuide.toggle() }
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(theme.fontBody)
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("About workflow settings")
            Button("Cancel") { dismiss() }
                .font(theme.fontCaption)
                .buttonStyle(.plain)
                .foregroundColor(theme.secondaryText)
            Button("Save") { saveAndDismiss() }
                .font(theme.fontCaption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundColor(theme.accentColor)
                .keyboardShortcut(.defaultAction)
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
                        title: "Execution Defaults",
                        subtitle: "per-workflow",
                        description: "Timeout, failure policy, and retry defaults applied to every node unless overridden by per-node config.",
                        color: .blue
                    )
                    guideStep(
                        number: "2",
                        title: "Context Pipeline",
                        subtitle: "budgets",
                        description: "Controls how much upstream text is passed between nodes. Increase for larger models with bigger context windows.",
                        color: .green
                    )
                    guideStep(
                        number: "3",
                        title: "Advanced",
                        subtitle: "safety",
                        description: "Nesting depth limit prevents infinite recursion when workflows contain sub-workflow nodes.",
                        color: .orange
                    )

                    guideTip("These settings apply as defaults to all nodes. Per-node settings (WorkflowNodeConfig) override these.")
                }
                .padding(.top, 10)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed")
                        .font(.system(.caption, weight: .medium))
                        .foregroundColor(.yellow)
                    Text("About Workflow Settings")
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

    // MARK: - 2. Execution Defaults Card

    private var executionDefaultsCard: some View {
        SettingsCard(title: "Execution Defaults", icon: "bolt.circle", theme: theme) {
            VStack(alignment: .leading, spacing: 10) {
                // Default Node Timeout
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Default Node Timeout")
                            .font(theme.fontCaption.weight(.medium))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        Text("\(Int(nodeTimeout))s")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 44, alignment: .trailing)
                    }
                    Slider(value: $nodeTimeout, in: 10...600, step: 10)
                        .controlSize(.small)
                    Text("Maximum wall-clock time per node before timeout. Overridden by per-node hard timeout.")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }

                Divider()

                // Default Failure Policy
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default Failure Policy")
                        .font(theme.fontCaption.weight(.medium))
                        .foregroundColor(theme.primaryText)
                    Picker("", selection: $failurePolicy) {
                        Text("Skip Dependents").tag(NodeFailurePolicy.skipDependents)
                        Text("Stop Workflow").tag(NodeFailurePolicy.stopWorkflow)
                        Text("Continue All").tag(NodeFailurePolicy.continueAll)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    Text(failurePolicyHelp)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }

                Divider()

                // Default Max Retries
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Default Max Retries")
                            .font(theme.fontCaption.weight(.medium))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        Stepper("\(maxRetries)", value: $maxRetries, in: 0...5)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 100)
                    }
                    Text("Number of automatic retries on transient failures. Overridden by per-node config.")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }
            }
        }
    }

    // MARK: - 3. Context Pipeline Card

    private var contextPipelineCard: some View {
        SettingsCard(title: "Context Pipeline", icon: "text.alignleft", theme: theme) {
            VStack(alignment: .leading, spacing: 10) {
                // Per-Node Budget
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Per-Node Budget")
                            .font(theme.fontCaption.weight(.medium))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        Text("\(contextBudgetPerNode) chars")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(contextBudgetPerNode) },
                            set: { contextBudgetPerNode = Int($0) }
                        ),
                        in: 500...50000,
                        step: 500
                    )
                    .controlSize(.small)
                    Text("Maximum characters per upstream node output before truncation.")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }

                Divider()

                // Total Context Budget
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Total Context Budget")
                            .font(theme.fontCaption.weight(.medium))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        Text("\(totalContextBudget) chars")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(totalContextBudget) },
                            set: { totalContextBudget = Int($0) }
                        ),
                        in: 1000...100000,
                        step: 1000
                    )
                    .controlSize(.small)
                    Text("Maximum total characters for all upstream context combined. Increase for larger models with bigger context windows.")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }
            }
        }
    }

    // MARK: - 4. Advanced Card

    private var advancedCard: some View {
        SettingsCard(title: "Advanced", icon: "wrench.and.screwdriver", theme: theme) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Max Nesting Depth")
                        .font(theme.fontCaption.weight(.medium))
                        .foregroundColor(theme.primaryText)
                    Spacer()
                    Stepper("\(maxNestingDepth)", value: $maxNestingDepth, in: 1...10)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 100)
                }
                Text("Maximum depth for sub-workflow recursion. Prevents infinite loops when workflows contain workflow nodes.")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    // MARK: - Helpers

    private var failurePolicyHelp: String {
        switch failurePolicy {
        case .skipDependents:
            return "When a node fails, skip all downstream dependent nodes."
        case .stopWorkflow:
            return "When a node fails, halt the entire workflow immediately."
        case .continueAll:
            return "When a node fails, continue executing all remaining nodes regardless."
        }
    }

    // MARK: - Load / Save

    private func loadFromProfile() {
        guard case .workflow(let config) = profile.details else { return }
        nodeTimeout = config.resolvedNodeTimeout
        failurePolicy = config.resolvedFailurePolicy
        maxRetries = config.resolvedMaxRetries
        contextBudgetPerNode = config.resolvedContextBudgetPerNode
        totalContextBudget = config.resolvedTotalContextBudget
        maxNestingDepth = config.resolvedMaxNestingDepth
    }

    private func saveAndDismiss() {
        var config: WorkflowConfig
        if case .workflow(let existing) = profile.details {
            config = existing
        } else {
            config = WorkflowConfig(agentProfileIDs: [])
        }

        // Store nil when value matches system default (keeps serialized data clean)
        config.defaultNodeTimeout = (nodeTimeout == 120) ? nil : nodeTimeout
        config.defaultFailurePolicy = (failurePolicy == .skipDependents) ? nil : failurePolicy
        config.defaultMaxRetries = (maxRetries == 0) ? nil : maxRetries
        config.contextBudgetPerNode = (contextBudgetPerNode == 2000) ? nil : contextBudgetPerNode
        config.totalContextBudget = (totalContextBudget == 6000) ? nil : totalContextBudget
        config.maxNestingDepth = (maxNestingDepth == 5) ? nil : maxNestingDepth

        profile.details = .workflow(config)
        onDirty()
        dismiss()
    }
}

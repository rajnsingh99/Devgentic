//
//  LoopNodeInspectorView.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Configuration sheet for Loop nodes — card-based layout.
//  Allows the user to:
//  - Pick a body workflow (sub-workflow to iterate)
//  - Set max iterations (1-50)
//  - Optionally configure an early-exit condition (reuses ConditionRule)
//

import SwiftUI

struct LoopNodeInspectorView: View {
    @Binding var node: WorkflowNode
    let parentWorkflowID: UUID
    let availableWorkflows: [BackendProfileModel]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    // Local editing state
    @State private var maxIterations: Int = 3
    @State private var bodyWorkflowID: UUID? = nil
    @State private var bodyWorkflowName: String? = nil
    @State private var hasExitCondition: Bool = false
    @State private var exitField: ConditionField = .upstreamOutput
    @State private var exitOp: ConditionOp = .contains
    @State private var exitValue: String = ""
    @State private var exitVariableName: String = ""
    @State private var showGuide: Bool = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    guideCard
                    bodyWorkflowCard
                    iterationsCard
                    exitConditionCard
                }
                .padding(24)
            }
        }
        .frame(width: 540, height: 560)
        .background(theme.primaryBackground)
        .onAppear { loadFromNode() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.orange)
            Text("Loop")
                .font(theme.fontSubheadline.weight(.semibold))
                .foregroundColor(theme.primaryText)
            Text("\u{00B7}")
                .foregroundColor(theme.tertiaryText)
            Text(node.displayName)
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
            .help("How loop nodes work")
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
                        title: "Body Workflow",
                        subtitle: "sub-workflow",
                        description: "Select a workflow to execute repeatedly. Each iteration's output becomes the next iteration's input.",
                        color: .orange
                    )
                    guideStep(
                        number: "2",
                        title: "Iterations",
                        subtitle: "limit",
                        description: "Set the maximum number of times the body runs (1-50).",
                        color: .blue
                    )
                    guideStep(
                        number: "3",
                        title: "Exit Condition",
                        subtitle: "optional",
                        description: "Optionally stop early when a condition is met on the iteration output.",
                        color: .green
                    )

                    guideTip("Variables written by Code nodes inside the loop body are scoped to the sub-workflow and don't propagate to the parent.")
                }
                .padding(.top, 10)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed")
                        .font(.system(.caption, weight: .medium))
                        .foregroundColor(.orange)
                    Text("How Loop Nodes Work")
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

    // MARK: - 2. Body Workflow Card

    private var bodyWorkflowCard: some View {
        SettingsCard(title: "Body Workflow", icon: "arrow.triangle.2.circlepath", theme: theme) {
            if filteredWorkflows.isEmpty {
                Label("No workflow profiles available.", systemImage: "exclamationmark.triangle")
                    .foregroundColor(theme.secondaryText)
                    .font(.caption)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(filteredWorkflows) { wf in
                        Button {
                            bodyWorkflowID = wf.id
                            bodyWorkflowName = wf.displayName
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: ProfileType.workflow.iconName)
                                    .foregroundColor(.purple)
                                    .frame(width: 20)

                                Text(wf.displayName)
                                    .font(theme.fontSubheadline)
                                    .foregroundColor(theme.primaryText)

                                Spacer()

                                if bodyWorkflowID == wf.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(theme.accentColor)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 3. Iterations Card

    private var iterationsCard: some View {
        SettingsCard(title: "Iterations", icon: "number", theme: theme) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Max Iterations")
                        .font(theme.fontBody.weight(.medium))
                        .foregroundColor(theme.primaryText)
                    Text("The body workflow runs up to \(maxIterations) time\(maxIterations == 1 ? "" : "s").")
                        .font(.system(.caption))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 24)
                Stepper("\(maxIterations)", value: $maxIterations, in: 1...50)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(maxWidth: 120)
            }
        }
    }

    // MARK: - 4. Exit Condition Card

    private var exitConditionCard: some View {
        SettingsCard(title: "Exit Condition", icon: "arrow.uturn.right", theme: theme) {
            VStack(alignment: .leading, spacing: 14) {
                // Enable toggle
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Early Exit")
                            .font(theme.fontBody.weight(.medium))
                            .foregroundColor(theme.primaryText)
                        Text("Stop the loop before reaching max iterations when a condition is met.")
                            .font(.system(.caption))
                            .foregroundColor(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 24)
                    Toggle("", isOn: $hasExitCondition)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                if hasExitCondition {
                    Divider()

                    // Field picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Evaluate")
                            .font(theme.fontCaption.weight(.medium))
                            .foregroundColor(theme.secondaryText)

                        Picker("", selection: $exitField) {
                            Text("Body Output").tag(ConditionField.upstreamOutput)
                            Text("Variable").tag(ConditionField.variable)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    // Variable name field
                    if exitField == .variable {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Variable Name")
                                .font(theme.fontCaption.weight(.medium))
                                .foregroundColor(theme.secondaryText)

                            TextField("Variable name", text: $exitVariableName)
                                .font(.system(size: 12, design: .monospaced))
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                                        .fill(theme.controlBackground)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                                        .stroke(theme.surfaceOverlayStrong.opacity(0.3), lineWidth: 0.5)
                                )
                        }
                    }

                    // Operator picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Operator")
                            .font(theme.fontCaption.weight(.medium))
                            .foregroundColor(theme.secondaryText)

                        Picker("", selection: $exitOp) {
                            ForEach(ConditionOp.allCases, id: \.self) { op in
                                Text(op.displayName).tag(op)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .font(.system(size: 12))
                    }

                    // Value field
                    if exitOp != .isEmpty && exitOp != .isNotEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Value to Match")
                                .font(theme.fontCaption.weight(.medium))
                                .foregroundColor(theme.secondaryText)

                            TextField("Value to match", text: $exitValue)
                                .font(.system(size: 12))
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                                        .fill(theme.controlBackground)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                                        .stroke(theme.surfaceOverlayStrong.opacity(0.3), lineWidth: 0.5)
                                )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var filteredWorkflows: [BackendProfileModel] {
        availableWorkflows.filter { $0.id != parentWorkflowID && $0.profileType == .workflow }
    }

    private func loadFromNode() {
        guard case .loop(let config) = node.kind else { return }
        maxIterations = config.maxIterations
        bodyWorkflowID = config.bodyWorkflowID
        bodyWorkflowName = config.bodyWorkflowName
        if let exit = config.exitCondition {
            hasExitCondition = true
            exitField = exit.field
            exitOp = exit.op
            exitValue = exit.value
            exitVariableName = exit.variableName ?? ""
        }
    }

    private func saveAndDismiss() {
        let exitCondition: ConditionRule? = hasExitCondition
            ? ConditionRule(
                label: "exit",
                field: exitField,
                op: exitOp,
                value: exitValue,
                variableName: exitField == .variable ? (exitVariableName.isEmpty ? nil : exitVariableName) : nil
            )
            : nil

        let config = LoopNodeConfig(
            bodyWorkflowID: bodyWorkflowID,
            bodyWorkflowName: bodyWorkflowName,
            maxIterations: maxIterations,
            exitCondition: exitCondition
        )
        node.kind = .loop(config)
        dismiss()
    }
}

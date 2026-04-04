//
//  SubAgentConfigView.swift
//  Devgentic
//
//  Sheet view for creating or editing an inline sub-agent.
//  Uses SettingsCard/SettingsRow pattern for consistency with the rest of the app.
//

import SwiftUI

struct SubAgentConfigView: View {

    @Binding var subAgent: SubAgentConfig
    let isNew: Bool
    var onSave: (SubAgentConfig) -> Void
    var onCancel: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var draft: SubAgentConfig

    init(subAgent: Binding<SubAgentConfig>, isNew: Bool, onSave: @escaping (SubAgentConfig) -> Void, onCancel: @escaping () -> Void) {
        self._subAgent = subAgent
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        self._draft = State(initialValue: subAgent.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 0) {

            // MARK: - Header
            header
                .padding(20)

            Divider().background(theme.dividerColor)

            // MARK: - Content
            ScrollView {
                VStack(spacing: 32) {

                    // 1. Identity
                    SettingsCard(title: "Identity", icon: "person.text.rectangle", theme: theme) {
                        SettingsRow(title: "Name", description: "Used by the parent agent to call this sub-agent.", theme: theme) {
                            TextField("e.g. SecurityReviewer", text: $draft.name)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(theme.secondaryBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.dividerColor, lineWidth: 1))
                                .frame(minWidth: 200)
                        }

                        Divider().background(theme.dividerColor)

                        SettingsRow(title: "Purpose", description: "One-line description visible to the parent agent's LLM.", theme: theme) {
                            TextField("e.g. Reviews code for security vulnerabilities", text: $draft.purpose)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(theme.secondaryBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.dividerColor, lineWidth: 1))
                                .frame(minWidth: 200)
                        }
                    }

                    // 2. System Prompt
                    SettingsCard(title: "System Prompt", icon: "text.quote", theme: theme) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Instructions")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(theme.primaryText)
                            Text("System prompt when this sub-agent runs. Define its persona, expertise, and behavior.")
                                .font(.system(size: 12))
                                .foregroundColor(theme.secondaryText)
                                .lineSpacing(2)

                            TextEditor(text: $draft.instructions)
                                .font(.body)
                                .frame(minHeight: 120)
                                .padding(8)
                                .scrollContentBackground(.hidden)
                                .background(theme.secondaryBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.dividerColor, lineWidth: 1))
                        }
                        .padding(16)
                    }

                    // 3. Inference Engine
                    SettingsCard(title: "Inference Engine", icon: "cpu", theme: theme) {
                        ProviderConfigSection(
                            providerConfig: $draft.llmConfig,
                            profileID: draft.id,
                            profileType: .agent
                        )
                        .padding(16)
                    }

                    // 4. Execution
                    SettingsCard(title: "Execution", icon: "gauge.with.dots.needle.33percent", theme: theme) {
                        SettingsRow(title: "Max Iterations", description: "How many reasoning steps the sub-agent can take.", theme: theme) {
                            Stepper("\(draft.maxIterations)", value: $draft.maxIterations, in: 3...30)
                                .fixedSize()
                        }
                    }
                }
                .padding(24)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .background(theme.primaryBackground)

            // MARK: - Footer
            Divider().background(theme.dividerColor)

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundColor(theme.secondaryText)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isNew ? "Create Sub-Agent" : "Save Changes") {
                    subAgent = draft
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(16)
            .background(theme.secondaryBackground)
        }
        .frame(width: 650, height: 700)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.1))
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "person.fill.viewfinder")
                        .font(.system(size: 20))
                        .foregroundColor(.accentColor)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(isNew ? "New Sub-Agent" : "Edit Sub-Agent")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(theme.primaryText)
                Text("Configure a specialist that this agent can delegate tasks to.")
                    .font(.subheadline)
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.purpose.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.instructions.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.llmConfig.modelName.isEmpty
    }
}

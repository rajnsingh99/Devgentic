// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingBehaviorView.swift
//  Devgentic
//
//  The profile's tools and system prompt, so the user lands on a profile that is ready to run.
//  An agent gets the ten starter tools, all on and all set to Ask; a chat bot gets only the prompt.
//

import SwiftUI

struct OnboardingBehaviorView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.appTheme) private var theme

    private var isAgent: Bool { viewModel.selectedProfileType == .agent }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    header

                    if isAgent {
                        toolsSection
                    }

                    promptSection
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
            }

            HStack {
                OnboardingSecondaryButton("Back", icon: "chevron.left") {
                    viewModel.goToStep(.modelDownload)
                }

                Spacer()

                // Not the default action: Return belongs to the system-prompt editor on this step.
                OnboardingPrimaryButton("Continue", isDefaultAction: false) {
                    viewModel.goToStep(.features)
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 32)
            .padding(.top, 10)
            .padding(.bottom, 22)
        }
    }

    // MARK: - Header
    private var header: some View {
        VStack(spacing: 8) {
            Text(OnboardingViewModel.Step.behavior.progressLabel ?? "")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .tracking(1.0)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())

            Text(isAgent ? String(localized: "Tools & Instructions") : String(localized: "Instructions"))
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(theme.primaryText)

            Text(isAgent
                 ? String(localized: "Choose what your agent can do on this Mac. It asks before every tool call unless you allow one.")
                 : String(localized: "Tell your assistant how to behave. You can change this any time in the profile editor."))
                .font(theme.fontBody)
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    // MARK: - Tools
    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tools")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text("\(viewModel.enabledToolNames.count) of \(OnboardingToolPreset.tools.count) on")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(OnboardingToolPreset.tools) { tool in
                    toolCard(tool)
                }
            }

            Text("You can add more tools later from the Tool Library.")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
        }
    }

    @ViewBuilder
    private func toolCard(_ tool: OnboardingStarterTool) -> some View {
        let isOn = viewModel.enabledToolNames.contains(tool.id)
        let asks = !viewModel.autoApprovedToolNames.contains(tool.id)

        HStack(spacing: 10) {
            Button(action: { viewModel.toggleTool(tool.id) }) {
                HStack(spacing: 10) {
                    Image(systemName: isOn ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15))
                        .foregroundColor(isOn ? Color.accentColor : theme.secondaryText.opacity(0.7))

                    Image(systemName: tool.iconName)
                        .font(.system(size: 13))
                        .foregroundColor(isOn ? theme.primaryText : theme.secondaryText)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(tool.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(isOn ? theme.primaryText : theme.secondaryText)
                        Text(tool.purpose)
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .accessibilityLabel("\(tool.title): \(tool.purpose)")
            .accessibilityAddTraits(isOn ? .isSelected : [])

            Button(action: { viewModel.setAutoApprove(asks, for: tool.id) }) {
                Text(asks ? String(localized: "Ask") : String(localized: "Allow"))
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((asks ? Color.accentColor : Color.orange).opacity(0.14))
                    .foregroundColor(asks ? Color.accentColor : .orange)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointingHandCursor(enabled: isOn)
            .disabled(!isOn)
            .opacity(isOn ? 1 : 0.4)
            .help(asks ? String(localized: "Asks for your approval before each use. Click to allow without asking.")
                       : String(localized: "Runs without asking. Click to ask first."))
            .accessibilityLabel("\(tool.title) permission")
            .accessibilityValue(asks ? String(localized: "Ask before each use") : String(localized: "Allow without asking"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isOn ? Color.accentColor.opacity(0.06) : theme.secondaryBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isOn ? Color.accentColor.opacity(0.5) : theme.dividerColor, lineWidth: 1)
        )
    }

    // MARK: - System Prompt
    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("System Prompt")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                if viewModel.systemPrompt != OnboardingPromptDefaults.prompt(for: viewModel.selectedProfileType) {
                    Button("Reset to Default") { viewModel.resetSystemPrompt() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.accentColor)
                        .pointingHandCursor()
                }
            }

            TextEditor(text: $viewModel.systemPrompt)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: isAgent ? 120 : 200)
                .background(theme.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(theme.dividerColor, lineWidth: 1)
                )
                .accessibilityLabel("System prompt")
        }
    }
}

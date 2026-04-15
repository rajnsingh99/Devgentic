//
//  PromptDetailContainerView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//
//  Displays a prompt's editable details in the main content area.
//  DynamicIslandBar handles Save and Delete actions.
//

import SwiftUI

struct PromptDetailContainerView: View {

    let promptID: UUID

    @State private var viewModel = PromptLibraryViewModel()
    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme

    @State private var isDeleteHovered = false
    @FocusState private var isTitleFocused: Bool

    private let categories = ["General", "Development", "Productivity", "Creativity", "Writing", "Education", "Research", "Marketing", "Custom"]

    private var prompt: DevPrompt? {
        PromptService.shared.prompts.first(where: { $0.id == promptID })
    }

    var body: some View {
        VStack(spacing: 0) {
            DynamicIslandBar {
                actionButtons
            }

            if prompt != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {

                        // Title
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Title")
                                .font(.system(.caption, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                                .textCase(.uppercase)
                                .tracking(0.5)

                            TextField("Enter a clear and concise title", text: $viewModel.editablePromptTitle)
                                .font(.system(.title3, weight: .medium))
                                .textFieldStyle(.plain)
                                .foregroundColor(theme.primaryText)
                                .focused($isTitleFocused)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(theme.surfaceOverlay)
                                )
                        }

                        // Category
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Category")
                                .font(.system(.caption, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                                .textCase(.uppercase)
                                .tracking(0.5)

                            Picker("", selection: $viewModel.editablePromptCategory) {
                                ForEach(categories, id: \.self) { cat in
                                    Text(cat).tag(cat)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        // Prompt Text
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Prompt Text")
                                .font(.system(.caption, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                                .textCase(.uppercase)
                                .tracking(0.5)

                            TextEditor(text: $viewModel.editablePromptText)
                                .font(theme.fontBody)
                                .scrollContentBackground(.hidden)
                                .padding(12)
                                .frame(minHeight: 250)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(theme.surfaceOverlay)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(theme.dividerColor.opacity(0.5), lineWidth: 0.5)
                                )
                        }

                        // Tags
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Tags")
                                .font(.system(.caption, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                                .textCase(.uppercase)
                                .tracking(0.5)

                            TextField("Comma-separated, e.g., coding, python", text: $viewModel.editablePromptTagsString)
                                .font(theme.fontBody)
                                .textFieldStyle(.plain)
                                .foregroundColor(theme.primaryText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(theme.surfaceOverlay)
                                )
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 1000)
                    .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36)) // Fixed size: intentional (icon)
                        .foregroundColor(theme.secondaryText)
                    Text("Prompt not found")
                        .font(.title3)
                        .foregroundColor(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            loadPrompt()
        }
        .onChange(of: promptID) {
            loadPrompt()
        }
    }

    private func loadPrompt() {
        if let prompt = prompt {
            viewModel.prepareToEditPrompt(prompt)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.1))
                isTitleFocused = true
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            // Save changes
            Button {
                viewModel.savePromptFromSheet()
            } label: {
                Text("Save")
                    .font(.system(.caption, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(theme.surfaceOverlay))
            .disabled(viewModel.editablePromptTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                      viewModel.editablePromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            // Delete
            Button(role: .destructive) {
                if let prompt = prompt {
                    viewModel.deletePrompt(prompt)
                    router.returnToChat()
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(.caption, weight: .medium))
                    .foregroundColor(isDeleteHovered ? .white : .red.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(isDeleteHovered ? Color.red : Color.red.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)
            .onHover { isDeleteHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: isDeleteHovered)
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CreateEditPromptView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

struct CreateEditPromptView: View {
    @Environment(PromptEditViewModel.self) var viewModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.appTheme) private var theme

    @State private var showingDiscardAlert: Bool = false
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        @Bindable var viewModel = viewModel

        VStack(spacing: 0) {
            Text(viewModel.isCreating ? "Create New Prompt" : "Edit Prompt")
                .font(.title2)
                .fontWeight(.semibold)
                .padding()

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 20) {
                GridRow(alignment: .center) {
                    Text("Title")
                        .gridColumnAlignment(.trailing)

                    TextField("Enter a clear and concise title", text: $viewModel.title)
                        .textFieldStyle(.roundedBorder)
                        .focused($isTitleFocused)
                }

                GridRow(alignment: .center) {
                    Text("Category")
                        .gridColumnAlignment(.trailing)

                    Picker("Category", selection: $viewModel.category) {
                        ForEach(PromptCategory.allCases) { category in
                            Text(category.displayName).tag(category)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                GridRow(alignment: .top) {
                    Text("Prompt Text")
                        .gridColumnAlignment(.trailing)
                        .padding(.top, 8)

                    TextEditor(text: $viewModel.text)
                        .font(.body)
                        .frame(minHeight: 150, maxHeight: 400)
                        .padding(5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.dividerColor.opacity(0.6), lineWidth: 1)
                        )
                }

                GridRow(alignment: .center) {
                    Text("Tags")
                        .gridColumnAlignment(.trailing)

                    TextField("Comma-separated, e.g., coding, python", text: $viewModel.tagsString)
                        .textFieldStyle(.roundedBorder)
                        .help("Use commas to separate multiple tags.")
                }

                GridRow(alignment: .center) {
                    Text("Pin")
                        .gridColumnAlignment(.trailing)

                    Toggle(isOn: $viewModel.isPinned) {
                        Text("Pinned to top of sidebar")
                            .font(.callout)
                    }
                    .toggleStyle(.switch)
                }
            }
            .padding(20)

            Spacer()

            Divider()

            HStack {
                TactileButton(title: "Cancel", variant: .subtle, size: .compact) {
                    attemptDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                TactileButton(
                    title: viewModel.isCreating ? "Create Prompt" : "Save Changes",
                    icon: viewModel.isCreating ? "plus" : "checkmark",
                    variant: .primary,
                    size: .compact,
                    isDisabled: !viewModel.canSave
                ) {
                    _ = viewModel.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .onAppear {
            // Defers one tick: SwiftUI's sheet-appear animation can drop focus set during `.onAppear`;
            // 50 ms lands after the animation without a visible flicker.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                isTitleFocused = true
            }
        }
        .confirmationDialog(
            "Discard unsaved changes?",
            isPresented: $showingDiscardAlert,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your edits to this prompt have not been saved.")
        }
    }

    private func attemptDismiss() {
        if viewModel.isDirty {
            showingDiscardAlert = true
        } else {
            dismiss()
        }
    }
}

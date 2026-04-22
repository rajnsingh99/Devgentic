//
//  CreateEditPromptView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//  Converted to sheet semantics + PromptEditViewModel on 2026-04-21.
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
                Button("Cancel") {
                    attemptDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(viewModel.isCreating ? "Create Prompt" : "Save Changes") {
                    _ = viewModel.save()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSave)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .onAppear {
            // Defer one run-loop tick via Task.sleep — SwiftUI's sheet-appear
            // animation sometimes drops focus set during `.onAppear`'s sync
            // pass. 50ms is enough to land after the animation tick without a
            // visible flicker. Replaces the old 100ms DispatchQueue workaround.
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

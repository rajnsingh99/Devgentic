//
//  SelectToolView.swift
//  Devgentic
//
//  Created by Raj Singh on 01/07/25.
//

import SwiftUI

/// A view that allows users to select multiple tools for an agent.
struct SelectToolView: View {
    @EnvironmentObject var toolStore: ToolStore
    @Binding var selectedTools: [SelectedTool]
    @Environment(\.dismiss) var dismiss

    /// A local state to manage the set of selected tool names for efficient multi-selection.
    @State private var selection: Set<String>

    init(selectedTools: Binding<[SelectedTool]>) {
        self._selectedTools = selectedTools
        // Initialize the local selection set from the parent view's binding.
        self._selection = State(initialValue: Set(selectedTools.wrappedValue.map { $0.toolName }))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            contentView
            Divider()
            footerView
        }
        .frame(minWidth: 500, idealWidth: 600, minHeight: 450, idealHeight: 600)
    }

    private var headerView: some View {
        HStack {
            Text("Select Agent Tools")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            // Add buttons to select all or none
            Button("Select All") {
                selection = Set(toolStore.availableTools.map { $0.toolName })
            }
            .disabled(toolStore.availableTools.isEmpty)
            
            Button("Deselect All") {
                selection.removeAll()
            }
            .disabled(selection.isEmpty)
        }
        .padding()
    }

    @ViewBuilder
    private var contentView: some View {
        if toolStore.isLoading {
            ProgressView("Loading Tools...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = toolStore.errorMessage {
            ContentUnavailableView {
                Label("Failed to Load Tools", systemImage: "xmark.octagon.fill")
            } description: {
                Text(errorMessage)
            }
        } else if toolStore.availableTools.isEmpty {
            ContentUnavailableView("No Tools Available", systemImage: "wrench.and.screwdriver")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // MODIFICATION: The `selection` parameter is removed from the List.
            // Selection is now handled manually by the `onTapGesture`.
            List(toolStore.availableTools) { tool in
                ToolRowView(tool: tool, isSelected: selection.contains(tool.toolName))
                    .contentShape(Rectangle()) // Ensures the entire row area is tappable
                    .onTapGesture {
                        // Manually toggle the tool's selection state.
                        if selection.contains(tool.toolName) {
                            selection.remove(tool.toolName)
                        } else {
                            selection.insert(tool.toolName)
                        }
                    }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var footerView: some View {
        HStack {
            Button("Cancel", role: .cancel) { dismiss() }
            Spacer()
            Button("Done") {
                updateSelectedToolsInParent()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    /// Updates the parent's `selectedTools` binding with the final selection.
    private func updateSelectedToolsInParent() {
        selectedTools = selection.compactMap { toolName in
            if let tool = toolStore.availableTools.first(where: { $0.toolName == toolName }) {
                return SelectedTool(toolName: tool.toolName, displayName: tool.displayName)
            }
            return nil
        }
        .sorted { $0.displayName < $1.displayName } // Keep the list sorted
    }
}

/// A view for a single row in the tool selection list.
private struct ToolRowView: View {
    let tool: ToolModel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(tool.displayName).fontWeight(.semibold)
                Text(tool.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

//
//  ToolLibraryView.swift
//  Devgentic
//
//  Created by Raj Singh on 25/09/25.
//
//  Refactored on 28/09/25 to unify Local and MCP tool management.
//  Updated on 26/01/26 to integrate the V2 MCP Architecture (AddMCPServerView).
//

import SwiftUI

/// A view for managing and selecting all available tools, both built-in and from MCP servers.
struct ToolLibraryView: View {
    // A binding to the agent's currently configured tools.
    @Binding var configuredTools: [Tool]
    
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    
    // The view now observes the unified store for all its data.
    @StateObject private var toolStore = UnifiedToolStore.shared
    
    // REMOVED: @StateObject private var mcpManager = MCPManager()
    // The new V2 architecture handles connection state internally within the Add View
    // using the MCPClientService singleton.
    
    @State private var isPresentingAddView = false
    
    // NEW: State for editing an existing source
    @State private var sourceToEdit: ToolSource? = nil
    
    @State private var expandedToolIDs: Set<UUID> = []

    /// Filters the unified list of tool sources based on search text.
    var filteredSources: [ToolSource] {
        if searchText.isEmpty {
            return toolStore.sources
        } else {
            return toolStore.sources.filter { source in
                source.serverName.localizedCaseInsensitiveContains(searchText) ||
                source.tools.contains(where: {
                    $0.name.localizedCaseInsensitiveContains(searchText) || $0.description.localizedCaseInsensitiveContains(searchText)
                })
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            searchAndAddView
            toolListView
        }
        .frame(minWidth: 450, idealWidth: 500, minHeight: 450, idealHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isPresentingAddView) {
            // UPDATED: Now presenting the V2 Add View
            AddMCPServerView(
                // Adding a tool communicates directly with the MCP store.
                // The UnifiedToolStore will update automatically via Combine.
                onToolAdded: { serverName, serverDefinition, tools -> Bool in
                    if MCPToolStore.shared.sources.contains(where: { $0.serverName.caseInsensitiveCompare(serverName) == .orderedSame }) {
                        return false // Duplicate found
                    }
                    
                    MCPToolStore.shared.addTool(serverName: serverName, serverDefinition: serverDefinition, newTools: tools)
                    return true // Successfully added
                }
            )
        }
        // NEW: Sheet for editing an existing MCP Server
        .sheet(item: $sourceToEdit) { source in
            AddMCPServerView(
                existingSource: source,
                onToolUpdated: { id, serverName, serverDefinition, tools in
                    // Update the store
                    UnifiedToolStore.shared.updateTool(id: id, serverName: serverName, serverDefinition: serverDefinition, newTools: tools)
                    
                    // Disconnect any active session to force a reconnect with new settings on next use
                    Task {
                        await MCPClientService.shared.disconnect(sourceId: id)
                    }
                    
                    sourceToEdit = nil
                }
            )
        }
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack {
            Text("Tool Library")
                .font(.title2)
                .fontWeight(.semibold)
            
            Spacer()
            
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
        .background(.bar)
    }
    
    private var searchAndAddView: some View {
        HStack {
            TextField("Search Tools...", text: $searchText)
                .textFieldStyle(.roundedBorder)
            
            Button {
                isPresentingAddView = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .help("Add a new MCP Tool Server")
        }
        .padding()
    }
    
    @ViewBuilder
    private var toolListView: some View {
        if toolStore.sources.isEmpty {
            emptyStateView
        } else {
            List {
                ForEach(filteredSources) { source in
                    toolCardView(for: source)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
    
    private var emptyStateView: some View {
        VStack {
            Spacer()
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.largeTitle)
                .foregroundColor(.secondary)
                .padding(.bottom, 4)
            Text("No Tool Sources Found")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Click the '+' button to add an MCP tool server.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Creates an expandable card view for a single ToolSource.
    @ViewBuilder
    private func toolCardView(for source: ToolSource) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main card row
            HStack(spacing: 12) {
                // Differentiate local vs. MCP with an icon
                Image(systemName: source.type == .local ? "cpu.fill" : "network")
                    .foregroundColor(.secondary)
                
                Text(source.serverName)
                    .font(.headline)
                    .fontWeight(.medium)

                Spacer()

                Text("\(source.tools.count) Tools")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)

                // NEW: Select All / Deselect All Button
                let selectionState = getSelectionState(for: source)
                Button {
                    toggleSelection(for: source)
                } label: {
                    Image(systemName: selectionStateIcon(for: selectionState))
                        .foregroundColor(selectionState == .none ? .secondary : .blue)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .help(selectionState == .all ? "Deselect All" : "Select All")
                .padding(.leading, 4)

                // Expand/Collapse Button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expandedToolIDs.contains(source.id) {
                            expandedToolIDs.remove(source.id)
                        } else {
                            expandedToolIDs.insert(source.id)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(expandedToolIDs.contains(source.id) ? 90 : 0))
                }
                .buttonStyle(.plain)
                .frame(width: 20, height: 20)
            }
            .padding(.vertical, 8)

            // Expanded tool list with checkboxes
            if expandedToolIDs.contains(source.id) {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().padding(.bottom, 4)

                    ForEach(source.tools) { toolDef in
                        // Use a custom view for the row to handle the binding logic
                        ToolSelectionRowView(
                            toolDefinition: toolDef,
                            source: source, // Pass the entire source object
                            configuredTools: $configuredTools
                        )
                    }
                }
                .padding(.leading, 8)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 4)
        .contextMenu {
            // Actions are only allowed for MCP sources.
            if source.type == .mcp {
                // NEW: Edit Server Action
                Button {
                    sourceToEdit = source
                } label: {
                    Label("Edit Server", systemImage: "pencil")
                }
                
                Divider()
                
                Button(role: .destructive) {
                    toolStore.deleteTool(toolSource: source)
                } label: {
                    Label("Delete Server", systemImage: "trash")
                }
            }
        }
    }
    
    // MARK: - Selection Logic Helpers
    
    private enum SelectionState {
        case all, none, mixed
    }
    
    private func getSelectionState(for source: ToolSource) -> SelectionState {
        // Count how many tools from this specific source are currently configured/enabled
        let selectedCount = configuredTools.filter { tool in
            tool.sourceId == source.id && source.tools.contains { $0.name == tool.name }
        }.count
        
        if selectedCount == 0 {
            return .none
        } else if selectedCount == source.tools.count {
            return .all
        } else {
            return .mixed
        }
    }
    
    private func selectionStateIcon(for state: SelectionState) -> String {
        switch state {
        case .all: return "checkmark.circle.fill"
        case .mixed: return "minus.circle.fill"
        case .none: return "circle"
        }
    }
    
    private func toggleSelection(for source: ToolSource) {
        let state = getSelectionState(for: source)
        
        withAnimation {
            if state == .all {
                // Deselect All: Remove all tools belonging to this source
                configuredTools.removeAll { tool in
                    tool.sourceId == source.id && source.tools.contains { $0.name == tool.name }
                }
            } else {
                // Select All (or fill Mixed): Add any tools that aren't already selected
                for toolDef in source.tools {
                    let isAlreadySelected = configuredTools.contains {
                        $0.sourceId == source.id && $0.name == toolDef.name
                    }
                    
                    if !isAlreadySelected {
                        let newTool = Tool(
                            name: toolDef.name,
                            description: toolDef.description,
                            isEnabled: true,
                            sourceId: source.id,
                            parameters: toolDef.parameters
                        )
                        configuredTools.append(newTool)
                    }
                }
            }
        }
    }
}

/// A private view for a single row in the expanded tool list, handling selection logic.
private struct ToolSelectionRowView: View {
    /// The complete definition of the tool to display, including its parameter schema.
    let toolDefinition: ToolDefinition
    
    /// The source (e.g., "Built-in Tools", "Slack Server") that provides this tool.
    let source: ToolSource
    
    /// A binding to the agent's master list of configured tools, which this view will modify.
    @Binding var configuredTools: [Tool]

    /// A custom binding that manages the enabled/disabled state for this specific tool.
    /// It contains the logic to add or remove the tool from the agent's configuration.
    private var isEnabled: Binding<Bool> {
        Binding<Bool>(
            get: {
                // A tool is considered "enabled" if a tool with the same name and and from the
                // same source exists in the agent's configuration. This handles potential
                // duplicate tool names from different sources.
                configuredTools.contains { $0.name == toolDefinition.name && $0.sourceId == source.id }
            },
            set: { shouldBeEnabled in
                if shouldBeEnabled {
                    // If the toggle is turned ON, add the tool to the agent's configuration
                    // but only if it's not already there.
                    if !configuredTools.contains(where: { $0.name == toolDefinition.name && $0.sourceId == source.id }) {
                        // Create the persistent `Tool` model from the `ToolDefinition`.
                        // This is the critical step where the parameter schema is preserved.
                        let newTool = Tool(
                            name: toolDefinition.name,
                            description: toolDefinition.description,
                            isEnabled: true,
                            sourceId: source.id,
                            parameters: toolDefinition.parameters
                        )
                        configuredTools.append(newTool)
                    }
                } else {
                    // If the toggle is turned OFF, remove the tool from the agent's configuration.
                    configuredTools.removeAll { $0.name == toolDefinition.name && $0.sourceId == source.id }
                }
            }
        )
    }

    var body: some View {
        // The main UI for the row is a toggle switch.
        HStack(alignment: .top, spacing: 8) {
            // The Toggle uses our custom `isEnabled` binding to manage its state
            // and trigger the add/remove logic.
            Toggle(isOn: isEnabled) {
                // The label for the toggle displays the tool's name and description.
                VStack(alignment: .leading, spacing: 2) {
                    Text(toolDefinition.name)
                        .font(.subheadline)
                    
                    Text(toolDefinition.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            
            Spacer()
        }
    }
}

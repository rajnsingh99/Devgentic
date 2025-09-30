//
//  MCPLibraryView.swift
//  Devgentic
//
//  Created by Raj Singh on 25/09/25.
//

import SwiftUI

// MARK: - UNIFIED Data Models (STEP 1)

/// A generic representation of a single tool's definition, regardless of its source.
/// NOTE: In a real app, this struct would be in a shared Models file.
struct ToolDefinition: Identifiable, Hashable, Codable {
    var id: String { name }
    let name: String
    let description: String
}

/// An enum to differentiate between the origins of a tool source.
enum ToolSourceType: Hashable, Codable {
    case local
    case mcp
}


/// A unified, persistent structure representing a source of tools, which can be
/// the built-in local tools or a configured MCP server.
struct ToolSource: Identifiable, Hashable {
    let id: UUID
    let type: ToolSourceType
    let serverName: String // For local, this can be "Built-in Tools"
    let tools: [ToolDefinition]
    
    // This is optional because local tools don't have a server definition.
    let serverDefinition: ServerDefinition?
    
    var displayName: String {
        "\(serverName) (\(tools.map { $0.name }.joined(separator: ", ")))"
    }
}

/// A view for managing and selecting MCP (Model Context Protocol) tools.
struct MCPLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    
    // Note: This will be updated to a UnifiedToolStore in a later step.
    @StateObject private var toolStore = MCPToolStore.shared
    @StateObject private var mcpManager = MCPManager()
    @State private var isPresentingAddView = false
    @State private var expandedToolIDs: Set<UUID> = []
    @State private var selectedTools: [UUID: Set<String>] = [:]

    var filteredTools: [ToolSource] {
        if searchText.isEmpty {
            return toolStore.sources
        } else {
            return toolStore.sources.filter { item in
                item.serverName.localizedCaseInsensitiveContains(searchText) ||
                item.tools.contains(where: {
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
            AddMcpConnectionView(
                manager: mcpManager,
                // The onToolAdded closure now provides ToolDefinition
                onToolAdded: { serverName, serverDefinition, tools -> Bool in
                    if self.toolStore.sources.contains(where: { $0.serverName.caseInsensitiveCompare(serverName) == .orderedSame }) {
                        return false // Duplicate found
                    }
                    
                    self.toolStore.addTool(serverName: serverName, serverDefinition: serverDefinition, newTools: tools)
                    return true // Successfully added
                }
            )
        }
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack {
            Text("MCP Tool Library")
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
            TextField("Search MCP Tools...", text: $searchText)
                .textFieldStyle(.roundedBorder)
            
            Button {
                isPresentingAddView = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .help("Add a new MCP Tool")
        }
        .padding()
    }
    
    @ViewBuilder
    private var toolListView: some View {
        if toolStore.sources.isEmpty {
            emptyStateView
        } else {
            List {
                ForEach(filteredTools) { tool in
                    toolCardView(for: tool)
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
            Text("No MCP Tools Added")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Click the '+' button to add a new tool.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Creates an expandable card view for a single ToolSource.
    @ViewBuilder
    private func toolCardView(for tool: ToolSource) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main card row
            HStack(spacing: 12) {
                Text(tool.serverName)
                    .font(.headline)
                    .fontWeight(.medium)

                Spacer()

                Text("\(tool.tools.count) Tools")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)

                // Expand/Collapse Button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expandedToolIDs.contains(tool.id) {
                            expandedToolIDs.remove(tool.id)
                        } else {
                            expandedToolIDs.insert(tool.id)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(expandedToolIDs.contains(tool.id) ? 90 : 0))
                }
                .buttonStyle(.plain)
                .frame(width: 20, height: 20)
            }
            .padding(.vertical, 8)

            // Expanded tool list with checkboxes
            if expandedToolIDs.contains(tool.id) {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().padding(.bottom, 4)

                    ForEach(tool.tools) { toolInfo in
                        HStack(alignment: .top, spacing: 8) {
                            // Checkbox button
                            Button {
                                toggleSelection(for: toolInfo.name, in: tool)
                            } label: {
                                Image(systemName: isSelected(toolName: toolInfo.name, in: tool) ? "checkmark.square.fill" : "square")
                                    .font(.body)
                                    .foregroundColor(isSelected(toolName: toolInfo.name, in: tool) ? .accentColor : .secondary)
                            }
                            .buttonStyle(.plain)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(toolInfo.name)
                                    .font(.subheadline)
                                
                                Text(toolInfo.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                        }
                    }
                }
                .padding(.leading, 8)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 4)
        .contextMenu {
            // Do not allow deleting the local tool source
            if tool.type == .mcp {
                Button(role: .destructive) {
                    toolStore.deleteTool(toolSource: tool)
                } label: {
                    Label("Delete Tool", systemImage: "trash")
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    /// Toggles the selection state for a specific tool within a tool source.
    private func toggleSelection(for toolName: String, in tool: ToolSource) {
        var selections = selectedTools[tool.id, default: Set()]
        if selections.contains(toolName) {
            selections.remove(toolName)
        } else {
            selections.insert(toolName)
        }
        selectedTools[tool.id] = selections
    }

    /// Checks if a specific tool is currently selected.
    private func isSelected(toolName: String, in tool: ToolSource) -> Bool {
        selectedTools[tool.id]?.contains(toolName) ?? false
    }
}

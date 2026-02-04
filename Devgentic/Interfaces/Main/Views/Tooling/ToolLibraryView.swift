//
//  ToolLibraryView.swift
//  Devgentic
//
//  Created by Raj Singh on 25/09/25.
//
//  Refactored on 28/09/25 to unify Local and MCP tool management.
//  Updated on 26/01/26 to integrate the V2 MCP Architecture.
//  Updated on 04/02/26 for Modern Dashboard UI.
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
    
    @State private var isPresentingAddView = false
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
            // 1. Header & Search
            headerView
            
            // 2. Scrollable Content
            ScrollView {
                VStack(spacing: 16) {
                    if toolStore.sources.isEmpty {
                        emptyStateView
                    } else if filteredSources.isEmpty {
                        noSearchResultsView
                    } else {
                        ForEach(filteredSources) { source in
                            ToolSourceCard(
                                source: source,
                                isExpanded: expandedToolIDs.contains(source.id),
                                configuredTools: $configuredTools,
                                onExpandToggle: { toggleExpansion(for: source.id) },
                                onEdit: { sourceToEdit = source },
                                onDelete: { toolStore.deleteTool(toolSource: source) }
                            )
                        }
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 500, idealWidth: 600, minHeight: 500, idealHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isPresentingAddView) {
            AddMCPServerView(
                onToolAdded: { serverName, serverDefinition, tools -> Bool in
                    if MCPToolStore.shared.sources.contains(where: { $0.serverName.caseInsensitiveCompare(serverName) == .orderedSame }) {
                        return false
                    }
                    MCPToolStore.shared.addTool(serverName: serverName, serverDefinition: serverDefinition, newTools: tools)
                    return true
                }
            )
        }
        .sheet(item: $sourceToEdit) { source in
            AddMCPServerView(
                existingSource: source,
                onToolUpdated: { id, serverName, serverDefinition, tools in
                    UnifiedToolStore.shared.updateTool(id: id, serverName: serverName, serverDefinition: serverDefinition, newTools: tools)
                    Task { await MCPClientService.shared.disconnect(sourceId: id) }
                    sourceToEdit = nil
                }
            )
        }
    }
    
    // MARK: - Logic Helpers
    
    private func toggleExpansion(for id: UUID) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            if expandedToolIDs.contains(id) {
                expandedToolIDs.remove(id)
            } else {
                expandedToolIDs.insert(id)
            }
        }
    }

    // MARK: - Top Level Views

    private var headerView: some View {
        VStack(spacing: 16) {
            // Title Bar
            HStack {
                VStack(alignment: .leading) {
                    Text("Tool Library")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Manage capabilities and MCP integrations")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            
            // Search Bar
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search tools or servers...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.body)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                
                Button {
                    isPresentingAddView = true
                } label: {
                    Label("Add MCP Server", systemImage: "server.rack")
                }
                .buttonStyle(.borderedProminent)
                .help("Connect a new Model Context Protocol server")
            }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.secondary.opacity(0.1)), alignment: .bottom)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            VStack(spacing: 4) {
                Text("No Tools Available")
                    .font(.headline)
                    .foregroundColor(.primary)
                Text("Get started by adding an MCP server.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Button("Add First Server") { isPresentingAddView = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Spacer()
        }
        .frame(minHeight: 300)
    }
    
    private var noSearchResultsView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("No matching tools found")
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(minHeight: 200)
    }
}

// MARK: - Component: Tool Source Card

struct ToolSourceCard: View {
    let source: ToolSource
    let isExpanded: Bool
    @Binding var configuredTools: [Tool]
    var onExpandToggle: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    
    // Computed Selection State
    private var selectionState: SelectionState {
        let selectedCount = configuredTools.filter { tool in
            tool.sourceId == source.id && source.tools.contains { $0.name == tool.name }
        }.count
        
        if selectedCount == 0 { return .none }
        if selectedCount == source.tools.count { return .all }
        return .mixed
    }
    
    enum SelectionState { case all, none, mixed }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card Header
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(source.type == .local ? Color.blue.opacity(0.1) : Color.purple.opacity(0.1))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: source.type == .local ? "macpro.gen3.fill" : "network")
                        .foregroundColor(source.type == .local ? .blue : .purple)
                        .font(.system(size: 16))
                }
                
                // Title
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.serverName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    HStack(spacing: 6) {
                        Text(source.type == .local ? "Built-in" : "MCP Server")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                        
                        Text("• \(source.tools.count) tools")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Actions
                HStack(spacing: 12) {
                    // Select All Toggle
                    Button {
                        toggleSelection()
                    } label: {
                        Image(systemName: selectionIcon)
                            .font(.title3)
                            .foregroundColor(selectionState == .none ? .secondary.opacity(0.5) : .blue)
                    }
                    .buttonStyle(.plain)
                    .help(selectionState == .all ? "Deselect All" : "Select All")
                    
                    // MCP-Only Actions
                    if source.type == .mcp {
                        Menu {
                            Button(action: onEdit) {
                                Label("Edit Configuration", systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive, action: onDelete) {
                                Label("Remove Server", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden) // <--- FIX: Hides the merged arrow
                        .foregroundColor(.secondary)
                    }
                    
                    // Expansion Chevron (Explicit)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.7))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .contentShape(Rectangle())
            .onTapGesture {
                onExpandToggle()
            }
            
            // Expanded List
            if isExpanded {
                Divider()
                
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(source.tools) { toolDef in
                        ToolRow(
                            toolDef: toolDef,
                            source: source,
                            configuredTools: $configuredTools
                        )
                        
                        if toolDef.id != source.tools.last?.id {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }
        }
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.02), radius: 2, x: 0, y: 1)
    }
    
    // Helpers
    private var selectionIcon: String {
        switch selectionState {
        case .all: return "checkmark.circle.fill"
        case .mixed: return "minus.circle.fill"
        case .none: return "circle"
        }
    }
    
    private func toggleSelection() {
        withAnimation {
            if selectionState == .all {
                // Deselect All
                configuredTools.removeAll { tool in
                    tool.sourceId == source.id && source.tools.contains { $0.name == tool.name }
                }
            } else {
                // Select All
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

// MARK: - Component: Individual Tool Row

struct ToolRow: View {
    let toolDef: ToolDefinition
    let source: ToolSource
    @Binding var configuredTools: [Tool]
    
    private var isEnabled: Binding<Bool> {
        Binding<Bool>(
            get: {
                configuredTools.contains { $0.name == toolDef.name && $0.sourceId == source.id }
            },
            set: { shouldEnable in
                if shouldEnable {
                    if !configuredTools.contains(where: { $0.name == toolDef.name && $0.sourceId == source.id }) {
                        let newTool = Tool(
                            name: toolDef.name,
                            description: toolDef.description,
                            isEnabled: true,
                            sourceId: source.id,
                            parameters: toolDef.parameters
                        )
                        configuredTools.append(newTool)
                    }
                } else {
                    configuredTools.removeAll { $0.name == toolDef.name && $0.sourceId == source.id }
                }
            }
        )
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(toolDef.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Text(toolDef.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture {
            isEnabled.wrappedValue.toggle()
        }
    }
}

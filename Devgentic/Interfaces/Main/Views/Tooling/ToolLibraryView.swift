//
//  ToolLibraryView.swift
//  Devgentic
//
//  Created by Raj Singh on 25/09/25.
//
//  Refactored on 28/09/25 to unify Local and MCP tool management.
//  Updated on 26/01/26 to integrate the V2 MCP Architecture.
//  Updated on 04/02/26 for Modern Dashboard UI.
//  Redesigned on 20/02/26 for Phase 4: Master-Detail Architecture & HITL controls.
//  Polished on 20/02/26 to modernize UI alignments, typography, and macOS standards.
//

import SwiftUI

// MARK: - Navigation State

enum SidebarSelection: Hashable {
    case all
    case local
    case mcp(UUID)
}

struct ToolTableRow: Identifiable {
    var id: String { "\(source.id)-\(definition.name)" }
    let source: ToolSource
    let definition: ToolDefinition
}

// MARK: - Main View

/// A modern, macOS-native view for managing tools and MCP servers using a NavigationSplitView.
struct ToolLibraryView: View {
    // A binding to the agent's currently configured tools.
    @Binding var configuredTools: [Tool]
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var toolStore = UnifiedToolStore.shared
    
    // UI State
    @State private var selectedSidebar: SidebarSelection? = .all
    @State private var searchText = ""
    @State private var isPresentingAddView = false
    @State private var sourceToEdit: ToolSource? = nil

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            detailView
        }
        .frame(minWidth: 900, idealWidth: 1000, minHeight: 600, idealHeight: 700)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search tools...")
        // Sheets
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
    
    // MARK: - Sidebar View
    
    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selectedSidebar) {
            
            Section("Library") {
                Label("All Tools", systemImage: "archivebox.fill")
                    .tag(SidebarSelection.all)
            }
            
            Section("Environment") {
                Label("Built-in Tools", systemImage: "cpu")
                    .tag(SidebarSelection.local)
            }
            
            Section("MCP Servers") {
                let mcpSources = toolStore.sources.filter { $0.type == .mcp }
                
                if mcpSources.isEmpty {
                    Text("No connected servers")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(mcpSources) { source in
                        Label(source.serverName, systemImage: "network")
                            .tag(SidebarSelection.mcp(source.id))
                            .contextMenu {
                                Button("Edit Configuration...") {
                                    sourceToEdit = source
                                }
                                Divider()
                                Button("Remove Server", role: .destructive) {
                                    toolStore.deleteTool(toolSource: source)
                                    if selectedSidebar == .mcp(source.id) {
                                        selectedSidebar = .all
                                    }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Tool Library")
    }
    
    // MARK: - Detail (Table) View
    
    @ViewBuilder
    private var detailView: some View {
        VStack(spacing: 0) {
            if displayedRows.isEmpty {
                emptyStateView
            } else {
                Table(displayedRows) {
                    // 1. Tool Identity Column
                    TableColumn("Tool") { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.definition.name)
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            
                            // Show source context if viewing "All Tools"
                            if selectedSidebar == .all {
                                Text(row.source.serverName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    .width(min: 200, ideal: 240, max: 320)
                    
                    // 2. Description Column
                    TableColumn("Description") { row in
                        Text(row.definition.description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                            .padding(.vertical, 10)
                    }
                    
                    // 3. Status Column (Active/Inactive)
                    TableColumn("Enabled") { row in
                        ToolStatusToggle(
                            configuredTools: $configuredTools,
                            source: row.source,
                            definition: row.definition
                        )
                        .padding(.vertical, 10)
                    }
                    .width(70)
                    
                    // 4. Security Column (HITL Approval)
                    TableColumn("Require Approval") { row in
                        ToolSecurityToggle(
                            configuredTools: $configuredTools,
                            source: row.source,
                            definition: row.definition
                        )
                        .padding(.vertical, 10)
                    }
                    .width(140)
                }
                .padding(.top, 12) // Ensures the Table headers don't overlap with the search field/toolbar area
            }
            
            // Bottom Action Bar
            Divider()
            HStack(spacing: 12) {
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction) // Allows hitting 'Esc' to close
                .controlSize(.large)
                
                Button {
                    isPresentingAddView = true
                } label: {
                    Label("Add MCP Server", systemImage: "plus")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Connect a new Model Context Protocol server")
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle(detailTitle)
    }
    
    // MARK: - Computed Properties & Helpers
    
    private var detailTitle: String {
        switch selectedSidebar {
        case .all: return "All Tools"
        case .local: return "Built-in Tools"
        case .mcp(let id): return toolStore.sources.first(where: { $0.id == id })?.serverName ?? "MCP Server"
        case .none: return "Select a category"
        }
    }
    
    /// Flattens the hierarchical data into a searchable array of rows for the Table.
    private var displayedRows: [ToolTableRow] {
        var rows: [ToolTableRow] = []
        let sourcesToProcess: [ToolSource]
        
        switch selectedSidebar {
        case .all:
            sourcesToProcess = toolStore.sources
        case .local:
            sourcesToProcess = toolStore.sources.filter { $0.type == .local }
        case .mcp(let id):
            sourcesToProcess = toolStore.sources.filter { $0.id == id }
        case .none:
            sourcesToProcess = []
        }
        
        for source in sourcesToProcess {
            for tool in source.tools {
                if searchText.isEmpty ||
                   tool.name.localizedCaseInsensitiveContains(searchText) ||
                   tool.description.localizedCaseInsensitiveContains(searchText) {
                    rows.append(ToolTableRow(source: source, definition: tool))
                }
            }
        }
        
        // Sort alphabetically by tool name
        return rows.sorted { $0.definition.name < $1.definition.name }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: searchText.isEmpty ? "puzzlepiece.extension" : "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text(searchText.isEmpty ? "No Tools Found" : "No Matches for '\(searchText)'")
                .font(.headline)
            
            if searchText.isEmpty && selectedSidebar != .local {
                Button("Add MCP Server") { isPresentingAddView = true }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Row Action Components

/// Manages the activation state of a tool (adding/removing from configuredTools).
private struct ToolStatusToggle: View {
    @Binding var configuredTools: [Tool]
    let source: ToolSource
    let definition: ToolDefinition
    
    var isEnabled: Binding<Bool> {
        Binding(
            get: {
                configuredTools.contains { $0.name == definition.name && $0.sourceId == source.id }
            },
            set: { newValue in
                if newValue {
                    // Enable: Create the Tool and append it
                    if !configuredTools.contains(where: { $0.name == definition.name && $0.sourceId == source.id }) {
                        let newTool = Tool(
                            name: definition.name,
                            description: definition.description,
                            isEnabled: true,
                            requiresConfirmation: definition.requiresConfirmation, // Inherit default
                            sourceId: source.id,
                            parameters: definition.parameters
                        )
                        configuredTools.append(newTool)
                    }
                } else {
                    // Disable: Remove from the active array
                    configuredTools.removeAll { $0.name == definition.name && $0.sourceId == source.id }
                }
            }
        )
    }
    
    var body: some View {
        Toggle("Enable \(definition.name)", isOn: isEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small) // Modernized from .regular to .small
    }
}

/// Manages the HITL security preference (requiresConfirmation) for an active tool.
private struct ToolSecurityToggle: View {
    @Binding var configuredTools: [Tool]
    let source: ToolSource
    let definition: ToolDefinition
    
    var isConfigured: Bool {
        configuredTools.contains { $0.name == definition.name && $0.sourceId == source.id }
    }
    
    var requiresConfirmation: Binding<Bool> {
        Binding(
            get: {
                // If it's configured, read the user's saved preference.
                if let existing = configuredTools.first(where: { $0.name == definition.name && $0.sourceId == source.id }) {
                    return existing.requiresConfirmation
                }
                // Otherwise, show what the default *will* be when enabled.
                return definition.requiresConfirmation
            },
            set: { newValue in
                // Only mutate if the tool is actually enabled/configured.
                if let index = configuredTools.firstIndex(where: { $0.name == definition.name && $0.sourceId == source.id }) {
                    configuredTools[index].requiresConfirmation = newValue
                }
            }
        )
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Toggle("Require Approval", isOn: requiresConfirmation)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small) // Modernized from .regular to .small
                .disabled(!isConfigured) // Lock the security control if the tool is disabled
            
            // Visual Indicator (Fixed width ensures toggles align perfectly)
            Image(systemName: requiresConfirmation.wrappedValue ? "lock.shield.fill" : "shield.slash")
                .foregroundColor(requiresConfirmation.wrappedValue ? (isConfigured ? .orange : .secondary) : .secondary.opacity(0.3))
                .font(.system(size: 14, weight: .medium)) // Slightly reduced font size to match small toggle
                .frame(width: 20, alignment: .center)
                .help(isConfigured
                      ? (requiresConfirmation.wrappedValue ? "Suspends execution for user approval." : "Runs automatically.")
                      : "Enable tool to configure security.")
        }
    }
}

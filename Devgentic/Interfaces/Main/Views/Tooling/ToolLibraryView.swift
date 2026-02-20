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
//  Updated on 20/02/26 for Step 3: Dependency Protection via Instructions matching.
//  Updated on 20/02/26: Added native Hover Tooltips and Detailed Parameter Popovers.
//  Updated on 21/02/26: Replaced scroll-glitch toggles with semantic pill buttons, unified popover scroll.
//  Updated on 21/02/26: Switched State button to icon-only for cleaner UI, fixed vertical alignment across columns.
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
    let instructions: String
    
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
                    
                    // 2. Description Column (Vertically Centered to match state toggles)
                    TableColumn("Description") { row in
                        HStack(alignment: .center) { // CHANGED: from .top to .center for perfect row alignment
                            Text(row.definition.description)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                                .help(row.definition.description) // Native Hover Tooltip
                            
                            Spacer(minLength: 8)
                            
                            // Clickable Info Popover for Parameters
                            ToolDetailsButton(definition: row.definition)
                        }
                        .padding(.vertical, 10)
                    }
                    
                    // 3. Status Column (Active/Inactive)
                    TableColumn("State") { row in
                        ToolStatusToggle(
                            configuredTools: $configuredTools,
                            source: row.source,
                            definition: row.definition,
                            instructions: instructions
                        )
                        .padding(.vertical, 10)
                    }
                    .width(60) // Reduced width since it's just an icon now
                    
                    // 4. Security Column (HITL Approval)
                    TableColumn("Approval") { row in
                        ToolSecurityToggle(
                            configuredTools: $configuredTools,
                            source: row.source,
                            definition: row.definition
                        )
                        .padding(.vertical, 10)
                    }
                    .width(80)
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

/// A small button that triggers a popover showing the full description and parameter schema.
private struct ToolDetailsButton: View {
    let definition: ToolDefinition
    @State private var isShowingPopover = false
    
    var body: some View {
        Button {
            isShowingPopover.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("View full tool details & parameters")
        .popover(isPresented: $isShowingPopover, arrowEdge: .trailing) {
            // Master ScrollView ensures long descriptions AND params scroll seamlessly together
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    HStack {
                        Image(systemName: "wrench.fill")
                            .foregroundColor(.accentColor)
                        Text(definition.name)
                            .font(.headline)
                            .fontDesign(.monospaced)
                    }
                    
                    // Full Description (Unrestricted Height)
                    Text(definition.description)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Divider()
                    
                    // Parameters Section
                    Text("Parameters Schema")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    if definition.parameters.properties.isEmpty {
                        Text("No parameters required.")
                            .font(.caption)
                            .italic()
                            .foregroundColor(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(definition.parameters.properties.keys.sorted()), id: \.self) { key in
                                let prop = definition.parameters.properties[key]!
                                let isRequired = definition.parameters.required.contains(key)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(key)
                                            .font(.system(.caption, design: .monospaced))
                                            .fontWeight(.bold)
                                        Text(prop.type)
                                            .font(.caption2)
                                            .foregroundColor(.blue)
                                        
                                        if isRequired {
                                            Text("Required")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(.red)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 2)
                                                .background(Color.red.opacity(0.1))
                                                .cornerRadius(4)
                                        }
                                    }
                                    
                                    if let desc = prop.description {
                                        Text(desc)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                                .cornerRadius(6)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.1), lineWidth: 1))
                            }
                        }
                    }
                }
                .padding()
            }
            .frame(width: 350)
            .frame(maxHeight: 500) // Provides a ceiling so it scrolls gracefully if content is huge
        }
    }
}


/// Manages the activation state of a tool using a semantic pill button to prevent table scroll-glitch.
private struct ToolStatusToggle: View {
    @Binding var configuredTools: [Tool]
    let source: ToolSource
    let definition: ToolDefinition
    let instructions: String
    
    @State private var showingDependencyAlert = false
    
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
                    // Disable: Check dependency
                    if instructions.contains("`\(definition.name)`") {
                        // Block disable and show alert
                        DispatchQueue.main.async {
                            showingDependencyAlert = true
                        }
                    } else {
                        // Safe to disable: Remove from the active array
                        configuredTools.removeAll { $0.name == definition.name && $0.sourceId == source.id }
                    }
                }
            }
        )
    }
    
    var body: some View {
        Button {
            isEnabled.wrappedValue.toggle()
        } label: {
            Image(systemName: isEnabled.wrappedValue ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 16, alignment: .center)
//            Image(systemName: "power")
//                .font(.system(size: 12, weight: .bold))
//                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isEnabled.wrappedValue ? Color.accentColor : Color.secondary.opacity(0.15))
        .foregroundColor(isEnabled.wrappedValue ? .white : .primary)
        .cornerRadius(6)
        .help(isEnabled.wrappedValue ? "Tool is ON. Click to disable." : "Tool is OFF. Click to enable.")
        .alert("Tool in Use", isPresented: $showingDependencyAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Cannot disable '\(definition.name)'. It is currently referenced in the System Instructions. Please remove it from the instructions first.")
        }
    }
}

/// Manages the HITL security preference using a semantic pill button.
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
                if let existing = configuredTools.first(where: { $0.name == definition.name && $0.sourceId == source.id }) {
                    return existing.requiresConfirmation
                }
                return definition.requiresConfirmation
            },
            set: { newValue in
                if let index = configuredTools.firstIndex(where: { $0.name == definition.name && $0.sourceId == source.id }) {
                    configuredTools[index].requiresConfirmation = newValue
                }
            }
        )
    }
    
    var body: some View {
        Button {
            if isConfigured {
                requiresConfirmation.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: requiresConfirmation.wrappedValue ? "lock.shield.fill" : "bolt.fill")
                    .font(.system(size: 10))
                Text(requiresConfirmation.wrappedValue ? "Ask" : "Auto")
                    .font(.system(size: 11, weight: .semibold))
            }
            .frame(width: 50, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            !isConfigured ? Color.secondary.opacity(0.05) :
            (requiresConfirmation.wrappedValue ? Color.orange : Color.green)
        )
        .foregroundColor(
            !isConfigured ? .secondary.opacity(0.3) : .white
        )
        .cornerRadius(6)
        .disabled(!isConfigured)
        .help(!isConfigured ? "Enable tool first to configure security." :
              (requiresConfirmation.wrappedValue ? "Ask Before Run: Suspends execution for your approval before running." : "Auto-Run: Tool executes automatically without asking."))
    }
}

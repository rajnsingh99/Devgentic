//
//  ToolLibraryView.swift
//  Devgentic
//
//  Created by Raj Singh on 25/09/25.
//
//  Redesigned on 19/03/26 for single-window stack navigation.
//  Uses a custom split layout with themed sidebar + scrollable
//  tool rows instead of NavigationSplitView + Table.
//

import SwiftUI

// MARK: - Navigation State

enum SidebarSelection: Hashable {
    case all
    case localCategory(String)
    case mcp(UUID)
}

// MARK: - Built-in Tool Category Mapping

struct BuiltInToolCategory: Identifiable {
    var id: String { name }
    let name: String
    let icon: String
    let rawCategories: Set<String>

    static let allGroups: [BuiltInToolCategory] = [
        .init(name: "File System", icon: "folder.fill", rawCategories: ["File System", "Advanced Finder & File Management"]),
        .init(name: "System & Shell", icon: "terminal.fill", rawCategories: ["System & Shell", "System Toggles", "System State", "System Automation", "Device & Peripheral Control"]),
        .init(name: "Coding & Dev Tools", icon: "chevron.left.forwardslash.chevron.right", rawCategories: ["Coding Assistant", "Developer & Diagnostics"]),
        .init(name: "Vision & UI", icon: "eye.fill", rawCategories: ["Vision & UI", "Workspace Management", "Deep Context Awareness"]),
        .init(name: "macOS Utilities", icon: "gearshape.fill", rawCategories: ["macOS Utilities"]),
        .init(name: "Network & Web", icon: "globe", rawCategories: ["Network & Connectivity", "Native Browser Automation"]),
        .init(name: "Communication & PIM", icon: "person.crop.rectangle.stack.fill", rawCategories: ["Personal Information", "Communication & Mail"]),
        .init(name: "Audio & Media", icon: "speaker.wave.2.fill", rawCategories: ["Audio & Media"]),
    ]

    static func groupName(for rawCategory: String) -> String? {
        allGroups.first { $0.rawCategories.contains(rawCategory) }?.name
    }
}

struct ToolTableRow: Identifiable {
    var id: String { "\(source.id)-\(definition.name)" }
    let source: ToolSource
    let definition: ToolDefinition
}

// MARK: - Main View

struct ToolLibraryView: View {
    @Binding var configuredTools: [Tool]
    let instructions: String
    @Binding var searchText: String
    @Binding var selectedSidebar: SidebarSelection?

    @EnvironmentObject private var router: MainViewRouter
    @StateObject private var toolStore = UnifiedToolStore.shared
    @Environment(\.appTheme) private var theme

    // Sheet state
    @State private var isPresentingAddView = false
    @State private var sourceToEdit: ToolSource? = nil

    var body: some View {
        HStack(spacing: 0) {
            // LEFT: Category sidebar
            toolSidebar
                .frame(width: 220)

            // Separator
            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(width: 1)

            // RIGHT: Tool list
            toolDetailView
        }
        .frame(maxWidth: 1000)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
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

    // MARK: - Sidebar

    @ViewBuilder
    private var toolSidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedSidebar) {
                Section {
                    sidebarRow(
                        label: "All Tools",
                        icon: "archivebox.fill",
                        count: totalToolCount,
                        tag: .all
                    )
                } header: {
                    Text("Library")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }

                Section {
                    ForEach(builtInGroups, id: \.name) { group in
                        sidebarRow(
                            label: group.name,
                            icon: group.icon,
                            count: group.count,
                            tag: .localCategory(group.name)
                        )
                    }
                } header: {
                    Text("Built-in Tools")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }

                Section {
                    let mcpSources = toolStore.sources.filter { $0.type == .mcp }

                    if mcpSources.isEmpty {
                        VStack(spacing: 4) {
                            Text("No MCP servers")
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                            Button("Add Server") { isPresentingAddView = true }
                                .font(.caption2)
                                .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(mcpSources) { source in
                            HStack(spacing: 6) {
                                MCPIconView(
                                    icons: source.tools.first?.icons,
                                    fallbackSymbol: "network",
                                    size: 16
                                )
                                .foregroundColor(theme.secondaryText)

                                Text(source.serverName)
                                    .font(.system(size: 13))
                                    .foregroundColor(theme.primaryText)

                                Spacer()

                                Text("\(source.tools.count)")
                                    .font(.caption2)
                                    .foregroundColor(theme.secondaryText)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(theme.surfaceOverlay)
                                    .cornerRadius(8)

                                ConnectionStateIndicator(sourceId: source.id)
                            }
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
                } header: {
                    Text("MCP Servers")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
            }
            .listStyle(.sidebar)
        }
        .background(theme.secondaryBackground.opacity(0.5))
    }

    private func sidebarRow(label: String, icon: String, count: Int, tag: SidebarSelection) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(.system(size: 13))
                .foregroundColor(theme.primaryText)
            Spacer()
            Text("\(count)")
                .font(.caption2)
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(theme.surfaceOverlay)
                .cornerRadius(8)
        }
        .tag(tag)
    }

    // MARK: - Detail (Tool List)

    @ViewBuilder
    private var toolDetailView: some View {
        if displayedRows.isEmpty {
            emptyStateView
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Column header
                    HStack(spacing: 0) {
                        Text("Tool")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Description")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("State")
                            .frame(width: 80, alignment: .center)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(theme.surfaceOverlay.opacity(0.3))

                    ForEach(displayedRows) { row in
                        toolRow(row)

                        if row.id != displayedRows.last?.id {
                            Divider()
                                .padding(.leading, 56)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }

    private func toolRow(_ row: ToolTableRow) -> some View {
        HStack(spacing: 12) {
            // Icon
            MCPIconView(
                icons: row.definition.icons,
                fallbackSymbol: row.source.type == .local ? "cpu" : "wrench.fill",
                size: 24
            )
            .foregroundColor(theme.accentColor)
            .frame(width: 28)

            // Name + source
            VStack(alignment: .leading, spacing: 2) {
                if let title = row.definition.title {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text(row.definition.name)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                } else {
                    Text(row.definition.name)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                }

                ToolAnnotationBadges(annotations: row.definition.annotations)

                if selectedSidebar == .all {
                    Text(row.source.serverName)
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Description + info
            HStack(alignment: .center, spacing: 8) {
                Text(row.definition.description)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)

                Spacer(minLength: 4)

                ToolDetailsButton(definition: row.definition)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // State control
            ToolStateControl(
                configuredTools: $configuredTools,
                source: row.source,
                definition: row.definition,
                instructions: instructions
            )
            .frame(width: 80, alignment: .center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - Computed Properties

    var totalToolCount: Int {
        toolStore.sources.reduce(0) { $0 + $1.tools.count }
    }

    /// Groups built-in tools by sidebar category with counts.
    var builtInGroups: [(name: String, icon: String, count: Int)] {
        let localTools = toolStore.sources.filter { $0.type == .local }.flatMap { $0.tools }
        return BuiltInToolCategory.allGroups.compactMap { group in
            let count = localTools.filter { group.rawCategories.contains($0.category) }.count
            guard count > 0 else { return nil }
            return (name: group.name, icon: group.icon, count: count)
        }
    }

    private var isLocalCategorySelected: Bool {
        if case .localCategory = selectedSidebar { return true }
        return false
    }

    var displayedRows: [ToolTableRow] {
        var rows: [ToolTableRow] = []

        switch selectedSidebar {
        case .all:
            for source in toolStore.sources {
                for tool in source.tools {
                    if matchesSearch(tool) {
                        rows.append(ToolTableRow(source: source, definition: tool))
                    }
                }
            }
        case .localCategory(let groupName):
            guard let group = BuiltInToolCategory.allGroups.first(where: { $0.name == groupName }) else { break }
            for source in toolStore.sources where source.type == .local {
                for tool in source.tools where group.rawCategories.contains(tool.category) {
                    if matchesSearch(tool) {
                        rows.append(ToolTableRow(source: source, definition: tool))
                    }
                }
            }
        case .mcp(let id):
            for source in toolStore.sources where source.id == id {
                for tool in source.tools {
                    if matchesSearch(tool) {
                        rows.append(ToolTableRow(source: source, definition: tool))
                    }
                }
            }
        case .none:
            break
        }

        return rows.sorted { $0.definition.name < $1.definition.name }
    }

    private func matchesSearch(_ tool: ToolDefinition) -> Bool {
        searchText.isEmpty ||
        tool.name.localizedCaseInsensitiveContains(searchText) ||
        tool.description.localizedCaseInsensitiveContains(searchText)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: searchText.isEmpty ? "puzzlepiece.extension" : "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(theme.secondaryText.opacity(0.4))

            Text(searchText.isEmpty ? "No Tools Found" : "No Matches for '\(searchText)'")
                .font(.headline)
                .foregroundColor(theme.secondaryText)

            if searchText.isEmpty && !isLocalCategorySelected {
                Button("Add MCP Server") { isPresentingAddView = true }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row Action Components

/// A small button that triggers a popover showing the full description and parameter schema.
private struct ToolDetailsButton: View {
    let definition: ToolDefinition
    @State private var isShowingPopover = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button {
            isShowingPopover.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundColor(theme.secondaryText)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("View full tool details & parameters")
        .popover(isPresented: $isShowingPopover, arrowEdge: .trailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    HStack {
                        MCPIconView(icons: definition.icons, fallbackSymbol: "wrench.fill", size: 20)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            if let title = definition.title {
                                Text(title).font(.headline)
                                Text(definition.name)
                                    .font(.caption)
                                    .fontDesign(.monospaced)
                                    .foregroundColor(.secondary)
                            } else {
                                Text(definition.name)
                                    .font(.headline)
                                    .fontDesign(.monospaced)
                            }
                        }
                    }

                    // Full Description
                    Text(definition.description)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    // Behavior Hints
                    if definition.annotations != nil {
                        Divider()
                        Text("Behavior Hints")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        ToolAnnotationBadges(annotations: definition.annotations)
                    }

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
            .frame(maxHeight: 500)
        }
    }
}


/// A unified 3-state control for managing tool activation and HITL approval.
/// States: Disabled -> Ask (Orange Lock) -> Auto (Green Bolt) -> Disabled
fileprivate struct ToolStateControl: View {
    @Binding var configuredTools: [Tool]
    let source: ToolSource
    let definition: ToolDefinition
    let instructions: String

    @State private var showingDependencyAlert = false

    private enum ToolControlState {
        case disabled
        case ask
        case auto
    }

    private var currentState: ToolControlState {
        if let tool = configuredTools.first(where: { $0.name == definition.name && $0.sourceId == source.id }) {
            return tool.requiresConfirmation ? .ask : .auto
        }
        return .disabled
    }

    var body: some View {
        Button {
            cycleState()
        } label: {
            HStack(spacing: 4) {
                stateIcon
                    .font(.system(size: 11, weight: .bold))
                if currentState != .disabled {
                    Text(stateLabel)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .frame(width: currentState == .disabled ? 28 : 54, height: 16, alignment: .center)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(stateBackground)
        .foregroundColor(stateForeground)
        .cornerRadius(6)
        .help(helpText)
        .alert("Tool in Use", isPresented: $showingDependencyAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Cannot disable '\(definition.name)'. It is currently referenced in the System Instructions. Please remove it from the instructions first.")
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch currentState {
        case .disabled:
            Image(systemName: "circle.dashed")
        case .ask:
            Image(systemName: "lock.shield.fill")
        case .auto:
            Image(systemName: "bolt.fill")
        }
    }

    private var stateLabel: String {
        switch currentState {
        case .disabled: return ""
        case .ask: return "Ask"
        case .auto: return "Auto"
        }
    }

    private var stateBackground: Color {
        switch currentState {
        case .disabled: return Color.secondary.opacity(0.15)
        case .ask: return Color.orange
        case .auto: return Color.green
        }
    }

    private var stateForeground: Color {
        currentState == .disabled ? .primary : .white
    }

    private var helpText: String {
        switch currentState {
        case .disabled: return "Tool is OFF. Click to enable (Ask mode)."
        case .ask: return "Ask Before Run: Suspends execution for your approval. Click for Auto mode."
        case .auto: return "Auto-Run: Tool executes automatically. Click to disable."
        }
    }

    private func cycleState() {
        switch currentState {
        case .disabled:
            var confirmation = true
            if let annotations = definition.annotations {
                if annotations.readOnlyHint == true {
                    confirmation = false
                }
            }

            let newTool = Tool(
                name: definition.name,
                description: definition.description,
                isEnabled: true,
                requiresConfirmation: confirmation,
                sourceId: source.id,
                parameters: definition.parameters
            )
            configuredTools.append(newTool)

        case .ask:
            if let index = configuredTools.firstIndex(where: { $0.name == definition.name && $0.sourceId == source.id }) {
                configuredTools[index].requiresConfirmation = false
            }

        case .auto:
            if instructions.contains("`\(definition.name)`") {
                showingDependencyAlert = true
            } else {
                configuredTools.removeAll { $0.name == definition.name && $0.sourceId == source.id }
            }
        }
    }
}

// MARK: - MCP v0.11.0 UI Components

/// Displays annotation badges for a tool's behavioral hints.
private struct ToolAnnotationBadges: View {
    let annotations: ToolAnnotations?

    var body: some View {
        if let annotations = annotations {
            HStack(spacing: 4) {
                if annotations.destructiveHint == true {
                    AnnotationBadge(text: "Destructive", color: .red, symbol: "exclamationmark.triangle.fill")
                }
                if annotations.readOnlyHint == true {
                    AnnotationBadge(text: "Read-only", color: .blue, symbol: "eye.fill")
                }
                if annotations.idempotentHint == true {
                    AnnotationBadge(text: "Idempotent", color: .green, symbol: "arrow.2.squarepath")
                }
                if annotations.openWorldHint == true {
                    AnnotationBadge(text: "Open World", color: .purple, symbol: "globe")
                }
            }
        }
    }
}

/// A compact colored pill badge with an SF Symbol and label.
private struct AnnotationBadge: View {
    let text: String
    let color: Color
    let symbol: String

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 8))
            Text(text)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundColor(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.1))
        .cornerRadius(4)
    }
}

/// Displays a colored circle indicating the MCP server's connection state.
private struct ConnectionStateIndicator: View {
    let sourceId: UUID
    @ObservedObject private var clientService = MCPClientService.shared

    private var state: MCPConnectionState {
        clientService.connectionStates[sourceId] ?? .disconnected
    }

    var body: some View {
        Circle()
            .fill(stateColor)
            .frame(width: 8, height: 8)
            .help(stateDescription)
    }

    private var stateColor: Color {
        switch state {
        case .disconnected: return .secondary.opacity(0.4)
        case .connecting, .reconnecting: return .orange
        case .connected: return .green
        case .error: return .red
        }
    }

    private var stateDescription: String {
        switch state {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .reconnecting(let attempt): return "Reconnecting (attempt \(attempt))..."
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

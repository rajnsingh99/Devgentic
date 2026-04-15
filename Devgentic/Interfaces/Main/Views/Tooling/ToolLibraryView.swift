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
    case favorites
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
    @Binding var isSelectionMode: Bool
    @Binding var selectedToolIDs: Set<String>

    @Environment(MainViewRouter.self) private var router
    private var toolStore: UnifiedToolStore { UnifiedToolStore.shared }
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
                        .font(.system(.caption, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }

                if favoriteCount > 0 {
                    Section {
                        sidebarRow(
                            label: "Favorites",
                            icon: "star.fill",
                            count: favoriteCount,
                            tag: .favorites
                        )
                    } header: {
                        Text("Pinned")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                            .textCase(.uppercase)
                            .tracking(0.5)
                    }
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
                        .font(.system(.caption, weight: .semibold))
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
                                    .font(theme.fontSubheadline)
                                    .foregroundColor(theme.primaryText)

                                Spacer()

                                Text("\(source.tools.count)")
                                    .font(.caption2)
                                    .foregroundColor(theme.secondaryText)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(theme.surfaceOverlay)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

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
                        .font(.system(.caption, weight: .semibold))
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
                .font(theme.fontSubheadline)
                .foregroundColor(theme.primaryText)
            Spacer()
            Text("\(count)")
                .font(.caption2)
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(theme.surfaceOverlay)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .tag(tag)
    }

    // MARK: - Detail (Tool List)

    @ViewBuilder
    private var toolDetailView: some View {
        if displayedRows.isEmpty {
            emptyStateView
        } else {
            ZStack(alignment: .bottom) {
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
                        .font(.system(.caption, weight: .semibold))
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
                    .padding(.bottom, isSelectionMode && !selectedToolIDs.isEmpty ? 64 : 20)
                }

                // Bulk action bar
                if isSelectionMode && !selectedToolIDs.isEmpty {
                    bulkActionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: selectedToolIDs.isEmpty)
        }
    }

    // MARK: - Bulk Actions

    private var bulkActionBar: some View {
        HStack(spacing: 12) {
            Text("\(selectedToolIDs.count) selected")
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            Button { bulkSetState(.ask) } label: {
                Label("Ask", systemImage: "lock.shield.fill")
                    .font(.system(.caption, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .controlSize(.small)

            Button { bulkSetState(.auto) } label: {
                Label("Auto", systemImage: "bolt.fill")
                    .font(.system(.caption, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .controlSize(.small)

            Button { bulkSetState(.disabled) } label: {
                Label("Disable", systemImage: "xmark")
                    .font(.system(.caption, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Divider().frame(height: 20)

            Button { bulkToggleFavorite() } label: {
                Image(systemName: "star.fill")
                    .font(.system(.caption))
            }
            .buttonStyle(.bordered)
            .tint(.yellow)
            .controlSize(.small)
            .accessibilityLabel("Toggle favorite")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.secondaryBackground)
                .shadow(color: .black.opacity(0.2), radius: 8, y: -2)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private enum BulkToolState {
        case ask, auto, disabled
    }

    private func bulkSetState(_ state: BulkToolState) {
        var tools = configuredTools

        for rowID in selectedToolIDs {
            guard let row = displayedRows.first(where: { $0.id == rowID }) else { continue }
            let name = row.definition.name
            let sourceId = row.source.id

            switch state {
            case .ask:
                if let idx = tools.firstIndex(where: { $0.name == name && $0.sourceId == sourceId }) {
                    tools[idx].requiresConfirmation = true
                } else {
                    tools.append(Tool(
                        name: name,
                        description: row.definition.description,
                        isEnabled: true,
                        requiresConfirmation: true,
                        sourceId: sourceId,
                        parameters: row.definition.parameters
                    ))
                }
            case .auto:
                if let idx = tools.firstIndex(where: { $0.name == name && $0.sourceId == sourceId }) {
                    tools[idx].requiresConfirmation = false
                } else {
                    tools.append(Tool(
                        name: name,
                        description: row.definition.description,
                        isEnabled: true,
                        requiresConfirmation: false,
                        sourceId: sourceId,
                        parameters: row.definition.parameters
                    ))
                }
            case .disabled:
                if instructions.contains("`\(name)`") { continue }
                tools.removeAll { $0.name == name && $0.sourceId == sourceId }
            }
        }

        configuredTools = tools
        selectedToolIDs.removeAll()
    }

    private func bulkToggleFavorite() {
        var tools = configuredTools
        let allFavorited = selectedToolIDs.allSatisfy { rowID in
            guard let row = displayedRows.first(where: { $0.id == rowID }) else { return false }
            return tools.first(where: { $0.name == row.definition.name && $0.sourceId == row.source.id })?.isFavorite == true
        }

        for rowID in selectedToolIDs {
            guard let row = displayedRows.first(where: { $0.id == rowID }) else { continue }
            if let idx = tools.firstIndex(where: { $0.name == row.definition.name && $0.sourceId == row.source.id }) {
                tools[idx].isFavorite = !allFavorited
            }
        }

        configuredTools = tools
        selectedToolIDs.removeAll()
    }

    private var isToolFavorited: (ToolTableRow) -> Bool {
        { row in configuredTools.first(where: { $0.name == row.definition.name && $0.sourceId == row.source.id })?.isFavorite == true }
    }

    private func toolRow(_ row: ToolTableRow) -> some View {
        let isEnabled = configuredTools.contains(where: { $0.name == row.definition.name && $0.sourceId == row.source.id })

        return ToolRowContent(
            row: row,
            isEnabled: isEnabled,
            isFavorited: isToolFavorited(row),
            isSelectionMode: isSelectionMode,
            isSelected: selectedToolIDs.contains(row.id),
            showSourceName: selectedSidebar == .all || selectedSidebar == .favorites,
            configuredTools: $configuredTools,
            instructions: instructions,
            theme: theme,
            onToggleSelection: {
                if selectedToolIDs.contains(row.id) {
                    selectedToolIDs.remove(row.id)
                } else {
                    selectedToolIDs.insert(row.id)
                }
            }
        )
    }

    // MARK: - Computed Properties

    var totalToolCount: Int {
        toolStore.sources.reduce(0) { $0 + $1.tools.count }
    }

    var favoriteCount: Int {
        configuredTools.filter(\.isFavorite).count
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
        case .favorites:
            let favoriteNames = Set(configuredTools.filter(\.isFavorite).map { "\($0.sourceId)-\($0.name)" })
            for source in toolStore.sources {
                for tool in source.tools {
                    let compositeKey = "\(source.id)-\(tool.name)"
                    if favoriteNames.contains(compositeKey) && matchesSearch(tool) {
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

        // Sort: favorites first, then alphabetical
        return rows.sorted { lhs, rhs in
            let lhsFav = configuredTools.first(where: { $0.name == lhs.definition.name && $0.sourceId == lhs.source.id })?.isFavorite == true
            let rhsFav = configuredTools.first(where: { $0.name == rhs.definition.name && $0.sourceId == rhs.source.id })?.isFavorite == true
            if lhsFav != rhsFav { return lhsFav }
            return lhs.definition.name < rhs.definition.name
        }
    }

    private func matchesSearch(_ tool: ToolDefinition) -> Bool {
        searchText.isEmpty ||
        tool.name.localizedCaseInsensitiveContains(searchText) ||
        tool.description.localizedCaseInsensitiveContains(searchText)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: searchText.isEmpty ? "puzzlepiece.extension" : "magnifyingglass")
                .font(.system(size: 48)) // Fixed size: intentional
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

// MARK: - Tool Row with Hover Effect

private struct ToolRowContent: View {
    let row: ToolTableRow
    let isEnabled: Bool
    let isFavorited: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let showSourceName: Bool
    @Binding var configuredTools: [Tool]
    let instructions: String
    let theme: any Theme
    let onToggleSelection: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Selection checkbox (bulk mode)
            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(theme.fontBody)
                    .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                    .frame(width: 20)
                    .onTapGesture { onToggleSelection() }
            }

            // Icon
            MCPIconView(
                icons: row.definition.icons,
                fallbackSymbol: row.source.type == .local ? "cpu" : "wrench.fill",
                size: 24
            )
            .foregroundColor(theme.accentColor)
            .frame(width: 28)

            // Name + source + favorite star
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let title = row.definition.title {
                        Text(title)
                            .font(theme.fontSubheadline.weight(.medium))
                            .foregroundColor(theme.primaryText)
                    } else {
                        Text(row.definition.name)
                            .font(.system(size: 13, weight: .medium, design: .monospaced)) // Fixed size: monospaced
                            .foregroundColor(theme.primaryText)
                    }

                    if isFavorited {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9)) // Fixed size: intentional (badge/chip text)
                            .foregroundColor(.yellow)
                    }
                }

                if row.definition.title != nil {
                    Text(row.definition.name)
                        .font(.system(size: 10, design: .monospaced)) // Fixed size: monospaced
                        .foregroundColor(theme.secondaryText)
                }

                ToolAnnotationBadges(annotations: row.definition.annotations)

                if showSourceName {
                    Text(row.source.serverName)
                        .font(.system(.caption2))
                        .foregroundColor(theme.secondaryText.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Description + info (info button only on hover)
            HStack(alignment: .center, spacing: 8) {
                Text(row.definition.description)
                    .font(.system(.caption))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)

                Spacer(minLength: 4)

                if isHovered {
                    ToolDetailsButton(definition: row.definition)
                        .transition(.opacity)
                }
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

            // Settings gear AFTER state button (only when enabled)
            if isEnabled {
                ToolSettingsPopover(
                    configuredTools: $configuredTools,
                    source: row.source,
                    definition: row.definition
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? theme.accentColor.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

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
        .accessibilityLabel("View full tool details & parameters")
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
                                                .font(.system(size: 9, weight: .bold)) // Fixed size: intentional (badge/chip text)
                                                .foregroundColor(.red)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 2)
                                                .background(Color.red.opacity(0.1))
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
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
                                .clipShape(RoundedRectangle(cornerRadius: 6))
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

    @Environment(\.appTheme) private var theme
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
                    .font(.system(.caption, weight: .bold))
                if currentState != .disabled {
                    Text(stateLabel)
                        .font(.system(.caption, weight: .semibold))
                }
            }
            .frame(width: currentState == .disabled ? 28 : 54, height: 16, alignment: .center)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(stateBackground)
        .foregroundColor(stateForeground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
        case .ask: return theme.warningColor
        case .auto: return theme.successColor
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

// MARK: - Per-Tool Settings Popover

private struct ToolSettingsPopover: View {
    @Binding var configuredTools: [Tool]
    let source: ToolSource
    let definition: ToolDefinition

    @State private var isShowingPopover = false
    @Environment(\.appTheme) private var theme

    private var toolIndex: Int? {
        configuredTools.firstIndex(where: { $0.name == definition.name && $0.sourceId == source.id })
    }

    var body: some View {
        Button {
            isShowingPopover.toggle()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(.caption))
                .foregroundColor(theme.secondaryText)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Tool settings")
        .accessibilityLabel("Tool settings")
        .popover(isPresented: $isShowingPopover, arrowEdge: .trailing) {
            popoverContent
                .frame(width: 280)
                .padding()
        }
    }

    @ViewBuilder
    private var popoverContent: some View {
        if let idx = toolIndex {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(theme.accentColor)
                    Text("Tool Settings")
                        .font(.headline)
                }

                Divider()

                // Favorite
                Toggle(isOn: Binding(
                    get: { configuredTools[idx].isFavorite },
                    set: { configuredTools[idx].isFavorite = $0 }
                )) {
                    Label("Favorite", systemImage: "star.fill")
                        .font(theme.fontSubheadline)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Divider()

                // Timeout
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { configuredTools[idx].timeout != nil },
                        set: { enabled in
                            configuredTools[idx].timeout = enabled ? 30 : nil
                            if !enabled { configuredTools[idx].timeoutMessage = nil }
                        }
                    )) {
                        Label("Timeout", systemImage: "clock")
                            .font(theme.fontSubheadline)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    if configuredTools[idx].timeout != nil {
                        HStack {
                            Stepper(
                                "\(Int(configuredTools[idx].timeout ?? 30))s",
                                value: Binding(
                                    get: { configuredTools[idx].timeout ?? 30 },
                                    set: { configuredTools[idx].timeout = $0 }
                                ),
                                in: 5...300,
                                step: 5
                            )
                            .font(.system(.caption))
                            .fixedSize()
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("On Timeout, Send:")
                                .font(.system(.caption, weight: .medium))
                                .foregroundColor(theme.secondaryText)

                            TextField(
                                "Custom message to LLM on timeout...",
                                text: Binding(
                                    get: { configuredTools[idx].timeoutMessage ?? "" },
                                    set: { configuredTools[idx].timeoutMessage = $0.isEmpty ? nil : $0 }
                                ),
                                axis: .vertical
                            )
                            .lineLimit(2...4)
                            .font(.system(.caption))
                            .textFieldStyle(.roundedBorder)
                        }

                        Text("Leave empty for default timeout error")
                            .font(.system(.caption2))
                            .foregroundColor(theme.secondaryText)
                    }
                }
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
                .font(.system(size: 8)) // Fixed size: intentional (badge icon)
            Text(text)
                .font(.system(size: 9, weight: .medium)) // Fixed size: intentional (badge/chip text)
        }
        .foregroundColor(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// Displays a colored circle indicating the MCP server's connection state.
private struct ConnectionStateIndicator: View {
    let sourceId: UUID

    private var state: MCPConnectionState {
        MCPClientService.shared.connectionStates[sourceId] ?? .disconnected
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

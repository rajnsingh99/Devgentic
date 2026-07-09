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

    /// Tool names to hide from the library. For Code profiles, this is the full
    /// CodeToolPreset — the user never sees those rows, so they can't disable or
    /// toggle them. Empty for other profile types.
    var hiddenToolNames: Set<String> = []

    @Environment(MainViewRouter.self) private var router
    private var toolStore: UnifiedToolStore { UnifiedToolStore.shared }
    @Environment(\.appTheme) private var theme

    /// Source the user just clicked "Report Issue..." on. Drives the bug-
    /// report sheet's `.sheet(item:)` binding.
    @State private var bugReportSource: ToolSource? = nil

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
        .frame(maxWidth: 1100)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .sheet(item: $bugReportSource) { source in
            MCPBugReportSheet(source: source)
        }
    }    // MARK: - Sidebar

    @ViewBuilder
    private var toolSidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // LIBRARY Section
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Library")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.secondaryText.opacity(0.7))
                            .textCase(.uppercase)
                            .tracking(0.8)
                            .padding(.leading, 8)
                        
                        sidebarRow(
                            label: "All Tools",
                            icon: "archivebox.fill",
                            count: totalToolCount,
                            tag: .all
                        )
                    }
                    
                    // PINNED Section
                    if favoriteCount > 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pinned")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(theme.secondaryText.opacity(0.7))
                                .textCase(.uppercase)
                                .tracking(0.8)
                                .padding(.leading, 8)
                            
                            sidebarRow(
                                label: "Favorites",
                                icon: "star.fill",
                                count: favoriteCount,
                                tag: .favorites
                            )
                        }
                    }
                    
                    // BUILT-IN TOOLS Section
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Built-in Tools")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.secondaryText.opacity(0.7))
                            .textCase(.uppercase)
                            .tracking(0.8)
                            .padding(.leading, 8)
                        
                        ForEach(builtInGroups, id: \.name) { group in
                            sidebarRow(
                                label: group.name,
                                icon: group.icon,
                                count: group.count,
                                tag: .localCategory(group.name)
                            )
                        }
                    }
                    
                    // MCP SERVERS Section
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MCP Servers")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.secondaryText.opacity(0.7))
                            .textCase(.uppercase)
                            .tracking(0.8)
                            .padding(.leading, 8)
                        
                        let mcpSources = toolStore.sources.filter { $0.type == .mcp }
                        
                        if mcpSources.isEmpty {
                            VStack(spacing: 6) {
                                Text("No MCP servers")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.secondaryText)
                                Button("Add Server") { router.navigate(to: .addMCPServer) }
                                    .font(.system(size: 10, weight: .semibold))
                                    .buttonStyle(.plain)
                                    .foregroundColor(theme.accentColor)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                        } else {
                            ForEach(mcpSources) { source in
                                mcpSidebarRow(source: source)
                            }
                        }
                    }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 10)
            }
        }
        .background(theme.secondaryBackground.opacity(0.4))
    }

    private func sidebarRow(label: String, icon: String, count: Int, tag: SidebarSelection) -> some View {
        let isSelected = selectedSidebar == tag
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                .frame(width: 18, alignment: .center)
            
            Text(label)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? theme.primaryText : theme.primaryText.opacity(0.85))
            
            Spacer()
            
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(isSelected ? theme.accentColor.opacity(0.12) : theme.surfaceOverlay)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? theme.accentColor.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.8)) {
                selectedSidebar = tag
            }
        }
        .tag(tag)
    }

    private func mcpSidebarRow(source: ToolSource) -> some View {
        let tag = SidebarSelection.mcp(source.id)
        let isSelected = selectedSidebar == tag
        
        return HStack(spacing: 8) {
            MCPIconView(
                icons: source.tools.first?.icons,
                fallbackSymbol: "network",
                size: 14
            )
            .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
            .frame(width: 18, alignment: .center)
            
            Text(source.serverName)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? theme.primaryText : theme.primaryText.opacity(0.85))
                .lineLimit(1)
            
            Spacer()
            
            Text("\(source.tools.count)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(isSelected ? theme.accentColor.opacity(0.12) : theme.surfaceOverlay)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            
            ConnectionStateIndicator(sourceId: source.id)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? theme.accentColor.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.8)) {
                selectedSidebar = tag
            }
        }
        .contextMenu {
            Button("Edit Configuration...") {
                router.navigate(to: .editMCPServer(sourceID: source.id))
            }
            Button("Report Issue...") {
                bugReportSource = source
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

    // MARK: - Detail (Tool List)

    @ViewBuilder
    private var toolDetailView: some View {
        if displayedRows.isEmpty {
            emptyStateView
        } else {
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        // Title / Count summary header
                        HStack {
                            Text(currentSelectionTitle)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(theme.secondaryText.opacity(0.8))
                                .textCase(.uppercase)
                                .tracking(0.5)
                            
                            Spacer()
                            
                            Text("\(displayedRows.count) \(displayedRows.count == 1 ? "tool" : "tools")")
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 14)
                        .padding(.bottom, 2)
                        
                        ForEach(displayedRows) { row in
                            toolRow(row)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, isSelectionMode && !selectedToolIDs.isEmpty ? 80 : 20)
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
        HStack(spacing: 14) {
            Text("\(selectedToolIDs.count) Selected")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(theme.primaryText)
                .textCase(.uppercase)
                .tracking(0.5)

            Spacer()

            Button { bulkSetState(.ask) } label: {
                Label("Ask First", systemImage: "lock.shield.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.warningColor)
            .controlSize(.small)

            Button { bulkSetState(.auto) } label: {
                Label("Auto Run", systemImage: "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.successColor)
            .controlSize(.small)

            Button { bulkSetState(.disabled) } label: {
                Label("Disable", systemImage: "xmark.circle")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .controlSize(.small)

            Divider().frame(height: 16)

            Button { bulkToggleFavorite() } label: {
                Label("Favorite", systemImage: "star.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .tint(.yellow)
            .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.secondaryBackground.opacity(0.85))
                .background(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.accentColor.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 5)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
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
        toolStore.sources.reduce(0) { acc, source in
            acc + source.tools.filter { !hiddenToolNames.contains($0.name) }.count
        }
    }

    var favoriteCount: Int {
        configuredTools.filter(\.isFavorite).count
    }

    /// Groups built-in tools by sidebar category with counts. Hidden tools are
    /// excluded so the Code profile doesn't see per-category rows for preset tools.
    var builtInGroups: [(name: String, icon: String, count: Int)] {
        let localTools = toolStore.sources.filter { $0.type == .local }
            .flatMap { $0.tools }
            .filter { !hiddenToolNames.contains($0.name) }
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

    private var currentSelectionTitle: String {
        switch selectedSidebar {
        case .all:
            return "All Tools"
        case .favorites:
            return "Favorites"
        case .localCategory(let category):
            return category
        case .mcp(let id):
            if let source = toolStore.sources.first(where: { $0.id == id }) {
                return source.serverName
            }
            return "MCP Server"
        case .none:
            return "Tools"
        }
    }

    var displayedRows: [ToolTableRow] {
        var rows: [ToolTableRow] = []

        switch selectedSidebar {
        case .all:
            for source in toolStore.sources {
                for tool in source.tools where !hiddenToolNames.contains(tool.name) {
                    if matchesSearch(tool) {
                        rows.append(ToolTableRow(source: source, definition: tool))
                    }
                }
            }
        case .favorites:
            let favoriteNames = Set(configuredTools.filter(\.isFavorite).map { "\($0.sourceId)-\($0.name)" })
            for source in toolStore.sources {
                for tool in source.tools where !hiddenToolNames.contains(tool.name) {
                    let compositeKey = "\(source.id)-\(tool.name)"
                    if favoriteNames.contains(compositeKey) && matchesSearch(tool) {
                        rows.append(ToolTableRow(source: source, definition: tool))
                    }
                }
            }
        case .localCategory(let groupName):
            guard let group = BuiltInToolCategory.allGroups.first(where: { $0.name == groupName }) else { break }
            for source in toolStore.sources where source.type == .local {
                for tool in source.tools where group.rawCategories.contains(tool.category) && !hiddenToolNames.contains(tool.name) {
                    if matchesSearch(tool) {
                        rows.append(ToolTableRow(source: source, definition: tool))
                    }
                }
            }
        case .mcp(let id):
            for source in toolStore.sources where source.id == id {
                for tool in source.tools where !hiddenToolNames.contains(tool.name) {
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
                Button("Add MCP Server") { router.navigate(to: .addMCPServer) }
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

    private var displayTitle: String {
        if let title = row.definition.title {
            return title
        }
        return row.definition.name.toTitleCase()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                // Left: Icon + Titles
                HStack(alignment: .center, spacing: 12) {
                    // Selection checkbox (bulk mode)
                    if isSelectionMode {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 14))
                            .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                            .onTapGesture { onToggleSelection() }
                    }

                    // Icon
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor.opacity(0.1))
                            .frame(width: 36, height: 36)
                        
                        MCPIconView(
                            icons: row.definition.icons,
                            fallbackSymbol: row.source.type == .local ? "cpu" : "wrench.fill",
                            size: 20
                        )
                        .foregroundColor(theme.accentColor)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .center, spacing: 6) {
                            Text(displayTitle)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            
                            if isFavorited {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.yellow)
                            }
                            
                            if showSourceName {
                                Text(row.source.serverName)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(theme.secondaryText.opacity(0.6))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(theme.surfaceOverlay)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        
                        // Technical name code badge
                        Text(row.definition.name)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(theme.secondaryText.opacity(0.85))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(theme.dividerColor.opacity(0.3), lineWidth: 0.5)
                            )
                    }
                }
                
                Spacer()
                
                // Right: Hover controls (gear, info) + State control button
                HStack(alignment: .center, spacing: 10) {
                    if isHovered {
                        HStack(spacing: 8) {
                            ToolDetailsButton(definition: row.definition)
                                .font(.system(size: 14))
                            
                            if isEnabled {
                                ToolSettingsPopover(
                                    configuredTools: $configuredTools,
                                    source: row.source,
                                    definition: row.definition
                                )
                                .font(.system(size: 14))
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                    
                    ToolStateControl(
                        configuredTools: $configuredTools,
                        source: row.source,
                        definition: row.definition,
                        instructions: instructions
                    )
                }
            }
            
            // Description & Badges
            VStack(alignment: .leading, spacing: 8) {
                Text(row.definition.description)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2)
                    .lineLimit(isHovered ? nil : 2) // Expand description on hover
                    .fixedSize(horizontal: false, vertical: true)
                
                if row.definition.annotations != nil {
                    ToolAnnotationBadges(annotations: row.definition.annotations)
                }
            }
            .padding(.leading, isSelectionMode ? 32 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground.opacity(isHovered ? 0.95 : 0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHovered ? theme.accentColor.opacity(0.4) : theme.dividerColor.opacity(0.3), lineWidth: isHovered ? 1.5 : 1)
        )
        .shadow(color: theme.shadowColor.opacity(isHovered ? 0.12 : 0.04), radius: isHovered ? 8 : 2, x: 0, y: isHovered ? 4 : 1)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                isHovered = hovering
            }
        }
    }
}

private struct ParameterTypeBadge: View {
    let typeName: String
    
    private var color: Color {
        switch typeName.lowercased() {
        case "string": return .blue
        case "integer", "number": return .green
        case "boolean": return .purple
        case "array": return .orange
        case "object": return .yellow
        default: return .secondary
        }
    }
    
    var body: some View {
        Text(typeName.uppercased())
            .font(.system(size: 8, weight: .bold))
            .tracking(0.5)
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(color.opacity(0.3), lineWidth: 0.5)
            )
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
                VStack(alignment: .leading, spacing: 14) {
                    // Header
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.accentColor.opacity(0.12))
                                .frame(width: 32, height: 32)
                            
                            MCPIconView(icons: definition.icons, fallbackSymbol: "wrench.fill", size: 16)
                                .foregroundColor(theme.accentColor)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            if let title = definition.title {
                                Text(title)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(theme.primaryText)
                                
                                Text(definition.name)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(theme.secondaryText)
                            } else {
                                Text(definition.name.toTitleCase())
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(theme.primaryText)
                                
                                Text(definition.name)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(theme.secondaryText)
                            }
                        }
                    }
                    .padding(.bottom, 4)

                    // Full Description
                    Text(definition.description)
                        .font(.system(size: 12))
                        .foregroundColor(theme.primaryText.opacity(0.9))
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    // Behavior Hints
                    if let annotations = definition.annotations {
                        Divider().background(theme.dividerColor.opacity(0.4))
                        
                        Text("Behavior")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.secondaryText)
                            .textCase(.uppercase)
                            .tracking(0.5)
                        
                        ToolAnnotationBadges(annotations: annotations)
                    }

                    Divider().background(theme.dividerColor.opacity(0.4))

                    // Parameters Section
                    Text("Parameters Schema")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    if definition.parameters.properties.isEmpty {
                        Text("No parameters required.")
                            .font(.system(size: 11))
                            .italic()
                            .foregroundColor(theme.secondaryText)
                            .padding(.vertical, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(definition.parameters.properties.keys.sorted()), id: \.self) { key in
                                let prop = definition.parameters.properties[key]!
                                let isRequired = definition.parameters.required.contains(key)

                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .center, spacing: 6) {
                                        Text(key)
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundColor(theme.primaryText)
                                        
                                        ParameterTypeBadge(typeName: prop.type)

                                        if isRequired {
                                            Text("REQUIRED")
                                                .font(.system(size: 8, weight: .bold))
                                                .tracking(0.5)
                                                .foregroundColor(theme.errorColor)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(theme.errorColor.opacity(0.08))
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 4)
                                                        .stroke(theme.errorColor.opacity(0.3), lineWidth: 0.5)
                                                )
                                        }
                                    }

                                    if let desc = prop.description {
                                        Text(desc)
                                            .font(.system(size: 11))
                                            .foregroundColor(theme.secondaryText)
                                            .lineSpacing(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.secondaryBackground.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.dividerColor.opacity(0.35), lineWidth: 1)
                                )
                            }
                        }
                    }
                }
                .padding(16)
            }
            .frame(width: 380)
            .frame(maxHeight: 520)
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
    @State private var isHovered = false

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
            HStack(spacing: 6) {
                stateIcon
                    .font(.system(size: 10, weight: .bold))
                
                Text(stateLabel)
                    .font(.system(size: 10, weight: .semibold))
            }
            .frame(width: 88, height: 24)
            .background(stateBackground)
            .foregroundColor(stateForeground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(stateBorder, lineWidth: 1)
            )
            .shadow(color: stateShadowColor, radius: isHovered ? 4 : 2, x: 0, y: isHovered ? 2 : 1)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .contentShape(Capsule())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
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
        case .disabled: return "Disabled"
        case .ask: return "Ask First"
        case .auto: return "Auto Run"
        }
    }

    private var stateBackground: AnyView {
        switch currentState {
        case .disabled:
            return AnyView(Color.clear)
        case .ask:
            return AnyView(
                LinearGradient(
                    colors: [theme.warningColor.opacity(0.85), theme.warningColor],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        case .auto:
            return AnyView(
                LinearGradient(
                    colors: [theme.successColor.opacity(0.85), theme.successColor],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private var stateBorder: Color {
        switch currentState {
        case .disabled:
            return theme.secondaryText.opacity(0.3)
        case .ask, .auto:
            return Color.clear
        }
    }

    private var stateForeground: Color {
        switch currentState {
        case .disabled:
            return theme.secondaryText
        case .ask, .auto:
            return .white
        }
    }

    private var stateShadowColor: Color {
        if !isHovered { return Color.black.opacity(0.05) }
        switch currentState {
        case .disabled: return Color.black.opacity(0.1)
        case .ask: return theme.warningColor.opacity(0.3)
        case .auto: return theme.successColor.opacity(0.3)
        }
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
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .semibold))
            
            Text(text.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(color.opacity(0.35), lineWidth: 0.5)
        )
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

// MARK: - String Extension for Title Case

extension String {
    func toTitleCase() -> String {
        let parts = self.split { $0 == "_" || $0 == "-" }
        return parts.map { part in
            let word = String(part)
            let lower = word.lowercased()
            switch lower {
            case "ui": return "UI"
            case "mcp": return "MCP"
            case "pim": return "PIM"
            case "llm": return "LLM"
            case "macos": return "macOS"
            case "db": return "Database"
            case "cli": return "CLI"
            default:
                if lower.isEmpty { return "" }
                let first = lower.prefix(1).uppercased()
                let rest = lower.dropFirst()
                return first + rest
            }
        }.joined(separator: " ")
    }
}

//
//  ToolLibraryContainerView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//
//  Wraps ToolLibraryView for display in the main content area.
//  DynamicIslandBar houses search, select-all, add-MCP, and done actions.
//

import SwiftUI

struct ToolLibraryContainerView: View {

    let profileID: UUID

    @EnvironmentObject private var profileService: BackendProfileService
    @EnvironmentObject private var router: MainViewRouter
    @Environment(\.appTheme) private var theme

    @State private var searchText = ""
    @State private var selectedSidebar: SidebarSelection? = .all
    @State private var isPresentingAddView = false
    @State private var isSelectAllHovered = false
    @State private var isAddHovered = false
    @State private var isDoneHovered = false

    var body: some View {
        if let index = profileService.profiles.firstIndex(where: { $0.id == profileID }) {
            VStack(spacing: 0) {
                DynamicIslandBar {
                    // CENTER: Search bar
                    searchBar
                } trailing: {
                    // TRAILING: Action icons
                    actionIcons(for: index)
                }
                .padding(.bottom, 8)

                ToolLibraryView(
                    configuredTools: toolsBinding(for: index),
                    instructions: instructions(for: index),
                    searchText: $searchText,
                    selectedSidebar: $selectedSidebar
                )
            }
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
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundColor(theme.secondaryText)
                Text("Profile not found")
                    .font(.title3)
                    .foregroundColor(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Search Bar (Center Content)

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)

            TextField("Search tools...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(theme.surfaceOverlay)
        )
        .frame(maxWidth: 260)
    }

    // MARK: - Action Icons (Trailing Content)

    private func actionIcons(for index: Int) -> some View {
        HStack(spacing: 6) {
            // Select All
            iconButton(
                symbol: allToolsSelected(for: index) ? "checkmark.circle.fill" : "checkmark.circle",
                color: allToolsSelected(for: index) ? theme.accentColor : theme.primaryText,
                isHovered: $isSelectAllHovered,
                help: allToolsSelected(for: index) ? "Deselect all tools" : "Select all tools"
            ) {
                toggleSelectAll(for: index)
            }

            // Add MCP Server
            iconButton(
                symbol: "plus.circle",
                color: theme.primaryText,
                isHovered: $isAddHovered,
                help: "Add MCP Server"
            ) {
                isPresentingAddView = true
            }

            // Done
            iconButton(
                symbol: "checkmark",
                color: theme.primaryText,
                isHovered: $isDoneHovered,
                help: "Done"
            ) {
                router.goBack()
            }
        }
    }

    private func iconButton(
        symbol: String,
        color: Color,
        isHovered: Binding<Bool>,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(isHovered.wrappedValue ? theme.accentColor : color)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isHovered.wrappedValue ? theme.accentColor.opacity(0.12) : Color.clear)
                )
                .scaleEffect(isHovered.wrappedValue ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered.wrappedValue = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered.wrappedValue)
        .help(help)
    }

    // MARK: - Select All Logic

    private func allToolsSelected(for index: Int) -> Bool {
        guard case .agent(_, _, let tools, _, _, _) = profileService.profiles[index].details else { return false }
        let rows = currentDisplayedRows()
        guard !rows.isEmpty else { return false }
        return rows.allSatisfy { row in
            tools.contains(where: { $0.name == row.definition.name && $0.sourceId == row.source.id })
        }
    }

    private func toggleSelectAll(for index: Int) {
        guard case .agent(let config, let arch, var tools, let desc, let instr, let sources) = profileService.profiles[index].details else { return }

        let rows = currentDisplayedRows()
        let allSelected = rows.allSatisfy { row in
            tools.contains(where: { $0.name == row.definition.name && $0.sourceId == row.source.id })
        }

        if allSelected {
            // Deselect all in current view
            for row in rows {
                // Skip tools referenced in instructions
                if let instructions = instr, instructions.contains("`\(row.definition.name)`") {
                    continue
                }
                tools.removeAll { $0.name == row.definition.name && $0.sourceId == row.source.id }
            }
        } else {
            // Select all in current view (default to Ask mode)
            for row in rows {
                if !tools.contains(where: { $0.name == row.definition.name && $0.sourceId == row.source.id }) {
                    var confirmation = true
                    if let annotations = row.definition.annotations, annotations.readOnlyHint == true {
                        confirmation = false
                    }
                    tools.append(Tool(
                        name: row.definition.name,
                        description: row.definition.description,
                        isEnabled: true,
                        requiresConfirmation: confirmation,
                        sourceId: row.source.id,
                        parameters: row.definition.parameters
                    ))
                }
            }
        }

        profileService.profiles[index].details = .agent(
            llmConfig: config,
            architecture: arch,
            tools: tools,
            description: desc,
            instructions: instr,
            knowledgeSources: sources
        )
        profileService.saveProfile(profileService.profiles[index])
    }

    /// Get the currently visible tool rows based on sidebar selection and search.
    private func currentDisplayedRows() -> [ToolTableRow] {
        let toolStore = UnifiedToolStore.shared
        var rows: [ToolTableRow] = []

        switch selectedSidebar {
        case .all:
            for source in toolStore.sources {
                for tool in source.tools where matchesSearch(tool) {
                    rows.append(ToolTableRow(source: source, definition: tool))
                }
            }
        case .localCategory(let groupName):
            guard let group = BuiltInToolCategory.allGroups.first(where: { $0.name == groupName }) else { break }
            for source in toolStore.sources where source.type == .local {
                for tool in source.tools where group.rawCategories.contains(tool.category) && matchesSearch(tool) {
                    rows.append(ToolTableRow(source: source, definition: tool))
                }
            }
        case .mcp(let id):
            for source in toolStore.sources where source.id == id {
                for tool in source.tools where matchesSearch(tool) {
                    rows.append(ToolTableRow(source: source, definition: tool))
                }
            }
        case .none:
            break
        }

        return rows
    }

    private func matchesSearch(_ tool: ToolDefinition) -> Bool {
        searchText.isEmpty ||
        tool.name.localizedCaseInsensitiveContains(searchText) ||
        tool.description.localizedCaseInsensitiveContains(searchText)
    }

    // MARK: - Bindings

    private func toolsBinding(for index: Int) -> Binding<[Tool]> {
        Binding(
            get: {
                if case .agent(_, _, let tools, _, _, _) = profileService.profiles[index].details {
                    return tools
                }
                return []
            },
            set: { newTools in
                if case .agent(let config, let arch, _, let desc, let instr, let sources) = profileService.profiles[index].details {
                    profileService.profiles[index].details = .agent(
                        llmConfig: config,
                        architecture: arch,
                        tools: newTools,
                        description: desc,
                        instructions: instr,
                        knowledgeSources: sources
                    )
                    profileService.saveProfile(profileService.profiles[index])
                }
            }
        )
    }

    private func instructions(for index: Int) -> String {
        if case .agent(_, _, _, _, let instructions, _) = profileService.profiles[index].details {
            return instructions ?? ""
        }
        return ""
    }
}

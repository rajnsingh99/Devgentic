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

    @Environment(BackendProfileService.self) private var profileService
    @Environment(MainViewRouter.self) private var router

    @State private var searchText = ""
    @State private var selectedSidebar: SidebarSelection? = .all
    @State private var isSelectionMode = false
    @State private var selectedToolIDs: Set<String> = []

    var body: some View {
        if profileService.profiles.contains(where: { $0.id == profileID }) {
            VStack(spacing: 0) {
                DynamicIslandBar {
                    IslandSearchField(
                        text: $searchText,
                        placeholder: "Search tools...",
                        autoFocus: true,
                        accessibilityIdentifier: "tool.library.search"
                    )
                } trailing: {
                    actionIcons
                }
                .padding(.bottom, 8)

                // The container itself takes whatever width is offered. The
                // inner ToolLibraryView caps itself at 1200pt (20% wider than
                // the global content column) so the sidebar + table can breathe
                // without dragging the island bar wider than its standard.
                ToolLibraryView(
                    configuredTools: toolsBinding,
                    instructions: currentInstructions,
                    searchText: $searchText,
                    selectedSidebar: $selectedSidebar,
                    isSelectionMode: $isSelectionMode,
                    selectedToolIDs: $selectedToolIDs,
                    hiddenToolNames: hiddenToolNames
                )
                .frame(maxWidth: .infinity)
            }
            .id(profileID)
        } else {
            ContentNotFoundView(
                icon: "exclamationmark.triangle",
                title: "Profile Not Found",
                subtitle: "This profile may have been deleted. Use the back button to return."
            )
        }
    }

    // MARK: - Action Icons (Trailing Content)

    private var actionIcons: some View {
        HStack(spacing: 6) {
            IslandIconButton(
                symbol: isSelectionMode ? "checklist.checked" : "checklist",
                isActive: isSelectionMode,
                help: isSelectionMode ? "Exit selection mode" : "Bulk select tools",
                accessibilityLabel: isSelectionMode ? "Exit bulk selection mode" : "Enter bulk selection mode"
            ) {
                isSelectionMode.toggle()
                if !isSelectionMode { selectedToolIDs.removeAll() }
            }

            IslandIconButton(
                symbol: allToolsSelected ? "checkmark.circle.fill" : "checkmark.circle",
                isActive: allToolsSelected,
                help: allToolsSelected ? "Deselect all tools" : "Select all tools",
                accessibilityLabel: allToolsSelected ? "Deselect all tools" : "Select all tools"
            ) {
                toggleSelectAll()
            }

            IslandIconButton(
                symbol: "plus.circle",
                help: "Add MCP Server",
                accessibilityLabel: "Add MCP Server"
            ) {
                router.navigate(to: .addMCPServer)
            }

            // "Done" uses `checkmark.seal.fill` to disambiguate from the
            // neighboring `checkmark` / `checkmark.circle` affordances. Promoted
            // to .prominent so the primary CTA reads distinctly from the
            // ghost-style toggles to its left.
            IslandIconButton(
                symbol: "checkmark.seal.fill",
                style: .prominent,
                help: "Done (⌘↩)",
                accessibilityLabel: "Done, return to previous view",
                keyboardShortcut: .defaultAction
            ) {
                router.goBack()
            }
        }
    }

    // MARK: - Current Profile Lookup

    private var currentProfile: BackendProfileModel? {
        profileService.profiles.first(where: { $0.id == profileID })
    }

    /// True when the active profile is a Code profile (`.code(AgentConfig)`). Drives
    /// the preset-tool hiding in the library so the user can't disable them.
    private var isCodeProfile: Bool {
        guard let profile = currentProfile else { return false }
        if case .code = profile.details { return true }
        return false
    }

    /// Tool names to hide from the Tool Library UI. For Code profiles, this is the
    /// full preset (originals + splits) — invisible rows can't be disabled. For
    /// other profile types, nothing is hidden.
    private var hiddenToolNames: Set<String> {
        isCodeProfile ? CodeToolPreset.hiddenToolNames : []
    }

    /// Reads the tools list from either an `.agent` or `.code` profile detail case.
    private func readTools(from details: ProfileDetails) -> [Tool] {
        switch details {
        case .agent(let config): return config.tools
        case .code(let config):  return config.tools
        default: return []
        }
    }

    /// Writes a tools list back into either an `.agent` or `.code` profile detail case.
    private func writeTools(_ tools: [Tool], into details: ProfileDetails) -> ProfileDetails {
        switch details {
        case .agent(var config):
            config.tools = tools
            return .agent(config)
        case .code(var config):
            config.tools = tools
            return .code(config)
        default:
            return details
        }
    }

    // MARK: - Select All Logic

    private var currentTools: [Tool] {
        if let buffer = profileService.editBuffer, buffer.draft.id == profileID {
            return readTools(from: buffer.draft.details)
        }
        guard let profile = currentProfile else { return [] }
        return readTools(from: profile.details)
    }

    private var allToolsSelected: Bool {
        let tools = currentTools
        let rows = currentDisplayedRows()
        guard !rows.isEmpty else { return false }
        return rows.allSatisfy { row in
            tools.contains(where: { $0.name == row.definition.name && $0.sourceId == row.source.id })
        }
    }

    private func toggleSelectAll() {
        guard let profile = currentProfile else { return }
        var tools = readTools(from: profile.details)
        let instructions = currentInstructions

        let rows = currentDisplayedRows()
        let allSelected = rows.allSatisfy { row in
            tools.contains(where: { $0.name == row.definition.name && $0.sourceId == row.source.id })
        }

        if allSelected {
            // Deselect all in current view
            for row in rows {
                // Skip tools referenced in instructions
                if instructions.contains("`\(row.definition.name)`") {
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

        // Sync to edit buffer
        if let buffer = profileService.editBuffer, buffer.draft.id == profileID {
            buffer.draft.details = writeTools(tools, into: buffer.draft.details)
        }
        // Persist
        if let idx = profileService.profiles.firstIndex(where: { $0.id == profileID }) {
            profileService.profiles[idx].details = writeTools(tools, into: profileService.profiles[idx].details)
            try? profileService.saveProfile(profileService.profiles[idx])
        }
    }

    /// Get the currently visible tool rows based on sidebar selection and search.
    /// Tools in `hiddenToolNames` are filtered out (used for Code profiles).
    private func currentDisplayedRows() -> [ToolTableRow] {
        let toolStore = UnifiedToolStore.shared
        let hidden = hiddenToolNames
        var rows: [ToolTableRow] = []

        switch selectedSidebar {
        case .all:
            for source in toolStore.sources {
                for tool in source.tools where matchesSearch(tool) && !hidden.contains(tool.name) {
                    rows.append(ToolTableRow(source: source, definition: tool))
                }
            }
        case .favorites:
            let tools = currentTools
            let favoriteKeys = Set(tools.filter(\.isFavorite).map { "\($0.sourceId)-\($0.name)" })
            for source in toolStore.sources {
                for tool in source.tools where !hidden.contains(tool.name) {
                    let key = "\(source.id)-\(tool.name)"
                    if favoriteKeys.contains(key) && matchesSearch(tool) {
                        rows.append(ToolTableRow(source: source, definition: tool))
                    }
                }
            }
        case .localCategory(let groupName):
            guard let group = BuiltInToolCategory.allGroups.first(where: { $0.name == groupName }) else { break }
            for source in toolStore.sources where source.type == .local {
                for tool in source.tools where group.rawCategories.contains(tool.category) && matchesSearch(tool) && !hidden.contains(tool.name) {
                    rows.append(ToolTableRow(source: source, definition: tool))
                }
            }
        case .mcp(let id):
            for source in toolStore.sources where source.id == id {
                for tool in source.tools where matchesSearch(tool) && !hidden.contains(tool.name) {
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

    private var toolsBinding: Binding<[Tool]> {
        Binding(
            get: {
                // Read from edit buffer if active, otherwise fall back to profile service
                if let buffer = self.profileService.editBuffer, buffer.draft.id == self.profileID {
                    return self.readTools(from: buffer.draft.details)
                }
                guard let profile = self.currentProfile else { return [] }
                return self.readTools(from: profile.details)
            },
            set: { newTools in
                // Write to edit buffer (keeps detail views in sync)
                if let buffer = self.profileService.editBuffer, buffer.draft.id == self.profileID {
                    buffer.draft.details = self.writeTools(newTools, into: buffer.draft.details)
                }
                // Also write to profile service for persistence
                guard let idx = self.profileService.profiles.firstIndex(where: { $0.id == self.profileID }) else { return }
                self.profileService.profiles[idx].details = self.writeTools(newTools, into: self.profileService.profiles[idx].details)
                try? self.profileService.saveProfile(self.profileService.profiles[idx])
            }
        )
    }

    private var currentInstructions: String {
        guard let profile = currentProfile else { return "" }
        switch profile.details {
        case .agent(let config): return config.instructions ?? ""
        case .code(let config):  return config.instructions ?? ""
        default: return ""
        }
    }
}

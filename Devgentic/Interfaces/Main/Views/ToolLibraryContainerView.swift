// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

private let logger = DGLogger(category: "ToolLibraryContainer")

struct ToolLibraryContainerView: View {

    /// Profile supplied by the route, if any. Nil when opened from the Tools rail tab.
    let routeProfileID: UUID?

    @Environment(BackendProfileService.self) private var profileService
    /// The Code profile's tools belong to the OPEN PROJECT — the label must say which one.
    @Environment(CodeSessionManager.self) private var codeSessionManager
    // register B16 — needed to surface the tool-capability advisory this screen was discarding.
    @Environment(ToastManager.self) private var toastManager
    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme

    @State private var isSearchExpanded = false
    @State private var isSelectionMode = false
    @State private var selectedToolIDs: Set<String> = []
    @State private var isShowingAllToolsDropdown = false

    /// Profile chosen inside the library, persisted so the Tools tab reopens where you left
    /// off. An explicit route profile always wins over it — arriving from a profile's own
    /// config must configure THAT profile, not whatever was last picked here.
    @AppStorage("toolLibrary.lastProfileID") private var rememberedProfileIDRaw: String = ""

    /// The profile currently being configured. Precedence: route > remembered > none.
    private var profileID: UUID? {
        if let routeProfileID { return routeProfileID }
        guard let remembered = UUID(uuidString: rememberedProfileIDRaw),
              profileService.profiles.contains(where: { $0.id == remembered }) else { return nil }
        return remembered
    }

    /// True when there is a profile to write tool enablement into. Everything that mutates —
    /// per-row toggles, selection mode, bulk actions — is hidden when false, because a
    /// control that appears functional with nowhere to write is worse than an absent one.
    private var canConfigureTools: Bool { profileID != nil }

    private var selectedSidebar: SidebarSelection? { ToolLibraryNavigationState.shared.selectedSidebar }

    var body: some View {
        if profileID == nil || profileService.profiles.contains(where: { $0.id == profileID! }) {
            VStack(spacing: 0) {
                DynamicIslandBar {
                    IslandExpandableSearchHeader(
                        title: "Tool Library",
                        icon: "wrench.and.screwdriver",
                        text: Binding(get: { ToolLibraryNavigationState.shared.searchText },
                                     set: { ToolLibraryNavigationState.shared.searchText = $0 }),
                        // One search field for the whole library; what it searches depends on
                        // where you are, so the placeholder has to say which.
                        placeholder: ToolLibraryNavigationState.shared.selectedSidebar == .marketplace
                            ? "Search the MCP registry"
                            : "Search tools",
                        isExpanded: $isSearchExpanded,
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
                    isSelectionMode: $isSelectionMode,
                    selectedToolIDs: $selectedToolIDs,
                    hiddenToolNames: hiddenToolNames,
                    lockedToolNames: lockedToolNames,
                    canConfigureTools: canConfigureTools,
                    profileSelector: { AnyView(profileSelector) }
                )
                .frame(maxWidth: .infinity)
            }
            .id(profileID ?? ToolSource.builtInSourceID)
            .onAppear {
                // Deep-link from the Tools sidebar: select the server the user clicked.
                // One-shot — it clears itself so a later plain navigation does not inherit
                // a stale selection.
                if let pending = MCPToolLibrarySelection.shared.consume() {
                    ToolLibraryNavigationState.shared.selectedSidebar = .mcp(pending)
                    logger.info("[TOOLLIB] Opened preselected on MCP source \(pending) from the Tools sidebar.")
                }
                if !ToolLibraryNavigationState.shared.searchText.isEmpty {
                    isSearchExpanded = true
                }
                logger.info("""
                    [TOOLLIB] Opened \(routeProfileID != nil ? "pinned to a route profile" : "unpinned"); \
                    configuring '\(profileLabel)' — tool enablement \
                    controls \(canConfigureTools ? "shown" : "HIDDEN, nothing to write to").
                    """)
            }
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
            IslandSearchToggleButton(isExpanded: $isSearchExpanded)

            // Selection mode and Select All write tool enablement into a profile. With none
            // targeted they would be controls with nowhere to write, so they are hidden
            // rather than shown disabled — the profile selector below is the way back.
            if canConfigureTools {
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
                    isActive: isShowingAllToolsDropdown || allToolsSelected,
                    help: "Configure all visible tools",
                    accessibilityLabel: "All tools execution mode"
                ) {
                    isShowingAllToolsDropdown.toggle()
                }
                .popover(isPresented: $isShowingAllToolsDropdown, arrowEdge: .bottom) {
                    allToolsDropdownContent
                        .frame(width: 290)
                        .padding(8)
                }
            }
        }
    }

    // MARK: - Profile Selector

    /// Always present, never conditional.
    ///
    /// A selector that only appeared when nothing was chosen would be a dead control the
    /// instant you chose something. Kept permanent, it doubles as the way to SWITCH profiles
    /// without leaving — which is the common case when pointing several agents at one new
    /// MCP server.
    ///
    /// Disabled (not hidden) when the route pinned a profile: arriving from a profile's own
    /// config is an explicit statement about what you are configuring, and silently letting
    /// it be changed there would write to a profile the user did not open.
    @ViewBuilder
    private var profileSelector: some View {
        let pinned = routeProfileID != nil

        Menu {
            if !pinned {
                Button("No profile — browse only") {
                    rememberedProfileIDRaw = ""
                    logger.info("[TOOLLIB] Profile target cleared; tool enablement controls hidden.")
                }
                Divider()
            }
            // Only agent and code profiles carry a tools list — `writeTools` returns the
            // details unchanged for anything else, so offering those here would produce a
            // selection that silently saves nothing.
            ForEach(toolCapableProfiles, id: \.id) { profile in
                Button {
                    rememberedProfileIDRaw = profile.id.uuidString
                    logger.info("[TOOLLIB] Now configuring tools for '\(profile.displayName)' (\(profile.id)).")
                } label: {
                    if profile.id == profileID {
                        Label(profile.displayName, systemImage: "checkmark")
                    } else {
                        Label(profile.displayName, systemImage: profile.profileType.iconName)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let iconName = profileIconName {
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(canConfigureTools ? theme.accentColor : theme.secondaryText)
                }
                Text(profileLabel)
                    .font(.caption)
                    .foregroundColor(canConfigureTools ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)
                if !pinned {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(canConfigureTools ? theme.accentColor : theme.secondaryText)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(canConfigureTools ? theme.accentColor.opacity(0.12) : theme.surfaceOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(canConfigureTools ? theme.accentColor.opacity(0.4) : theme.surfaceOverlayStrong, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(pinned)
        .help(isCodeProfile
              ? Self.codeScopeHelp(projectFolder: codeSessionManager.projectPath)
              : (pinned
                 ? "Configuring \(currentProfile?.displayName ?? "this profile"). Open the Tools tab to switch."
                 : (canConfigureTools
                    ? "Tools you enable apply to this profile. Click to switch."
                    : "Choose a profile to enable tools for it.")))
    }

    /// Relevant SF Symbol for the active profile type (e.g. `</>` for Code, `cpu` for Agent).
    private var profileIconName: String? {
        guard let profile = currentProfile else { return nil }
        return profile.profileType.iconName
    }

    /// Which project a Code tool change just went to — the Library edits the one Code profile,
    /// and the open project captures it from there.
    private func logCodeScopeOfSave() {
        guard isCodeProfile else { return }
        if let folder = codeSessionManager.projectPath {
            logger.info("[TOOLLIB] Code tools saved for project '\(folder.lastPathComponent)'. CONSEQUENCE: that project keeps them; other projects are unaffected.")
        } else {
            logger.info("[TOOLLIB] Code tools saved with no project selected. CONSEQUENCE: they go to the next project opened from the welcome screen; a project with its own remembered tools replaces them.")
        }
    }

    private var profileLabel: String {
        guard let profile = currentProfile else { return "No profile selected" }
        guard isCodeProfile else { return profile.displayName }
        return Self.codeScopeLabel(profileName: profile.displayName, projectFolder: codeSessionManager.projectPath)
    }

    /// "Code Session · <project>" — the Code profile's tools are saved per project (2026-09-24),
    /// so a bare "Code Session" left the user guessing which project a change would land in.
    static func codeScopeLabel(profileName: String, projectFolder: URL?) -> String {
        "\(profileName) · \(projectFolder?.lastPathComponent ?? String(localized: "No Project Selected"))"
    }

    static func codeScopeHelp(projectFolder: URL?) -> String {
        if let projectFolder {
            return String(localized: "Tools you enable here apply to the project “\(projectFolder.lastPathComponent)” only. Each project keeps its own.")
        }
        return String(localized: "No project is selected. Tools you enable here go to the next project you open.")
    }

    /// Profiles that actually have a tools list to write into.
    ///
    /// ⚠️ `sharedProfiles` — this is a user-facing chooser. A workflow node's own row is an agent,
    /// so the unfiltered list offered every node's private configuration for tool editing here,
    /// outside the workflow that scopes it. `currentProfile` below stays on the unfiltered list
    /// because it resolves BY ID and must keep finding an owned row.
    private var toolCapableProfiles: [BackendProfileModel] {
        profileService.sharedProfiles.filter { profile in
            switch profile.details {
            case .agent, .code: return true
            default:            return false
            }
        }
    }

    // MARK: - Current Profile Lookup

    private var currentProfile: BackendProfileModel? {
        profileService.profiles.first(where: { $0.id == profileID })
    }

    /// True when the active profile is a Code profile (`.code(AgentConfig)`).
    private var isCodeProfile: Bool {
        guard let profile = currentProfile else { return false }
        if case .code = profile.details { return true }
        return false
    }

    /// Core tools that cannot be disabled for a Code profile.
    private var lockedToolNames: Set<String> {
        isCodeProfile ? CodeToolPreset.lockedToolNames : []
    }

    /// Tool names to hide from the Tool Library UI. For Code profiles, this is only
    /// superseded tools (if any). Preset tools are now shown and locked.
    private var hiddenToolNames: Set<String> {
        isCodeProfile ? CodeToolPreset.hiddenToolNames : []
    }

    /// Reads the tools list from either an `.agent` or `.code` profile detail case.
    private func readTools(from details: ProfileDetails) -> [Tool] {
        switch details {
        case .agent(let config): return config.tools
        case .code(let config):
            return CodeSessionManager.mergePresetTools(preset: CodeToolPreset.defaultTools, existing: config.tools)
        default: return []
        }
    }

    /// Writes a tools list back into either an `.agent` or `.code` profile detail case.

    /// Surfaces save advisories that are ABOUT tools on the screen where tools are edited.
    ///
    /// ⚠️ register B16. Filtered rather than shown wholesale: this screen can also produce the
    /// endpoint-transport and missing-instructions advisories, and neither is actionable from a
    /// tool list — showing them here would be noise that trains the user to ignore the one warning
    /// that matters. The profile editors' banner (A34) remains the surface for the rest.
    private func showToolAdvisories(_ advisories: [ProfileValidationError]) {
        for advisory in advisories where advisory.field == "modelCapabilities" {
            toastManager.show(advisory.message, style: .warning)
        }
    }

    private func writeTools(_ tools: [Tool], into details: ProfileDetails) -> ProfileDetails {
        switch details {
        case .agent(var config):
            config.tools = tools
            return .agent(config)
        case .code(var config):
            config.tools = CodeSessionManager.mergePresetTools(preset: CodeToolPreset.defaultTools, existing: tools)
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

    // MARK: - All Tools Bulk Configuration

    private var allToolsState: ToolControlState? {
        let tools = currentTools
        let rows = currentDisplayedRows()
        guard !rows.isEmpty else { return .disabled }

        let enabledRows = rows.filter { row in
            tools.contains(where: { $0.name == row.definition.name && $0.sourceId == row.source.id })
        }

        let disableableRows = rows.filter { !lockedToolNames.contains($0.definition.name) }
        let enabledDisableableRows = disableableRows.filter { row in
            tools.contains(where: { $0.name == row.definition.name && $0.sourceId == row.source.id })
        }

        if !disableableRows.isEmpty && enabledDisableableRows.isEmpty {
            return .disabled
        }

        if enabledRows.count == rows.count {
            let allAuto = rows.allSatisfy { row in
                guard let t = tools.first(where: { $0.name == row.definition.name && $0.sourceId == row.source.id }) else { return false }
                return !t.requiresConfirmation
            }
            if allAuto { return .auto }

            let allAsk = rows.allSatisfy { row in
                guard let t = tools.first(where: { $0.name == row.definition.name && $0.sourceId == row.source.id }) else { return false }
                return t.requiresConfirmation
            }
            if allAsk { return .ask }
        }

        return nil
    }

    private var allToolsDropdownContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ALL VISIBLE TOOLS")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(theme.secondaryText.opacity(0.75))
                .tracking(0.6)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 2)

            StateDropdownOptionRow(
                state: .auto,
                isSelected: allToolsState == .auto,
                customTitle: "Auto Run All",
                customSubtitle: "Set all visible tools to run automatically",
                theme: theme,
                onSelect: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        setAllToolsState(.auto)
                    }
                    isShowingAllToolsDropdown = false
                }
            )

            StateDropdownOptionRow(
                state: .ask,
                isSelected: allToolsState == .ask,
                customTitle: "Ask First All",
                customSubtitle: "Set all visible tools to require confirmation",
                theme: theme,
                onSelect: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        setAllToolsState(.ask)
                    }
                    isShowingAllToolsDropdown = false
                }
            )

            let rows = currentDisplayedRows()
            let disableableRows = rows.filter { !lockedToolNames.contains($0.definition.name) }
            let allLocked = !rows.isEmpty && disableableRows.isEmpty

            StateDropdownOptionRow(
                state: .disabled,
                isSelected: allToolsState == .disabled,
                isDisabled: allLocked,
                disabledReason: allLocked ? "All visible tools are core tools required for Code Session" : nil,
                customTitle: "Disable All",
                customSubtitle: lockedToolNames.isEmpty
                    ? "Turn off all visible tools"
                    : "Turn off visible tools (core tools remain protected)",
                theme: theme,
                onSelect: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        setAllToolsState(.disabled)
                    }
                    isShowingAllToolsDropdown = false
                }
            )

            if isSelectionMode {
                Divider()
                    .padding(.vertical, 4)

                let allChecked = !rows.isEmpty && rows.allSatisfy { selectedToolIDs.contains($0.id) }

                Button {
                    if allChecked {
                        selectedToolIDs.removeAll()
                    } else {
                        selectedToolIDs = Set(rows.map(\.id))
                    }
                    isShowingAllToolsDropdown = false
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.accentColor.opacity(0.12))
                                .frame(width: 26, height: 26)

                            Image(systemName: allChecked ? "checklist.unchecked" : "checklist.checked")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(theme.accentColor)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(allChecked ? "Deselect All Checkboxes" : "Select All Checkboxes (\(rows.count))")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.primaryText)

                            Text(allChecked ? "Clear all checkboxes" : "Check all visible tools for bulk action")
                                .font(.system(size: 10))
                                .foregroundColor(theme.secondaryText)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func setAllToolsState(_ targetState: ToolControlState) {
        guard let profile = currentProfile else { return }
        var tools = readTools(from: profile.details)
        let instructions = currentInstructions
        let rows = currentDisplayedRows()

        switch targetState {
        case .auto:
            for row in rows {
                if let idx = tools.firstIndex(where: { $0.name == row.definition.name && $0.sourceId == row.source.id }) {
                    tools[idx].requiresConfirmation = false
                    tools[idx].isEnabled = true
                } else {
                    tools.append(Tool(
                        name: row.definition.name,
                        description: row.definition.description,
                        isEnabled: true,
                        requiresConfirmation: false,
                        sourceId: row.source.id,
                        parameters: row.definition.parameters
                    ))
                }
            }

        case .ask:
            for row in rows {
                if let idx = tools.firstIndex(where: { $0.name == row.definition.name && $0.sourceId == row.source.id }) {
                    tools[idx].requiresConfirmation = true
                    tools[idx].isEnabled = true
                } else {
                    tools.append(Tool(
                        name: row.definition.name,
                        description: row.definition.description,
                        isEnabled: true,
                        requiresConfirmation: true,
                        sourceId: row.source.id,
                        parameters: row.definition.parameters
                    ))
                }
            }

        case .disabled:
            for row in rows {
                // Skip tools referenced in instructions
                if instructions.contains("`\(row.definition.name)`") {
                    continue
                }
                // Skip core tools required for Code Session
                if lockedToolNames.contains(row.definition.name) {
                    continue
                }
                tools.removeAll { $0.name == row.definition.name && $0.sourceId == row.source.id }
            }
        }

        // Sync to edit buffer
        if let buffer = profileService.editBuffer, buffer.draft.id == profileID {
            buffer.draft.details = writeTools(tools, into: buffer.draft.details)
        }
        // Persist
        if let idx = profileService.profiles.firstIndex(where: { $0.id == profileID }) {
            profileService.profiles[idx].details = writeTools(tools, into: profileService.profiles[idx].details)
            do {
                let advisories = try profileService.saveProfile(profileService.profiles[idx])
                showToolAdvisories(advisories)
                profileService.rebaseEditBuffer(to: profileService.profiles[idx])
                logCodeScopeOfSave()
            } catch {
                logger.error(
                    "[TOOLS] Failed to persist tool selection for profile \(profileID): \(error). "
                    + "CONSEQUENCE: the Tool Library shows the new selection but it was NOT written "
                    + "to disk — it reverts on relaunch."
                )
            }
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
            // Built-in only: this row sits under the Build-In section, so counting MCP tools
            // here would promise rows the click does not deliver.
            for source in toolStore.sources where source.type == .local {
                for tool in source.tools where matchesSearch(tool) && !hidden.contains(tool.name) {
                    rows.append(ToolTableRow(source: source, definition: tool))
                }
            }
        case .marketplace, .none:
            // The registry browser renders its own grid; there are no installed rows to list.
            break
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
        let query = ToolLibraryNavigationState.shared.searchText
        return query.isEmpty ||
            tool.name.localizedCaseInsensitiveContains(query) ||
            tool.description.localizedCaseInsensitiveContains(query)
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
                // ⚠️ Same as above — the binding's setter has already mutated both the edit buffer
                // and the service array, so a swallowed throw desynchronises the UI from disk.
                do {
                    // register B16 — same surfacing as the bulk path above.
                    let advisories = try self.profileService.saveProfile(self.profileService.profiles[idx])
                    self.showToolAdvisories(advisories)
                    // Same re-baseline as the bulk path above — see the note there.
                    self.profileService.rebaseEditBuffer(to: self.profileService.profiles[idx])
                    self.logCodeScopeOfSave()
                } catch {
                    logger.error(
                        "[TOOLS] Failed to persist tool binding for profile \(self.profileID): \(error). "
                        + "CONSEQUENCE: the UI shows the new tool set but it was NOT written to disk — "
                        + "it reverts on relaunch."
                    )
                }
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

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
    // register B16 — needed to surface the tool-capability advisory this screen was discarding.
    @Environment(ToastManager.self) private var toastManager
    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme

    @State private var searchText = ""
    @State private var isSelectionMode = false
    @State private var selectedToolIDs: Set<String> = []

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
                    IslandSearchField(
                        text: Binding(get: { ToolLibraryNavigationState.shared.searchText },
                                     set: { ToolLibraryNavigationState.shared.searchText = $0 }),
                        // One search field for the whole library; what it searches depends on
                        // where you are, so the placeholder has to say which.
                        placeholder: ToolLibraryNavigationState.shared.selectedSidebar == .marketplace
                            ? "Search the MCP registry..."
                            : "Search tools...",
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
                    isSelectionMode: $isSelectionMode,
                    selectedToolIDs: $selectedToolIDs,
                    hiddenToolNames: hiddenToolNames,
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
                logger.info("""
                    [TOOLLIB] Opened \(routeProfileID != nil ? "pinned to a route profile" : "unpinned"); \
                    configuring '\(currentProfile?.displayName ?? "no profile")' — tool enablement \
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
                isActive: allToolsSelected,
                help: allToolsSelected ? "Deselect all tools" : "Select all tools",
                accessibilityLabel: allToolsSelected ? "Deselect all tools" : "Select all tools"
            ) {
                toggleSelectAll()
            }
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
                        Text(profile.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: canConfigureTools ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.questionmark")
                    .font(.system(size: 11))
                    .foregroundColor(canConfigureTools ? theme.accentColor : theme.secondaryText)
                Text(currentProfile?.displayName ?? "No profile selected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(canConfigureTools ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)
                if !pinned {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(canConfigureTools ? theme.accentColor.opacity(0.10) : theme.surfaceOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(canConfigureTools ? theme.accentColor.opacity(0.28) : theme.secondaryText.opacity(0.18), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(pinned)
        .help(pinned
              ? "Configuring \(currentProfile?.displayName ?? "this profile"). Open the Tools tab to switch."
              : (canConfigureTools
                 ? "Tools you enable apply to this profile. Click to switch."
                 : "Choose a profile to enable tools for it."))
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
            // Select all in current view — always Ask mode.
            //
            // This used to read the tool's `readOnlyHint` annotation and, when true,
            // enable the tool with `requiresConfirmation: false`. That annotation is
            // supplied BY THE MCP SERVER, so a third party was choosing this app's
            // security posture — and choosing the permissive side. A server declaring
            // `readOnlyHint: true` on a destructive tool got silent auto-run.
            //
            // Annotations describe, they never enforce: they render as badges in the
            // Tool Library (ToolLibraryView) and nothing more. `requiresConfirmation`
            // is the user's setting alone.
            for row in rows {
                if !tools.contains(where: { $0.name == row.definition.name && $0.sourceId == row.source.id }) {
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
        }

        // Sync to edit buffer
        if let buffer = profileService.editBuffer, buffer.draft.id == profileID {
            buffer.draft.details = writeTools(tools, into: buffer.draft.details)
        }
        // Persist
        if let idx = profileService.profiles.firstIndex(where: { $0.id == profileID }) {
            profileService.profiles[idx].details = writeTools(tools, into: profileService.profiles[idx].details)
            // ⚠️ Was a bare `try?`. The in-memory arrays above are ALREADY mutated, so a throw here
            // leaves the Tool Library showing the new tool set while disk keeps the old one — the
            // change survives until relaunch and then silently reverts, with no toast and (before
            // this) no log line either. This was the only one of the affected save paths that
            // produced zero diagnostic output.
            do {
                // ⚠️ register B16 — the advisories are SHOWN here, not discarded. `ProfileValidator`
                // emits "the selected model does not support tool calling" for local providers, and
                // this screen is where the user is enabling tools: every save recomputed that
                // warning and threw it away, so someone could tick ten tools onto a model that
                // cannot call any of them and be told nothing. A34's banner lives in the three
                // detail editors — the one screen the user is NOT on at this moment.
                let advisories = try profileService.saveProfile(profileService.profiles[idx])
                showToolAdvisories(advisories)
                // ⚠️ Re-baseline ONLY on success, and only onto what was actually written. Without
                // this the detail editor kept an `original` describing the pre-change tool list, so
                // it showed Save/Revert pills for an edit the user never made — and Revert restored
                // that stale list while disk and every send kept the new one.
                profileService.rebaseEditBuffer(to: profileService.profiles[idx])
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
                // ⚠️ Same as above — the binding's setter has already mutated both the edit buffer
                // and the service array, so a swallowed throw desynchronises the UI from disk.
                do {
                    // register B16 — same surfacing as the bulk path above.
                    let advisories = try self.profileService.saveProfile(self.profileService.profiles[idx])
                    self.showToolAdvisories(advisories)
                    // Same re-baseline as the bulk path above — see the note there.
                    self.profileService.rebaseEditBuffer(to: self.profileService.profiles[idx])
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

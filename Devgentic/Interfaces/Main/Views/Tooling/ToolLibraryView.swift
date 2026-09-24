// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

private let logger = DGLogger(category: "ToolLibraryView")

// MARK: - Navigation State

enum SidebarSelection: Hashable {
    case all
    case favorites
    case localCategory(String)
    case mcp(UUID)
    /// The MCP registry browser. A selection rather than a mode so the pane's rows and the
    /// content column stay driven by one value.
    case marketplace
}

// MARK: - Built-in Tool Category Mapping

struct BuiltInToolCategory: Identifiable {
    var id: String { name }
    let name: String
    let icon: String
    let rawCategories: Set<String>

    /// Sidebar groups, and the tool `category` values each one gathers.
    ///
    /// Four names were removed on 2026-08-01 — "Advanced Finder & File Management",
    /// "Device & Peripheral Control", "Deep Context Awareness" and "Communication & Mail" — left
    /// behind by tool files deleted in the 2026-07-31 catalogue cleanup. They were inert (a group
    /// with no tools is dropped by `compactMap`) but they described a shape the app no longer has,
    /// which is the kind of thing a reader trusts. `ToolCategoryGroupingTests` now pins BOTH
    /// directions: every name here gathers at least one real tool, and every tool's category is
    /// gathered by some group — the second being the one that matters, since a tool whose category
    /// belongs to no group gets no sidebar row.
    static let allGroups: [BuiltInToolCategory] = [
        .init(name: "File System", icon: "folder.fill", rawCategories: ["File System"]),
        .init(name: "System & Shell", icon: "terminal.fill", rawCategories: ["System & Shell", "System Toggles", "System State", "System Automation"]),
        .init(name: "Coding & Dev Tools", icon: "chevron.left.forwardslash.chevron.right", rawCategories: ["Coding Assistant", "Developer & Diagnostics"]),
        .init(name: "Vision & UI", icon: "eye.fill", rawCategories: ["Vision & UI", "Workspace Management"]),
        .init(name: "macOS Utilities", icon: "gearshape.fill", rawCategories: ["macOS Utilities"]),
        .init(name: "Network & Web", icon: "globe", rawCategories: ["Network & Connectivity", "Native Browser Automation"]),
        .init(name: "Communication & PIM", icon: "person.crop.rectangle.stack.fill", rawCategories: ["Personal Information"]),
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
    /// Shared with the pane — see `ToolLibraryNavigationState`.
    private var nav: ToolLibraryNavigationState { .shared }
    private var searchText: String { nav.searchText }
    private var selectedSidebar: SidebarSelection? { nav.selectedSidebar }
    @Binding var isSelectionMode: Bool
    @Binding var selectedToolIDs: Set<String>

    /// Tool names to hide from the library. For Code profiles, this is the full
    /// CodeToolPreset — the user never sees those rows, so they can't disable or
    /// toggle them. Empty for other profile types.
    var hiddenToolNames: Set<String> = []

    /// False when no profile is targeted. Everything that writes tool enablement — per-row
    /// toggles, the selection circles, bulk actions — is hidden rather than disabled: a
    /// control that looks live with nowhere to write is worse than an absent one.
    var canConfigureTools: Bool = true

    /// Supplied by the container so the profile picker can live in this view's header
    /// without this view knowing anything about profiles.
    var profileSelector: (() -> AnyView)? = nil

    @Environment(MainViewRouter.self) private var router
    private var toolStore: UnifiedToolStore { UnifiedToolStore.shared }
    @Environment(\.appTheme) private var theme

    /// Source the user just clicked "Report Issue..." on. Drives the bug-
    /// report sheet's `.sheet(item:)` binding.
    @State private var bugReportSource: ToolSource? = nil

    /// Source awaiting delete confirmation. Removing a server purges its Keychain secrets
    /// and revokes its OAuth grant, so it is confirmed rather than done on one click.
    @State private var pendingDeletion: ToolSource? = nil


    var body: some View {
        // Navigation (categories, MCP servers, Installed/Discover, Discover facets) lives in
        // the SIDEBAR PANE now — see `ToolNavigationPane`. This view is purely the content
        // column. Previously both were on screen at once, each listing MCP servers.
        Group {
            // Driven by the SELECTION, not a separate mode: Marketplace is a row in the pane
            // like any other, so one value decides what both halves show.
            if nav.selectedSidebar == .marketplace {
                MCPDiscoverView { plan, values in
                    addFromRegistry(plan: plan, values: values)
                }
            } else {
                toolDetailView
            }
        }
        .frame(maxWidth: .infinity)
        .sheet(item: $bugReportSource) { source in
            MCPBugReportSheet(source: source)
        }
        .onAppear { publishFavoriteCount() }
        .onChange(of: configuredTools.count) { _, _ in publishFavoriteCount() }
    }

    /// The pane draws the Pinned section but has no access to the profile's tool list, so
    /// the count is published from here rather than read there.
    private func publishFavoriteCount() {
        ToolLibraryFavoritesBridge.shared.count = favoriteCount
    }


    // MARK: - Registry adds

    /// Creates a server from a reviewed registry plan, then connects it.
    ///
    /// The tool list is intentionally EMPTY at save time: we have not talked to the server
    /// yet, and inventing tools from registry metadata would put entries in the library that
    /// may not exist. The connect that follows discovers the real list and persists it — and
    /// if it fails, the server is still saved, visible, and editable rather than silently
    /// discarded along with the credentials the user just typed.
    private func addFromRegistry(plan: MCPRegistryInstallPlan, values: [String: String]) {
        guard let definition = plan.makeServerDefinition() else {
            logger.error("""
                [MCP-DISCOVER] Cannot add '\(plan.server.name)': the plan produced no usable \
                ServerDefinition. Nothing was saved.
                """)
            return
        }

        // Uniquify against existing names — the registry has no idea what the user already
        // has, and a collision would be rejected by the store with no explanation here.
        var name = plan.server.displayName
        if toolStore.isServerNameTaken(name) {
            var suffix = 2
            while toolStore.isServerNameTaken("\(name) \(suffix)") { suffix += 1 }
            let uniquified = "\(name) \(suffix)"
            logger.info("[MCP-DISCOVER] '\(name)' is taken; saving as '\(uniquified)'.")
            name = uniquified
        }

        let secrets = MCPRuntimeSecrets(env: values.filter { !$0.value.isEmpty })

        guard let sourceID = toolStore.addTool(
            serverName: name,
            serverDefinition: definition,
            secrets: secrets,
            newTools: []
        ) else {
            logger.error("""
                [MCP-DISCOVER] Store REFUSED to add '\(name)' from the registry. The user's \
                supplied values were not persisted; they will need to retry.
                """)
            return
        }

        logger.info("""
            [MCP-DISCOVER] Added '\(name)' (\(sourceID)) from registry entry \
            '\(plan.server.name)' — \(plan.server.isRemote ? "remote" : "local"), \
            \(values.count) value(s) stored in Keychain. Connecting now to discover its tools.
            """)

        // Mark connecting BEFORE switching views. `performConnect` sets this too, but only
        // after an actor hop — so without it the freshly-selected server renders for a frame
        // as "Not connected", which reads as a failure rather than work in progress.
        MCPClientService.shared.connectionStates[sourceID] = .connecting

        nav.section = .mcp
        nav.selectedSidebar = .mcp(sourceID)

        Task {
            await MCPConnectionCoordinator.shared.connectIfNeeded(sourceID: sourceID)
        }
    }

    private func isConnected(_ source: ToolSource) -> Bool {
        MCPClientService.shared.connectionStates[source.id]?.isActive ?? false
    }

    // MARK: - Detail (Tool List)

    @ViewBuilder
    private var toolDetailView: some View {
        if displayedRows.isEmpty {
            // An MCP server with no rows is almost never "nothing here" — it is connecting,
            // or it failed, or the user disabled it. Falling through to the library's generic
            // empty state showed "No Tools Found / Add MCP Server" for a server that was
            // mid-handshake, so adding a server looked like it had done nothing until the
            // user navigated away and back.
            if case .mcp(let sourceID) = selectedSidebar,
               let source = toolStore.sources.first(where: { $0.id == sourceID }) {
                mcpServerStateView(source)
            } else {
                emptyStateView
            }
        } else {
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        // Title / Count summary header
                        HStack(spacing: 10) {
                            Text(currentSelectionTitle)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(theme.secondaryText.opacity(0.8))
                                .textCase(.uppercase)
                                .tracking(0.5)

                            Spacer()

                            // Which profile these toggles write to. Permanent, so it also
                            // serves as the profile SWITCHER — the common case when pointing
                            // several agents at one newly-added MCP server.
                            if let profileSelector {
                                profileSelector()
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 14)
                        .padding(.bottom, 2)
                        
                        ForEach(displayedRows) { row in
                            toolRow(row)
                        }
                    }
                    .padding(.horizontal, ViewLayout.containerPadding)
                    .padding(.bottom, isSelectionMode && !selectedToolIDs.isEmpty ? 80 : ViewLayout.containerPadding)
                    .frame(maxWidth: 1000)
                    .frame(maxWidth: .infinity)
                }

                // Bulk action bar
                if isSelectionMode && !selectedToolIDs.isEmpty {
                    bulkActionBar
                        .frame(maxWidth: 1000)
                        .frame(maxWidth: .infinity)
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
            // With no profile targeted there is nowhere to write enablement, so the row's
            // selection circle and enable pill are suppressed entirely.
            isSelectionMode: isSelectionMode && canConfigureTools,
            canConfigureTools: canConfigureTools,
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
        case .marketplace:
            return "Marketplace"
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
        case .marketplace, .none:
            // The registry browser draws its own grid — no installed rows to list.
            break
        case .all:
            // Built-in only; this row lives under the Build-In section.
            for source in toolStore.sources where source.type == .local {
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

    /// Explains WHY a selected MCP server is showing no tools, rather than implying there is
    /// nothing to show. Each state names its own next action.
    @ViewBuilder
    private func mcpServerStateView(_ source: ToolSource) -> some View {
        let state = MCPClientService.shared.connectionStates[source.id] ?? .disconnected

        VStack(spacing: 14) {
            switch state {
            case .connecting:
                ProgressView().controlSize(.large)
                stateTitle("Connecting to \(source.serverName)…")
                stateDetail(source.serverDefinition?.command != nil
                    ? "Starting the server and discovering its tools. A first run may download the package, which can take a minute."
                    : "Opening a connection and discovering its tools.")

            case .reconnecting(let attempt):
                ProgressView().controlSize(.large)
                stateTitle("Reconnecting to \(source.serverName)…")
                stateDetail("Attempt \(attempt). The previous connection dropped.")

            case .error(let message):
                stateIcon("exclamationmark.triangle", tint: .orange)
                stateTitle("Couldn't connect to \(source.serverName)")
                // Selectable: this is the string a user pastes into a search or a bug report.
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.09)))

                HStack(spacing: 8) {
                    Button("Retry") {
                        Task { await MCPConnectionCoordinator.shared.reconnect(sourceID: source.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Edit Configuration") {
                        router.navigate(to: .editMCPServer(sourceID: source.id))
                    }
                    .buttonStyle(.bordered)
                }

            case .disconnected where !source.isEnabled:
                stateIcon("pause.circle", tint: theme.secondaryText)
                stateTitle("\(source.serverName) is disabled")
                stateDetail("Its configuration and saved credentials are kept. Enable it to make its tools available again.")
                Button("Enable Server") {
                    toolStore.setEnabled(true, sourceID: source.id)
                }
                .buttonStyle(.borderedProminent)

            case .disconnected:
                stateIcon("bolt.horizontal.circle", tint: theme.secondaryText)
                stateTitle("Not connected")
                stateDetail("This server hasn't been connected yet in this session.")
                Button("Connect") {
                    Task { await MCPConnectionCoordinator.shared.connectIfNeeded(sourceID: source.id) }
                }
                .buttonStyle(.borderedProminent)

            case .connected:
                // Connected and genuinely empty. Rare, but real: a resources-only server whose
                // capabilities we could not turn into anything callable.
                stateIcon("puzzlepiece.extension", tint: theme.secondaryText)
                stateTitle("\(source.serverName) exposes no tools")
                stateDetail("The server connected but advertised nothing this app can call. Rescan if you expect that to have changed.")
                Button("Rescan Tools") {
                    Task { await MCPConnectionCoordinator.shared.rescan(sourceID: source.id) }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func stateIcon(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 40))
            .foregroundColor(tint.opacity(0.7))
    }

    private func stateTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(theme.primaryText)
            .multilineTextAlignment(.center)
    }

    private func stateDetail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 380)
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
    /// False when no profile is targeted — the enable/Ask pill is hidden rather than shown
    /// inert, because a control that looks live with nowhere to write is worse than none.
    var canConfigureTools: Bool = true
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
                    
                    // Hidden with no profile targeted: this control writes enablement into a
                    // profile's tool list, and there is nothing to write to.
                    if canConfigureTools {
                        ToolStateControl(
                            configuredTools: $configuredTools,
                            source: row.source,
                            definition: row.definition,
                            instructions: instructions
                        )
                    }
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

                // What survives when this tool's result is larger than the model's room. Nil =
                // follow the global setting in the context gauge.
                VStack(alignment: .leading, spacing: 6) {
                    Label("If the result doesn't fit, keep", systemImage: "scissors")
                        .font(theme.fontSubheadline)
                    Picker("", selection: Binding(
                        get: { configuredTools[idx].cutStrategy?.rawValue ?? "" },
                        set: { configuredTools[idx].cutStrategy = ContextCutStrategy(rawValue: $0) }
                    )) {
                        Text("Default (\(ContextCutStrategy.globalDefault.label))").tag("")
                        ForEach(ContextCutStrategy.allCases, id: \.rawValue) { strategy in
                            Text(strategy.label).tag(strategy.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }

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

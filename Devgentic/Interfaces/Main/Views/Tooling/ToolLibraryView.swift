// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolLibraryView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

private let logger = DGLogger(category: "ToolLibraryView")

// MARK: - Navigation State

/// Which item is selected in the tool library sidebar: all tools, favorites, a local category, an MCP server
/// or the registry.
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
    /// A group with no tools is dropped; a tool whose category belongs to no group gets no sidebar row.
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

    var displayTitle: String {
        definition.title ?? definition.name.toTitleCase()
    }
}

extension ToolDefinition {
    /// Resolves the risk tier for this tool based on its capabilities, annotations, and provenance.
    func riskTier(in source: ToolSource? = nil) -> HITLRiskTier {
        if ToolCapability.executesArbitraryCode(name) { return .destructive }
        if annotations?.destructiveHint == true { return .destructive }
        if annotations?.readOnlyHint == true { return .safe }
        if let source = source, source.type == .mcp {
            return .moderate
        }
        return HITLRiskTier.classify(toolName: name)
    }
}

extension ToolTableRow {
    var riskTier: HITLRiskTier {
        definition.riskTier(in: source)
    }
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

    /// Tool names to hide from the library. Empty for other profile types.
    var hiddenToolNames: Set<String> = []

    /// Core tools that cannot be disabled (e.g. Code preset tools when viewing a Code profile).
    var lockedToolNames: Set<String> = []

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

    /// Tools a bulk "enable" skipped because they cannot work until set up, with the reason.
    @State private var skippedForSetup: [String] = []


    var body: some View {
        // Navigation (categories, MCP servers, Installed/Discover, Discover facets) lives in the sidebar pane
        // (`ToolNavigationPane`); this view is only the content column.
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
        .alert("Setup needed", isPresented: Binding(
            get: { !skippedForSetup.isEmpty },
            set: { if !$0 { skippedForSetup = [] } }
        )) {
            Button("Open Settings") {
                if let pane = skippedForSetup.compactMap({ NativeToolCatalog.setupSettings(for: $0) }).first {
                    router.navigateToSettings(pane)
                }
                skippedForSetup = []
            }
            Button("OK", role: .cancel) { skippedForSetup = [] }
        } message: {
            Text("Not enabled because they need setup first: \(skippedForSetup.joined(separator: ", ")).")
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
    /// The tool list is empty at save time, since tools invented from registry metadata may not exist; the connect that
    /// follows discovers and persists the real list. If it fails, the server and the typed credentials are still saved.
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

        // Mark connecting BEFORE switching views: `performConnect` sets this only after an actor hop, so the freshly-selected
        // server would render as "Not connected" for a frame.
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
            // An MCP server with no rows is usually connecting, failed or disabled, not empty; the generic empty state would
            // show "No Tools Found" for a server mid-handshake.
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

                            // Which profile these toggles write to; always visible, so it doubles as the profile switcher (e.g. when pointing
                            // several agents at one newly-added MCP server).
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
                HStack(spacing: 5) {
                    Image(systemName: "lock.shield.fill")
                    Text("Ask First")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.warningForegroundColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.warningColor)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            Button { bulkSetState(.auto) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill")
                    Text("Auto Run")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.successColor)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            Button { bulkSetState(.disabled) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "xmark.circle")
                    Text("Disable")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.surfaceOverlay)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.dividerColor.opacity(0.4), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            Divider().frame(height: 16)

            Button { bulkToggleFavorite() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill")
                    Text("Favorite")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.isDark ? Color(hex: "#ffcc00") : Color(hex: "#9a6700"))
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.yellow.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.yellow.opacity(0.28), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
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
        var skipped: [String] = []

        for rowID in selectedToolIDs {
            guard let row = displayedRows.first(where: { $0.id == rowID }) else { continue }
            let name = row.definition.name
            let sourceId = row.source.id

            // A tool that cannot work yet is never enabled in bulk; it is reported instead.
            if state != .disabled, sourceId == ToolSource.builtInSourceID,
               NativeToolCatalog.setupBlocker(for: name) != nil,
               !tools.contains(where: { $0.name == name && $0.sourceId == sourceId }) {
                skipped.append(name)
                continue
            }

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
                if lockedToolNames.contains(name) { continue }
                tools.removeAll { $0.name == name && $0.sourceId == sourceId }
            }
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            configuredTools = tools
            selectedToolIDs.removeAll()
        }
        skippedForSetup = skipped
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
        let isLocked = lockedToolNames.contains(row.definition.name)

        return ToolRowContent(
            row: row,
            isEnabled: isEnabled,
            isLocked: isLocked,
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

        // Sort: enabled tools first, then favorites, then alphabetical by display title
        let enabledKeys = Set(configuredTools.filter(\.isEnabled).map { "\($0.sourceId)-\($0.name)" })
        let favoriteKeys = Set(configuredTools.filter(\.isFavorite).map { "\($0.sourceId)-\($0.name)" })

        return rows.sorted { lhs, rhs in
            let lhsEnabled = enabledKeys.contains(lhs.id)
            let rhsEnabled = enabledKeys.contains(rhs.id)
            if lhsEnabled != rhsEnabled { return lhsEnabled }

            let lhsFav = favoriteKeys.contains(lhs.id)
            let rhsFav = favoriteKeys.contains(rhs.id)
            if lhsFav != rhsFav { return lhsFav }

            return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
        }
    }

    private func matchesSearch(_ tool: ToolDefinition) -> Bool {
        searchText.isEmpty ||
        tool.name.localizedCaseInsensitiveContains(searchText) ||
        tool.description.localizedCaseInsensitiveContains(searchText)
    }

    /// Explains why a selected MCP server is showing no tools, rather than implying there is nothing to show;
    /// each state names its own next action.
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
                    TactileButton(
                        title: "Retry",
                        icon: "arrow.clockwise",
                        variant: .primary,
                        size: .regular
                    ) {
                        Task { await MCPConnectionCoordinator.shared.reconnect(sourceID: source.id) }
                    }

                    TactileButton(
                        title: "Edit Configuration",
                        icon: "slider.horizontal.3",
                        variant: .secondary,
                        size: .regular
                    ) {
                        router.navigate(to: .editMCPServer(sourceID: source.id))
                    }
                }

            case .disconnected where !source.isEnabled:
                stateIcon("pause.circle", tint: theme.secondaryText)
                stateTitle("\(source.serverName) is disabled")
                stateDetail("Its configuration and saved credentials are kept. Enable it to make its tools available again.")
                TactileButton(
                    title: "Enable Server",
                    icon: "play.circle.fill",
                    variant: .primary,
                    size: .regular
                ) {
                    toolStore.setEnabled(true, sourceID: source.id)
                }

            case .disconnected:
                stateIcon("bolt.horizontal.circle", tint: theme.secondaryText)
                stateTitle("Not connected")
                stateDetail("This server hasn't been connected yet in this session.")
                TactileButton(
                    title: "Connect",
                    icon: "bolt.fill",
                    variant: .primary,
                    size: .regular
                ) {
                    Task { await MCPConnectionCoordinator.shared.connectIfNeeded(sourceID: source.id) }
                }

            case .connected:
                // Connected and genuinely empty. Rare, but real: a resources-only server whose
                // capabilities we could not turn into anything callable.
                stateIcon("puzzlepiece.extension", tint: theme.secondaryText)
                stateTitle("\(source.serverName) exposes no tools")
                stateDetail("The server connected but advertised nothing this app can call. Rescan if you expect that to have changed.")
                TactileButton(
                    title: "Rescan Tools",
                    icon: "arrow.clockwise",
                    variant: .secondary,
                    size: .regular
                ) {
                    Task { await MCPConnectionCoordinator.shared.rescan(sourceID: source.id) }
                }
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
                TactileButton(
                    title: "Add MCP Server",
                    icon: "plus",
                    variant: .primary,
                    size: .regular
                ) {
                    router.navigate(to: .addMCPServer)
                }
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
    var isLocked: Bool = false
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
    @State private var isShowingDetails = false
    @State private var isShowingSettings = false
    @State private var isShowingStateDropdown = false
    @Environment(MainViewRouter.self) private var router

    /// Why this built-in cannot work yet (no provider/key), or nil. Read live each render, but
    /// only a handful of catalogue entries declare one, so most rows cost nothing.
    private var setupBlocker: String? {
        row.source.id == ToolSource.builtInSourceID ? NativeToolCatalog.setupBlocker(for: row.definition.name) : nil
    }

    /// The pane behind this tool's "Setup" option; non-nil even when already configured.
    private var setupPane: SettingsCategory? {
        row.source.id == ToolSource.builtInSourceID ? NativeToolCatalog.setupSettings(for: row.definition.name) : nil
    }

    private var isCardActive: Bool {
        isHovered || isShowingDetails || isShowingSettings || isShowingStateDropdown
    }

    private var displayTitle: String {
        row.displayTitle
    }

    private var configuredTimeout: TimeInterval? {
        configuredTools.first(where: { $0.name == row.definition.name && $0.sourceId == row.source.id })?.timeout
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
                        
                        HStack(alignment: .center, spacing: 6) {
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

                            if isLocked {
                                HStack(spacing: 3) {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 7, weight: .bold))
                                    Text("CORE")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .foregroundColor(theme.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(theme.accentColor.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(theme.accentColor.opacity(0.25), lineWidth: 0.5)
                                )
                                .help("Required core tool for Code Session. Cannot be disabled.")
                            }

                            ToolRiskBadge(tier: row.riskTier)

                            if let blocker = setupBlocker {
                                HStack(spacing: 3) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 7, weight: .bold))
                                    Text("SETUP NEEDED")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .foregroundColor(theme.warningColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(theme.warningColor.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .help(blocker)
                            }

                            if let timeout = configuredTimeout {
                                ToolTimeoutBadge(timeout: timeout)
                            }
                        }
                    }
                }
                
                Spacer()
                
                // Right: Action controls (info, gear) + State dropdown button
                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 6) {
                        ToolDetailsButton(
                            definition: row.definition,
                            isShowingPopover: $isShowingDetails
                        )
                        .opacity(isCardActive ? 1.0 : 0.0)
                        .allowsHitTesting(isCardActive)
                        .animation(.easeInOut(duration: 0.15), value: isCardActive)
                        
                        if isEnabled {
                            ToolSettingsPopover(
                                configuredTools: $configuredTools,
                                source: row.source,
                                definition: row.definition,
                                isShowingPopover: $isShowingSettings
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: isEnabled)
                    
                    // Hidden with no profile targeted: this control writes enablement into a
                    // profile's tool list, and there is nothing to write to.
                    if canConfigureTools {
                        ToolStateControl(
                            configuredTools: $configuredTools,
                            source: row.source,
                            definition: row.definition,
                            instructions: instructions,
                            isLocked: isLocked,
                            setupBlocker: setupBlocker,
                            onOpenSetup: setupPane.map { pane in { router.navigateToSettings(pane) } },
                            isShowingDropdown: $isShowingStateDropdown
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
                    .lineLimit(isCardActive ? nil : 2) // Expand description on hover or while popover is open
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
                .fill(theme.secondaryBackground.opacity(isCardActive ? 0.95 : 0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isCardActive ? theme.accentColor.opacity(0.4) : theme.dividerColor.opacity(0.3), lineWidth: isCardActive ? 1.5 : 1)
        )
        .shadow(color: theme.shadowColor.opacity(isCardActive ? 0.12 : 0.04), radius: isCardActive ? 8 : 2, x: 0, y: isCardActive ? 4 : 1)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                isHovered = hovering
            }
        }
        .onChange(of: isShowingDetails) { _, newValue in
            if newValue {
                isShowingSettings = false
                isShowingStateDropdown = false
            }
        }
        .onChange(of: isShowingSettings) { _, newValue in
            if newValue {
                isShowingDetails = false
                isShowingStateDropdown = false
            }
        }
        .onChange(of: isShowingStateDropdown) { _, newValue in
            if newValue {
                isShowingDetails = false
                isShowingSettings = false
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
    @Binding var isShowingPopover: Bool
    @Environment(\.appTheme) private var theme
    @State private var isButtonHovered = false

    var body: some View {
        Button {
            isShowingPopover.toggle()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isShowingPopover
                            ? theme.accentColor.opacity(0.18)
                            : (isButtonHovered ? theme.surfaceOverlay : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                isShowingPopover
                                    ? theme.accentColor.opacity(0.5)
                                    : theme.dividerColor.opacity(isButtonHovered ? 0.45 : 0.25),
                                lineWidth: 0.8
                            )
                    )

                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(
                        isShowingPopover
                            ? theme.accentColor
                            : (isButtonHovered ? theme.primaryText : theme.secondaryText)
                    )
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hover in
            isButtonHovered = hover
        }
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


/// The three operational states for tool execution and HITL approval.
enum ToolControlState: String, CaseIterable, Sendable {
    case auto
    case ask
    case disabled

    var title: String {
        switch self {
        case .auto: return "Auto Run"
        case .ask: return "Ask First"
        case .disabled: return "Disabled"
        }
    }

    var subtitle: String {
        switch self {
        case .auto: return "Executes automatically without prompting for confirmation."
        case .ask: return "Pauses and prompts for user approval before each action."
        case .disabled: return "Turned off. Tool is unavailable to the agent."
        }
    }

    var iconName: String {
        switch self {
        case .auto: return "bolt.fill"
        case .ask: return "lock.shield.fill"
        case .disabled: return "circle.dashed"
        }
    }

    func tintColor(theme: any Theme) -> Color {
        switch self {
        case .auto: return theme.successColor
        case .ask: return theme.warningColor
        case .disabled: return theme.secondaryText
        }
    }
}

/// An execution mode dropdown control for managing tool activation and HITL approval.
/// States: Auto Run (Green Bolt) | Ask First (Orange Shield) | Disabled (Muted Dash)
fileprivate struct ToolStateControl: View {
    @Binding var configuredTools: [Tool]
    let source: ToolSource
    let definition: ToolDefinition
    let instructions: String
    var isLocked: Bool = false
    /// Why the tool cannot work yet; while non-nil it cannot be switched ON from here.
    var setupBlocker: String? = nil
    var onOpenSetup: (() -> Void)? = nil
    @Binding var isShowingDropdown: Bool

    @Environment(\.appTheme) private var theme
    @State private var showingDependencyAlert = false
    @State private var isHovered = false

    private var currentState: ToolControlState {
        if let tool = configuredTools.first(where: { $0.name == definition.name && $0.sourceId == source.id }) {
            return tool.requiresConfirmation ? .ask : .auto
        }
        return .disabled
    }

    var body: some View {
        Button {
            isShowingDropdown.toggle()
        } label: {
            HStack(spacing: 5) {
                stateIcon
                    .font(.system(size: 10, weight: .bold))
                
                Text(currentState.title)
                    .font(.system(size: 11, weight: .semibold))

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.8)
                    .rotationEffect(.degrees(isShowingDropdown ? 180 : 0))
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(stateBackground)
            .foregroundColor(stateForeground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(stateBorder, lineWidth: 1)
            )
            .shadow(color: stateShadowColor, radius: (isHovered || isShowingDropdown) ? 4 : 2, x: 0, y: (isHovered || isShowingDropdown) ? 2 : 1)
        }
        .buttonStyle(.plain)
        .help("Select execution mode: Auto Run, Ask First, or Disabled")
        .contentShape(Capsule())
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .popover(isPresented: $isShowingDropdown, arrowEdge: .bottom) {
            dropdownContent
                .frame(width: 290)
                .padding(8)
        }
        .alert("Tool in Use", isPresented: $showingDependencyAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Cannot disable '\(definition.name)'. It is currently referenced in the System Instructions. Please remove it from the instructions first.")
        }
    }

    private var dropdownContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EXECUTION MODE")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(theme.secondaryText.opacity(0.75))
                .tracking(0.6)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 2)

            // Not configured yet: only "Disabled" and "Setup" make sense. Once configured the
            // normal three come back, with "Setup" still last for changing the configuration.
            ForEach(ToolControlState.allCases.filter { setupBlocker == nil || $0 == .disabled }, id: \.self) { state in
                let isOptionLocked = (state == .disabled && isLocked)
                StateDropdownOptionRow(
                    state: state,
                    isSelected: currentState == state,
                    isDisabled: isOptionLocked,
                    disabledReason: isOptionLocked ? "Core tool required for Code Session" : nil,
                    theme: theme,
                    onSelect: {
                        if !isOptionLocked {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                selectState(state)
                            }
                            isShowingDropdown = false
                        }
                    }
                )
            }

            if let onOpenSetup {
                SetupOptionRow(
                    subtitle: setupBlocker ?? "Change this tool's configuration in Settings.",
                    needsAttention: setupBlocker != nil,
                    theme: theme
                ) {
                    isShowingDropdown = false
                    onOpenSetup()
                }
            }
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

    private var stateBackground: AnyView {
        switch currentState {
        case .disabled:
            return AnyView(
                RoundedRectangle(cornerRadius: 13)
                    .fill(isHovered || isShowingDropdown ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
            )
        case .ask:
            return AnyView(
                LinearGradient(
                    colors: [theme.warningColor.opacity(0.88), theme.warningColor],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        case .auto:
            return AnyView(
                LinearGradient(
                    colors: [theme.successColor.opacity(0.88), theme.successColor],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private var stateBorder: Color {
        switch currentState {
        case .disabled:
            return theme.dividerColor.opacity(isHovered || isShowingDropdown ? 0.5 : 0.25)
        case .ask, .auto:
            return Color.clear
        }
    }

    private var stateForeground: Color {
        switch currentState {
        case .disabled:
            return theme.secondaryText
        case .ask:
            return theme.warningForegroundColor
        case .auto:
            return .white
        }
    }

    private var stateShadowColor: Color {
        if !isHovered && !isShowingDropdown { return Color.black.opacity(0.04) }
        switch currentState {
        case .disabled: return Color.black.opacity(0.08)
        case .ask: return theme.warningColor.opacity(0.3)
        case .auto: return theme.successColor.opacity(0.3)
        }
    }

    private func selectState(_ state: ToolControlState) {
        guard state != currentState else { return }
        // Defence in depth: the dropdown already disables these options.
        if state != .disabled, currentState == .disabled, setupBlocker != nil { return }

        switch state {
        case .disabled:
            if isLocked { return }
            if instructions.contains("`\(definition.name)`") {
                showingDependencyAlert = true
                return
            }
            configuredTools.removeAll { $0.name == definition.name && $0.sourceId == source.id }

        case .ask:
            if let index = configuredTools.firstIndex(where: { $0.name == definition.name && $0.sourceId == source.id }) {
                configuredTools[index].requiresConfirmation = true
            } else {
                let newTool = Tool(
                    name: definition.name,
                    description: definition.description,
                    isEnabled: true,
                    requiresConfirmation: true,
                    sourceId: source.id,
                    parameters: definition.parameters
                )
                configuredTools.append(newTool)
            }

        case .auto:
            if let index = configuredTools.firstIndex(where: { $0.name == definition.name && $0.sourceId == source.id }) {
                configuredTools[index].requiresConfirmation = false
            } else {
                let newTool = Tool(
                    name: definition.name,
                    description: definition.description,
                    isEnabled: true,
                    requiresConfirmation: false,
                    sourceId: source.id,
                    parameters: definition.parameters
                )
                configuredTools.append(newTool)
            }
        }
    }
}

/// The fourth entry in a tool's execution-mode dropdown: opens the Settings pane where the tool
/// is configured. Not a state — choosing it changes nothing in the profile.
fileprivate struct SetupOptionRow: View {
    let subtitle: String
    let needsAttention: Bool
    let theme: any Theme
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 10) {
                let tint = needsAttention ? theme.warningColor : theme.accentColor
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(tint.opacity(0.14))
                        .frame(width: 26, height: 26)
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(isHovered ? theme.secondaryText.opacity(0.08) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
    }
}

internal struct StateDropdownOptionRow: View {
    let state: ToolControlState
    let isSelected: Bool
    var isDisabled: Bool = false
    var disabledReason: String? = nil
    var customTitle: String? = nil
    var customSubtitle: String? = nil
    let theme: any Theme
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            if !isDisabled {
                onSelect()
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                let tint = state.tintColor(theme: theme)

                // Colored icon badge
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(tint.opacity(isSelected ? 0.22 : (isDisabled ? 0.05 : 0.12)))
                        .frame(width: 26, height: 26)

                    Image(systemName: state.iconName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(isDisabled ? theme.secondaryText.opacity(0.4) : tint)
                }

                // Title and info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(customTitle ?? state.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(isDisabled ? theme.secondaryText : theme.primaryText)

                        if isDisabled {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                                .foregroundColor(theme.secondaryText.opacity(0.6))
                        }
                    }

                    Text(disabledReason ?? customSubtitle ?? state.subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(isDisabled ? theme.secondaryText.opacity(0.7) : theme.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(tint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected
                            ? state.tintColor(theme: theme).opacity(0.1)
                            : (isHovered && !isDisabled ? theme.surfaceOverlay : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected
                            ? state.tintColor(theme: theme).opacity(0.3)
                            : Color.clear,
                        lineWidth: 0.8
                    )
            )
            .contentShape(Rectangle())
            .opacity(isDisabled ? 0.55 : 1.0)
        }
        .buttonStyle(.plain)
        .pointingHandCursor(enabled: !isDisabled)
        .disabled(isDisabled)
        .onHover { hover in
            if !isDisabled {
                isHovered = hover
            }
        }
    }
}

// MARK: - Per-Tool Settings Popover

private struct ToolSettingsPopover: View {
    @Binding var configuredTools: [Tool]
    let source: ToolSource
    let definition: ToolDefinition
    @Binding var isShowingPopover: Bool

    @Environment(\.appTheme) private var theme
    @State private var isButtonHovered = false

    private var toolIndex: Int? {
        configuredTools.firstIndex(where: { $0.name == definition.name && $0.sourceId == source.id })
    }

    var body: some View {
        Button {
            isShowingPopover.toggle()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isShowingPopover
                            ? theme.accentColor.opacity(0.18)
                            : (isButtonHovered ? theme.surfaceOverlay : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                isShowingPopover
                                    ? theme.accentColor.opacity(0.5)
                                    : theme.dividerColor.opacity(isButtonHovered ? 0.45 : 0.25),
                                lineWidth: 0.8
                            )
                    )

                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(
                        isShowingPopover
                            ? theme.accentColor
                            : (isButtonHovered ? theme.primaryText : theme.secondaryText)
                    )
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hover in
            isButtonHovered = hover
        }
        .help("Tool settings")
        .accessibilityLabel("Tool settings")
        .popover(isPresented: $isShowingPopover, arrowEdge: .trailing) {
            popoverContent
                .frame(width: 340)
                .padding(14)
        }
    }

    @ViewBuilder
    private var popoverContent: some View {
        if let idx = toolIndex {
            let tier = definition.riskTier(in: source)
            let riskTint: Color = {
                switch tier {
                case .safe: return .blue
                case .moderate: return theme.warningColor
                case .destructive: return theme.errorColor
                }
            }()
            let riskDescription: String = {
                switch tier {
                case .safe:
                    return "Safe read-only tool. Inspects data or queries environment without mutating system state or files."
                case .moderate:
                    return "State-modifying tool. Creates, modifies, or moves files and data. Changes are generally recoverable."
                case .destructive:
                    return "High-impact or destructive tool. Executes arbitrary system commands, deletes resources, or performs irreversible actions."
                }
            }()

            VStack(alignment: .leading, spacing: 12) {
                // Header: Tool Context & Dismiss
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor.opacity(0.12))
                            .frame(width: 32, height: 32)
                        
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(definition.title ?? definition.name.toTitleCase())
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)
                            
                            if configuredTools[idx].isFavorite {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.yellow)
                            }
                        }

                        HStack(spacing: 5) {
                            Text(definition.name)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundColor(theme.secondaryText)

                            Text("•")
                                .font(.system(size: 9))
                                .foregroundColor(theme.secondaryText.opacity(0.5))

                            Text(source.serverName)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(theme.secondaryText.opacity(0.8))
                        }
                    }

                    Spacer(minLength: 4)

                    Button {
                        isShowingPopover = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(theme.secondaryText.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Close settings")
                }

                // 1. Risk Classification Card
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        HStack(spacing: 5) {
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                            Text("Tool Impact & Risk")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                        }
                        
                        Spacer()
                        
                        HStack(spacing: 4) {
                            Image(systemName: tier.icon)
                                .font(.system(size: 9, weight: .bold))
                            Text(tier.label.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.5)
                        }
                        .foregroundColor(riskTint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(riskTint.opacity(0.12))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(riskTint.opacity(0.35), lineWidth: 0.5)
                        )
                    }

                    Text(riskDescription)
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.secondaryText.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(riskTint.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(riskTint.opacity(0.2), lineWidth: 0.8)
                )

                // 2. Favorite Toggle Card
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: configuredTools[idx].isFavorite ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(configuredTools[idx].isFavorite ? .yellow : theme.secondaryText)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Favorite Tool")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Pins this tool to top of library & quick access")
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.secondaryText)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { configuredTools[idx].isFavorite },
                        set: { configuredTools[idx].isFavorite = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.surfaceOverlay.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.dividerColor.opacity(0.3), lineWidth: 0.8)
                )

                // 3. Truncation Strategy Card
                let selectedStrategy = configuredTools[idx].cutStrategy
                let strategyDescription: String = {
                    guard let strategy = selectedStrategy else {
                        return "Default: Follows the global context gauge setting (currently \(ContextCutStrategy.globalDefault.label.lowercased()))."
                    }
                    switch strategy {
                    case .automatic:
                        let autoChoice = ContextCutStrategy.automaticChoice(forTool: definition.name)
                        return "Automatic: Intelligently chooses '\(autoChoice.label)' for this tool based on its output structure."
                    case .keepStart:
                        return "Start (Keep beginning): Retains the first lines and discards the tail. Best for file reading and search listings."
                    case .keepEnd:
                        return "End (Keep latest): Retains the bottom/latest output and discards earlier text. Best for terminal commands and test logs."
                    case .keepStartAndEnd:
                        return "Start + End: Retains both the beginning and end with a '[...]' omission marker. Ideal for git diffs and structured data."
                    }
                }()

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "scissors")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Output Truncation")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            Text("When tool output exceeds context room")
                                .font(.system(size: 10.5))
                                .foregroundColor(theme.secondaryText)
                        }

                        Spacer()

                        Picker("", selection: Binding(
                            get: { configuredTools[idx].cutStrategy?.rawValue ?? "" },
                            set: { configuredTools[idx].cutStrategy = ContextCutStrategy(rawValue: $0) }
                        )) {
                            Text("Default (\(ContextCutStrategy.globalDefault.label))").tag("")
                            Text("Automatic").tag(ContextCutStrategy.automatic.rawValue)
                            Text("Start (Keep head)").tag(ContextCutStrategy.keepStart.rawValue)
                            Text("End (Keep tail)").tag(ContextCutStrategy.keepEnd.rawValue)
                            Text("Start + End (Both ends)").tag(ContextCutStrategy.keepStartAndEnd.rawValue)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(maxWidth: 140)
                    }

                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 9.5))
                            .foregroundColor(theme.secondaryText.opacity(0.8))
                            .padding(.top, 1)

                        Text(strategyDescription)
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 1)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.surfaceOverlay.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.dividerColor.opacity(0.3), lineWidth: 0.8)
                )

                // 4. Execution Timeout Card
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "clock")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(configuredTools[idx].timeout != nil ? theme.accentColor : theme.secondaryText)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Execution Timeout")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            if let timeout = configuredTools[idx].timeout {
                                Text("Capped at \(ToolExecutionMediator.describe(timeout))")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(theme.accentColor)
                            } else {
                                Text("Global default of \(ToolExecutionMediator.describe(ToolExecutionMediator.globalDefaultToolTimeout))")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(theme.secondaryText)
                            }
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { configuredTools[idx].timeout != nil },
                            set: { enabled in
                                configuredTools[idx].timeout = enabled ? ToolExecutionMediator.globalDefaultToolTimeout : nil
                                if !enabled { configuredTools[idx].timeoutMessage = nil }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    if configuredTools[idx].timeout != nil {
                        Divider()
                            .opacity(0.5)

                        // Duration Presets & Stepper
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Duration Presets")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(theme.secondaryText)

                            HStack(spacing: 5) {
                                let currentTimeout = configuredTools[idx].timeout ?? ToolExecutionMediator.globalDefaultToolTimeout
                                let presets: [(label: String, seconds: TimeInterval)] = [
                                    ("30s", 30),
                                    ("1m", 60),
                                    ("5m", 300),
                                    ("15m", 900),
                                    ("30m", 1800)
                                ]

                                ForEach(presets, id: \.seconds) { preset in
                                    let isSelected = abs(currentTimeout - preset.seconds) < 1.0
                                    Button {
                                        configuredTools[idx].timeout = preset.seconds
                                    } label: {
                                        Text(preset.label)
                                            .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3.5)
                                            .background(
                                                RoundedRectangle(cornerRadius: 5)
                                                    .fill(isSelected ? theme.accentColor : theme.surfaceOverlay)
                                            )
                                            .foregroundColor(isSelected ? .white : theme.primaryText)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 5)
                                                    .stroke(isSelected ? Color.clear : theme.dividerColor.opacity(0.4), lineWidth: 0.5)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .pointingHandCursor()
                                }

                                Spacer(minLength: 4)

                                // Fine-tune Stepper
                                Stepper(
                                    "",
                                    value: Binding(
                                        get: { configuredTools[idx].timeout ?? ToolExecutionMediator.globalDefaultToolTimeout },
                                        set: { configuredTools[idx].timeout = $0 }
                                    ),
                                    in: 5...3600,
                                    step: 5
                                )
                                .labelsHidden()
                                .controlSize(.mini)
                                .help("Fine-tune timeout (5s to 60m)")
                            }

                            // Custom LLM timeout message
                            VStack(alignment: .leading, spacing: 4) {
                                Text("On Timeout, Send to LLM:")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundColor(theme.secondaryText)

                                TextField(
                                    "Optional message (e.g., 'Check logs or retry with higher timeout')...",
                                    text: Binding(
                                        get: { configuredTools[idx].timeoutMessage ?? "" },
                                        set: { configuredTools[idx].timeoutMessage = $0.isEmpty ? nil : $0 }
                                    ),
                                    axis: .vertical
                                )
                                .lineLimit(2...3)
                                .font(.system(size: 11))
                                .textFieldStyle(.roundedBorder)

                                Text("Leave empty for standard timeout error.")
                                    .font(.system(size: 9.5))
                                    .foregroundColor(theme.secondaryText.opacity(0.7))
                            }
                            .padding(.top, 2)
                        }
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.surfaceOverlay.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.dividerColor.opacity(0.3), lineWidth: 0.8)
                )
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(theme.warningColor)
                Text("Enable this tool to configure its settings.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
            .frame(width: 260)
            .padding()
        }
    }
}

// MARK: - Risk & Behavioral Indicator Components

/// Visual badge indicator showing the tool's HITL risk classification (Read-only, Modifies, Destructive).
private struct ToolRiskBadge: View {
    let tier: HITLRiskTier
    var isCompact: Bool = false
    @Environment(\.appTheme) private var theme

    private var tintColor: Color {
        switch tier {
        case .safe: return .blue
        case .moderate: return theme.warningColor
        case .destructive: return theme.errorColor
        }
    }

    private var descriptionText: String {
        switch tier {
        case .safe:
            return "Read-only: Performs inspections or queries without modifying files or system state."
        case .moderate:
            return "Modifies: Makes changes to files, settings, or state (generally recoverable)."
        case .destructive:
            return "Destructive: Executes arbitrary code, removes data, or alters critical system state."
        }
    }

    var body: some View {
        HStack(spacing: 3.5) {
            Image(systemName: tier.icon)
                .font(.system(size: isCompact ? 7.5 : 8.5, weight: .semibold))
            
            Text(tier.label.uppercased())
                .font(.system(size: isCompact ? 7.5 : 8.5, weight: .bold))
                .tracking(0.4)
        }
        .foregroundColor(tintColor)
        .padding(.horizontal, isCompact ? 5 : 6)
        .padding(.vertical, isCompact ? 1.5 : 2.5)
        .background(tintColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(tintColor.opacity(0.28), lineWidth: 0.5)
        )
        .help("\(tier.label): \(descriptionText)")
    }
}

/// Pill badge displayed on the tool row when a custom execution timeout override is set.
private struct ToolTimeoutBadge: View {
    let timeout: TimeInterval
    var isCompact: Bool = false
    @Environment(\.appTheme) private var theme

    private var formattedText: String {
        ToolExecutionMediator.describe(timeout).uppercased()
    }

    var body: some View {
        HStack(spacing: 3.5) {
            Image(systemName: "clock.fill")
                .font(.system(size: isCompact ? 7.5 : 8.5, weight: .semibold))
            
            Text(formattedText)
                .font(.system(size: isCompact ? 7.5 : 8.5, weight: .bold))
                .tracking(0.4)
        }
        .foregroundColor(theme.accentColor)
        .padding(.horizontal, isCompact ? 5 : 6)
        .padding(.vertical, isCompact ? 1.5 : 2.5)
        .background(theme.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(theme.accentColor.opacity(0.28), lineWidth: 0.5)
        )
        .help("Execution timeout override: \(ToolExecutionMediator.describe(timeout))")
    }
}

// MARK: - MCP v0.11.0 UI Components

/// Displays supplementary annotation badges for an MCP tool's behavioral hints.
private struct ToolAnnotationBadges: View {
    let annotations: ToolAnnotations?

    var body: some View {
        if let annotations = annotations {
            HStack(spacing: 4) {
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

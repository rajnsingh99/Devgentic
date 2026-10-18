// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolNavigationPane.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

private let logger = DGLogger(category: "ToolNavigationPane")

/// The Tool Library's navigation, hosted in the sidebar pane. The Tools rail tab renders it directly, and the
/// Profiles tab swaps its profile list for it while the Tool Library is the active destination (derived from the
/// router, never stored).
struct ToolNavigationPane: View {

    /// Where this pane is hosted. When hosted in profilesTab, suppresses automatic
    /// navigation to the global tool library on appear.
    enum Host {
        case toolsTab
        case profilesTab
    }

    let host: Host

    @Environment(\.appTheme) private var theme
    @Environment(MainViewRouter.self) private var router

    @State private var pendingDeletion: ToolSource?
    @FocusState private var isListFocused: Bool

    private var nav: ToolLibraryNavigationState { .shared }
    private var toolStore: UnifiedToolStore { UnifiedToolStore.shared }

    private var currentNavSelections: [SidebarSelection] {
        switch nav.section {
        case .builtIn:
            var items: [SidebarSelection] = [.all]
            if favoriteCount > 0 { items.append(.favorites) }
            for group in builtInGroups {
                items.append(.localCategory(group.name))
            }
            return items
        case .mcp:
            var items: [SidebarSelection] = [.marketplace]
            for source in mcpSources {
                items.append(.mcp(source.id))
            }
            return items
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            sectionSwitcher

            ScrollViewReader { proxy in
                ScrollView {
                    switch nav.section {
                    case .builtIn: builtInSections
                    case .mcp:     mcpSections
                    }
                }
                .focusable()
                .focused($isListFocused)
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    moveFocus(direction)
                }
                .onKeyPress(.return) {
                    ensureLibraryVisible()
                    return .handled
                }
                .onKeyPress(.delete) {
                    if case .mcp(let id) = nav.selectedSidebar,
                       let source = mcpSources.first(where: { $0.id == id }) {
                        pendingDeletion = source
                        return .handled
                    }
                    return .ignored
                }
            }
        }
        .onAppear { openLibraryIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .addMCPServer)) { _ in
            router.navigate(to: .addMCPServer)
        }
        .confirmationDialog(
            "Remove “\(pendingDeletion?.serverName ?? "")”?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Server", role: .destructive) {
                if let source = pendingDeletion {
                    toolStore.deleteTool(toolSource: source)
                    if nav.selectedSidebar == .mcp(source.id) { nav.selectedSidebar = .all }
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(pendingDeletion.map(Self.deletionWarning) ?? "")
        }
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        let items = currentNavSelections
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex(where: { $0 == nav.selectedSidebar }) ?? 0
        switch direction {
        case .down:
            let nextIndex = min(currentIndex + 1, items.count - 1)
            nav.selectedSidebar = items[nextIndex]
            ensureLibraryVisible()
        case .up:
            let prevIndex = max(currentIndex - 1, 0)
            nav.selectedSidebar = items[prevIndex]
            ensureLibraryVisible()
        default:
            break
        }
    }

    /// Opens the Tool Library when the Tools rail tab is selected, because this pane's rows are categories of the library
    /// and mean nothing unless it is on screen. Does not move the user if they are already somewhere in the tool family
    /// (the library or its add/edit server forms).
    private func openLibraryIfNeeded() {
        guard host == .toolsTab else { return }
        ensureLibraryVisible()
    }

    /// Belt-and-braces: a click on any row guarantees the library is on screen, covering the case where Done leaves the
    /// Tools pane mounted while the destination is chat.
    private func ensureLibraryVisible() {
        switch router.activeDestination {
        case .toolLibrary, .addMCPServer, .editMCPServer:
            return
        default:
            logger.info("[TOOLLIB] Tools tab selected — opening the Tool Library (was \(router.activeDestination.displayName)).")
            router.navigate(to: .toolLibrary(profileID: nil))
        }
    }

    // MARK: - Header

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text("Tool Library")
                .font(theme.fontBody.weight(.semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            // Manual configuration, distinct from the Marketplace's registry-driven flow.
            SidebarHeaderActionButton(
                title: "Add Server",
                systemImage: "plus",
                shortcut: "⌘N"
            ) {
                router.navigate(to: .addMCPServer)
            }
            .keyboardShortcut("n", modifiers: [.command])
            .help("Configure an MCP server by hand (⌘N)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var sectionSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(ToolLibrarySection.allCases) { section in
                let isSelected = nav.section == section
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        nav.section = section
                        switch section {
                        case .builtIn where isMCPSelection(nav.selectedSidebar):
                            nav.selectedSidebar = .all
                        case .mcp where !isMCPSelection(nav.selectedSidebar):
                            nav.selectedSidebar = .marketplace
                        default:
                            break
                        }
                        ensureLibraryVisible()
                    }
                } label: {
                    Text(section.title)
                        .font(theme.fontCaption2.weight(isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? theme.surfaceOverlayStrong : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(isSelected ? theme.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surfaceOverlay)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.secondaryText.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func isMCPSelection(_ selection: SidebarSelection?) -> Bool {
        switch selection {
        case .mcp, .marketplace: return true
        default:                 return false
        }
    }

    // MARK: - Build-In

    private var builtInSections: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Library") {
                row(label: "All", icon: "archivebox.fill", count: builtInToolCount, tag: .all)
                if favoriteCount > 0 {
                    row(label: "Favorites", icon: "star.fill", count: favoriteCount, tag: .favorites)
                }
            }

            section("Categories") {
                ForEach(builtInGroups, id: \.name) { group in
                    row(label: group.name, icon: group.icon, count: group.count, tag: .localCategory(group.name))
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
    }

    // MARK: - MCP

    private var mcpSections: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Marketplace leads: it is how a server gets here in the first place, and it is
            // the only row that is an action rather than a filter.
            marketplaceRow

            section("Installed") {
                let sources = mcpSources
                if sources.isEmpty {
                    VStack(spacing: 6) {
                        Text("No MCP servers yet")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                        Text("Browse the Marketplace, or Add Custom.")
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                } else {
                    ForEach(sources) { source in
                        mcpRow(source)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
    }

    private var marketplaceRow: some View {
        ToolSidebarRow(
            label: "Marketplace",
            icon: "storefront",
            count: nil,
            isSelected: nav.selectedSidebar == .marketplace,
            showChevron: true
        ) {
            nav.selectedSidebar = .marketplace
            ensureLibraryVisible()
        }
        .help("Browse the official MCP registry")
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        trailing: (() -> AnyView)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.secondaryText.opacity(0.7))
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer()
                if let trailing { trailing() }
            }
            .padding(.horizontal, 8)

            content()
        }
    }

    private func row(label: String, icon: String, count: Int, tag: SidebarSelection) -> some View {
        ToolSidebarRow(
            label: label,
            icon: icon,
            count: count,
            isSelected: nav.selectedSidebar == tag
        ) {
            nav.selectedSidebar = tag
            ensureLibraryVisible()
        }
    }

    private func mcpRow(_ source: ToolSource) -> some View {
        let isSelected = nav.selectedSidebar == .mcp(source.id)
        let state = MCPClientService.shared.connectionStates[source.id] ?? .disconnected

        return ToolSidebarRow(
            label: source.serverName,
            icon: "network",
            count: source.tools.count,
            isSelected: isSelected,
            statusDot: AnyView(statusDot(state: state, isEnabled: source.isEnabled))
        ) {
            nav.selectedSidebar = .mcp(source.id)
            ensureLibraryVisible()
        }
        .opacity(source.isEnabled ? 1 : 0.55)
        .contextMenu {
            Button(source.isEnabled ? "Disable Server" : "Enable Server") {
                toolStore.setEnabled(!source.isEnabled, sourceID: source.id)
            }
            if source.isEnabled {
                Button(state.isActive ? "Reconnect" : "Connect") {
                    Task { await MCPConnectionCoordinator.shared.reconnect(sourceID: source.id) }
                }
                Button("Rescan Tools") {
                    Task { await MCPConnectionCoordinator.shared.rescan(sourceID: source.id) }
                }
            }
            Divider()
            Button("Edit Configuration") {
                router.navigate(to: .editMCPServer(sourceID: source.id))
            }
            Divider()
            Button("Remove Server", role: .destructive) {
                pendingDeletion = source
            }
        }
    }

    @ViewBuilder
    private func statusDot(state: MCPConnectionState, isEnabled: Bool) -> some View {
        if !isEnabled {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 9))
                .foregroundColor(theme.secondaryText.opacity(0.6))
        } else {
            Circle()
                .fill(colour(for: state))
                .frame(width: 7, height: 7)
                .help(label(for: state))
        }
    }

    private func colour(for state: MCPConnectionState) -> Color {
        switch state {
        case .connected:                 return theme.successColor
        case .connecting, .reconnecting: return theme.warningColor
        case .error:                     return theme.errorColor
        case .disconnected:              return theme.secondaryText.opacity(0.4)
        }
    }

    private func label(for state: MCPConnectionState) -> String {
        switch state {
        case .connected:            return "Connected"
        case .connecting:           return "Connecting…"
        case .reconnecting(let n):  return "Reconnecting (attempt \(n))"
        case .error:                return "Connection failed — open the server for details"
        case .disconnected:         return "Not connected"
        }
    }

    // MARK: - Data

    private var mcpSources: [ToolSource] {
        toolStore.sources
            .filter { $0.type == .mcp }
            .sorted { $0.serverName.localizedCaseInsensitiveCompare($1.serverName) == .orderedAscending }
    }

    /// Built-in only. The old combined count mixed MCP tools into a "Library" row that now
    /// sits under the Build-In section, where 807 would be a lie about what clicking it shows.
    private var builtInToolCount: Int {
        toolStore.sources.filter { $0.type == .local }.reduce(0) { $0 + $1.tools.count }
    }

    /// Favourites live on the PROFILE's tool list, which the pane has no access to. Reading
    /// zero here would hide the section entirely, so it is derived from the shared library
    /// state instead — set by the content view, which does have the profile.
    private var favoriteCount: Int { ToolLibraryFavoritesBridge.shared.count }

    private var builtInGroups: [(name: String, icon: String, count: Int)] {
        let localTools = toolStore.sources.filter { $0.type == .local }.flatMap(\.tools)
        return BuiltInToolCategory.allGroups.compactMap { group in
            let count = localTools.filter { group.rawCategories.contains($0.category) }.count
            guard count > 0 else { return nil }
            return (name: group.name, icon: group.icon, count: count)
        }
    }

    /// Same copy as the library's own delete confirmation — removing a server is not
    /// recoverable and the dialog must say what is lost.
    private static func deletionWarning(for source: ToolSource) -> String {
        var lines = ["This cannot be undone."]
        let toolCount = source.tools.count
        if toolCount > 0 {
            lines.append("\(toolCount) tool\(toolCount == 1 ? "" : "s") will be removed from every profile that uses them.")
        }
        if let definition = source.serverDefinition {
            let envCount = definition.envKeys?.count ?? 0
            if envCount > 0 {
                lines.append("\(envCount) stored credential\(envCount == 1 ? "" : "s") will be deleted from your Keychain.")
            }
            switch definition.auth {
            case .oauth:
                lines.append("Your sign-in will be revoked at the provider — you will need to authorize again.")
            case .bearer, .apiKeyHeader:
                lines.append("The saved API credential will be deleted from your Keychain.")
            case .none:
                break
            }
        }
        return lines.joined(separator: "\n\n")
    }
}

/// Publishes the favourite count from the content view (which owns the profile's tool list)
/// to the pane (which does not). A one-value bridge rather than threading the whole profile
/// through the sidebar.
@Observable @MainActor
final class ToolLibraryFavoritesBridge {
    static let shared = ToolLibraryFavoritesBridge()
    private init() {}
    var count: Int = 0
}


/// One-shot hand-off for deep-linking the Tool Library onto a specific server. The router carries only a destination,
/// so this shared slot carries the hint and self-clears so a later navigation cannot inherit it.
@Observable @MainActor
final class MCPToolLibrarySelection {
    static let shared = MCPToolLibrarySelection()
    private init() {}

    var pendingServerID: UUID?

    func consume() -> UUID? {
        defer { pendingServerID = nil }
        return pendingServerID
    }
}

// MARK: - Tool Sidebar Row (8pt continuous rounded rectangle with hover scaling)

struct ToolSidebarRow: View {
    let label: String
    let icon: String
    let count: Int?
    let isSelected: Bool
    var showChevron: Bool = false
    var statusDot: AnyView? = nil
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(theme.fontCaption.weight(isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? theme.accentColor : (isHovered ? theme.accentColor : theme.secondaryText))
                    .frame(width: 18)

                Text(label)
                    .font(theme.fontCaption.weight(isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? theme.primaryText : (isHovered ? theme.primaryText : theme.primaryText.opacity(0.85)))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let count {
                    Text("\(count)")
                        .font(theme.fontCodeCaption.weight(.bold))
                        .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? theme.accentColor.opacity(0.15) : theme.surfaceOverlay)
                        )
                }

                if let statusDot {
                    statusDot
                }

                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(theme.fontCaption2.weight(.semibold))
                        .foregroundColor(isSelected ? theme.accentColor : theme.tertiaryText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .sidebarRowBackground(isSelected: isSelected, isHovering: isHovered)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

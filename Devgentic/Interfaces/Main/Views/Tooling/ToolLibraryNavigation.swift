//
//  ToolLibraryNavigation.swift
//  Devgentic
//
//  Created 2026-08-02 — shared navigation state for the Tool Library.
//
//  The library's navigation (category, Installed/Discover, Discover facets) used to be
//  `@State` inside `ToolLibraryView`, which was fine while the nav lived inside that view.
//  It now lives in the SIDEBAR PANE — a completely separate view tree — so the two halves
//  need one source of truth between them.
//
//  Why the nav moved: the pane and the library's own inner sidebar were both listing MCP
//  servers, side by side, with different affordances. That is nav-inside-nav, and it spent
//  ~220pt of the content column duplicating what the app shell already provides.
//

import SwiftUI

/// Which half of the library the pane is showing.
///
/// Renamed from Installed/Discover on 2026-08-02: that pair described where a server came
/// from rather than what the row IS, and it put built-in tools and MCP servers under the same
/// heading. Built-in vs MCP is the distinction the user actually navigates by.
enum ToolLibrarySection: String, CaseIterable, Identifiable {
    case builtIn, mcp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .builtIn: return "Build-In"
        case .mcp:     return "MCP"
        }
    }
}

/// Discover's local/remote facet. Lives here rather than in `MCPDiscoverView` because the
/// chips now render in the pane while the grid renders in the content column.
enum ToolDiscoverFilter: String, CaseIterable, Identifiable {
    case all = "All", local = "Local", remote = "Remote"
    var id: String { rawValue }
}

@Observable @MainActor
final class ToolLibraryNavigationState {

    static let shared = ToolLibraryNavigationState()
    private init() {}

    var selectedSidebar: SidebarSelection? = .all
    var section: ToolLibrarySection = .builtIn
    var discoverFilter: ToolDiscoverFilter = .all

    /// Search text, shared so the island-bar field filters the pane's counts too.
    var searchText: String = ""

}

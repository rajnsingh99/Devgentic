// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolLibraryNavigation.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Which half of the library the pane is showing: built-in tools or MCP servers, the distinction users
/// navigate by.
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

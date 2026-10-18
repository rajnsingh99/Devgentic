// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CommandPaletteModel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftUI

// MARK: - Category

enum CommandPaletteCategory: String, CaseIterable, Identifiable {
    case navigation = "Navigation"
    case mode = "Interface Modes"
    case action = "Actions"
    case recentChat = "Recent Chats"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .navigation: return "arrow.turn.up.right"
        case .mode: return "square.2.layers.3d"
        case .action: return "bolt.fill"
        case .recentChat: return "bubble.left.and.bubble.right"
        }
    }
}

// MARK: - Item

struct CommandPaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String
    let category: CommandPaletteCategory
    let shortcutBadge: [String]?
    let keywords: [String]
    let action: () -> Void

    init(
        id: String? = nil,
        title: String,
        subtitle: String? = nil,
        icon: String,
        category: CommandPaletteCategory,
        shortcutBadge: [String]? = nil,
        keywords: [String] = [],
        action: @escaping () -> Void
    ) {
        self.id = id ?? "\(category.rawValue)-\(title)"
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.category = category
        self.shortcutBadge = shortcutBadge
        self.keywords = keywords
        self.action = action
    }

    func matches(query: String) -> Bool {
        let cleanQuery = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !cleanQuery.isEmpty else { return true }

        if title.lowercased().contains(cleanQuery) { return true }
        if let sub = subtitle, sub.lowercased().contains(cleanQuery) { return true }
        if category.rawValue.lowercased().contains(cleanQuery) { return true }
        if let badges = shortcutBadge, badges.joined().lowercased().contains(cleanQuery) { return true }
        if keywords.contains(where: { $0.lowercased().contains(cleanQuery) }) { return true }

        return false
    }
}

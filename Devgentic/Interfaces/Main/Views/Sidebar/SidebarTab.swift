//
//  SidebarTab.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//

import SwiftUI
import Combine
import os

enum SidebarTab: CaseIterable, Identifiable {
    case newChat
    case conversations
    case integration
    case explorer
    case promptLibrary
    case settings
    case user

    var id: Self { self }

    /// Provides the SF Symbol name for each tab icon.
    var iconName: String {
        switch self {
        case .newChat:
            return "plus.bubble"
        case .conversations:
            return "message"
        case .integration:
            return "cpu"
        case .promptLibrary:
            return "square.stack.3d.up.fill"
        case .settings:
            return "gearshape"
        case .user:
            return "person.crop.circle"
        case .explorer:
            return "folder"
        }
    }

    /// Provides a title/tooltip for each tab, used in the Side Bar Pane header or for panel titles.
    var title: String {
        switch self {
        case .newChat:
            return "New Conversation"
        case .conversations:
            return "Conversations"
        case .integration:
            // Updated title for a cleaner header
            return "LLM Integrations"
        case .promptLibrary:
            return "Prompt Library"
        case .settings:
            return "Settings"
        case .user:
            return "Account"
        case .explorer:
            return "Explorer"
        }
    }
}

// --- Placeholder Views remain the same ---

struct ConversationsTabViewPlaceholder: View {
    var body: some View {
        Text("Conversation List View Placeholder\n(Will contain the actual list)")
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundColor(.secondary)
    }
}

struct LocalModelDiscoveryGridViewPlaceholder: View {
    var body: some View {
        Text("Local Model Discovery Grid Placeholder\n(Will show models to download)")
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundColor(.secondary)
    }
}

struct SettingsTabView: View {
    var body: some View {
        Text("Application settings content will appear here.\n(Separate from the old slide-over panel for now)")
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundColor(.secondary)
    }
}

struct UserTabView: View {
    var body: some View {
        Text("User login/profile information will appear here.")
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundColor(.secondary)
    }
}

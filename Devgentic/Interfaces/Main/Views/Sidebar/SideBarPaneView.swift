//
//  SideBarPaneView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "SideBarPaneView")

enum SidebarTab: CaseIterable, Identifiable {
    case conversations
    case explorer
    case promptLibrary
    case backendProfiles
    case settings
    case user

    var id: Self { self }

    var iconName: String {
        switch self {
        case .conversations: return "message"
        case .promptLibrary: return "square.stack.3d.up.fill"
        case .backendProfiles: return "cpu"
        case .settings: return "gearshape"
        case .user: return "person.crop.circle"
        case .explorer: return "folder"
        }
    }

    var title: String {
        switch self {
        case .conversations: return "Chats"
        case .promptLibrary: return "Prompts"
        case .backendProfiles: return "Profiles"
        case .settings: return "Settings"
        case .user: return "Account"
        case .explorer: return "Explorer"
        }
    }
}


struct SideBarPaneView: View {
    @Binding var selectedTab: SidebarTab?
    @Binding var sidebarWidth: CGFloat

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Only show a generic header for tabs that don't have their own rich toolbar/search bar.
            // Explorer, Conversations, and Prompts now handle their own top area.
            if let tab = selectedTab, shouldShowGenericHeader(for: tab) {
                 HStack {
                     Text(tab.title)
                         .font(.system(size: 11, weight: .bold))
                         .foregroundColor(.secondary)
                         .textCase(.uppercase)
                         .tracking(0.5)
                     
                     Spacer()
                 }
                 .padding(.horizontal, 16)
                 .padding(.top, 14)
                 .padding(.bottom, 8)
                 
                 Divider()
                     .background(Color.white.opacity(0.1))
            }

            VStack {
                switch selectedTab {
                case .explorer:
                    ExplorerSidebarView()
                case .conversations:
                    ConversationSidebarView()
                case .promptLibrary:
                    PromptLibrarySidebarView()
                case .backendProfiles:
                    // Placeholder or actual view for Profiles
                    PlaceholderSidebarView(icon: "cpu", title: "Backend Profiles", description: "Manage your AI models and agents here.")
                case .settings:
                    PlaceholderSidebarView(icon: "gearshape", title: "Settings", description: "Application preferences coming soon.")
                case .user:
                    PlaceholderSidebarView(icon: "person.crop.circle", title: "Account", description: "User profile management coming soon.")
                case .none:
                    Spacer()
                }
            }
            .environmentObject(viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Use clear background to allow the parent container's material/vibrancy to show through
        .background(Color.clear)
        .frame(maxHeight: .infinity)
    }
    
    private func shouldShowGenericHeader(for tab: SidebarTab) -> Bool {
        switch tab {
        case .explorer, .conversations, .promptLibrary:
            return false // These views have their own search bars/headers
        default:
            return true
        }
    }
}

// MARK: - Placeholder View for Empty/Future Tabs
struct PlaceholderSidebarView: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 70, height: 70)
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundColor(.secondary)
            }
            
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

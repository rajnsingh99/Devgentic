import SwiftUI
import Combine // For potential future use with ViewModel state
import os     // For logging (optional here, but good practice)

// Logger (Optional)
// private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "Sidebar")

// MARK: - SidebarTab Enum
/// Represents the different tabs available in the Activity Bar.
enum SidebarTab: CaseIterable, Identifiable {
    case newChat
    case conversations
    case localModels
    // MARK: - New Tab for Prompt Library
    case promptLibrary // Added new case
    case agents
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
        case .localModels:
            return "cpu"
        // MARK: - Icon for Prompt Library
        case .promptLibrary:
            return "books.vertical" // Example icon, choose one that fits
        case .agents:
            return "figure.walk.motion"
        case .settings:
            return "gearshape"
        case .user:
            return "person.crop.circle"
        }
    }

    /// Provides a title/tooltip for each tab, used in the Side Bar Pane header or for panel titles.
    var title: String {
        switch self {
        case .newChat:
            return "New Chat"
        case .conversations:
            return "Conversations"
        case .localModels:
            return "Local AI Models"
        // MARK: - Title for Prompt Library
        case .promptLibrary:
            return "Prompt Library"
        case .agents:
            return "Agents"
        case .settings:
            return "Settings"
        case .user:
            return "Account"
        }
    }
}

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

struct AgentsTabView: View {
    var body: some View {
        Text("Agent configuration and management will appear here.")
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


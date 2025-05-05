import SwiftUI
import Combine // For potential future use with ViewModel state
import os     // For logging (optional here, but good practice)

// Logger (Optional)
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "Sidebar")

// --- Phase 1: Core Sidebar Structure ---

// MARK: - SidebarTab Enum
/// Represents the different tabs available in the Activity Bar.
enum SidebarTab: CaseIterable, Identifiable {
    case newChat
    case conversations
    case localModels
    case agents
    case settings
    case user

    var id: Self { self }

    /// Provides the SF Symbol name for each tab icon.
    var iconName: String {
        switch self {
        case .newChat:
            // Use a placeholder icon for Devgentic for now
            // Replace "brain.head.profile" with your actual app icon if available as an SF Symbol or asset
            return "plus.bubble" // Changed to a more "new chat" like icon
        case .conversations:
            return "message" // Standard chat bubble icon
        case .localModels:
            return "cpu" // Icon representing processing or models
        case .agents:
            return "figure.walk.motion" // Icon representing agents or actions
        case .settings:
            return "gearshape" // Standard settings icon
        case .user:
            return "person.crop.circle" // Standard user profile icon
        }
    }

    /// Provides a title/tooltip for each tab, used in the Side Bar Pane header.
    var title: String {
        switch self {
        case .newChat:
            return "New Chat"
        case .conversations:
            return "Conversations"
        case .localModels:
            return "Local AI Models"
        case .agents:
            return "Agents"
        case .settings:
            return "Settings"
        case .user:
            return "Account" // Changed from "User Account" for brevity
        }
    }
}

// MARK: - Activity Bar View
/// The thin vertical bar on the far left, displaying icons for different sections.
struct ActivityBarView: View {
    // Binding to the selected tab state in the container view
    @Binding var selectedTab: SidebarTab?
    // Binding to the sidebar visibility state in the container view
    @Binding var isSidebarVisible: Bool

    var body: some View {
        VStack(spacing: 0) { // No vertical space between buttons initially
            // --- Top Icons (New Chat, Conversations, Models, Agents) ---
            // Filter out settings and user tabs for the top section
            ForEach(SidebarTab.allCases.filter { $0 != .settings && $0 != .user }) { tab in
                ActivityBarButton(
                    tab: tab,
                    selectedTab: $selectedTab,
                    isSidebarVisible: $isSidebarVisible
                )
            }

            Spacer() // Pushes the bottom icons down

            // --- Bottom Icons (Settings, User) ---
            // Explicitly add buttons for settings and user tabs
            ActivityBarButton(
                tab: .settings,
                selectedTab: $selectedTab,
                isSidebarVisible: $isSidebarVisible
            )
            ActivityBarButton(
                tab: .user,
                selectedTab: $selectedTab,
                isSidebarVisible: $isSidebarVisible
            )
        }
        .frame(width: 50) // Fixed width for the Activity Bar
        .padding(.vertical, 10) // Add some padding at the top and bottom
        // Use a standard system background color that adapts to light/dark mode
        .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
        // Ensure the bar takes the full available height
        .frame(maxHeight: .infinity)
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


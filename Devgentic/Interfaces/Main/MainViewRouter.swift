//
//  MainViewRouter.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//
//  Custom enum-based router for single-window stack navigation.
//  Uses opacity toggling to keep the chat view alive while showing
//  profile/settings detail views in the main content area.
//

import SwiftUI

/// Represents a destination that can be shown in the main content area.
enum MainViewDestination: Equatable, Hashable {
    case chat
    case profileDetail(profileID: UUID)
    case settingsDetail(category: SettingsCategory)
    /// Profile is OPTIONAL. The Tool Library is reachable from the Tools rail tab with no
    /// backend chosen — browsing the catalogue, managing MCP servers and Discover need no
    /// profile. Only per-tool enablement writes to one, and that surface hides itself when
    /// there is nothing to write to.
    case toolLibrary(profileID: UUID?)
    case addMCPServer
    case editMCPServer(sourceID: UUID)
    case promptDetail(promptID: UUID)
    case scheduledTaskDetail(taskID: UUID)
    case scheduledTaskCreate(prefillPrompt: String?, prefillConversationID: UUID?)
    case ollamaModelStore(profileID: UUID)
    case mlxModelStore(profileID: UUID, filterForTools: Bool)
    case downloadManager
    case userPersonalProfile

    /// Short label used in back-button help text and context menus
    /// (e.g. "Back to Chat", "Back to Settings").
    var displayName: String {
        switch self {
        case .chat: return "Chat"
        case .profileDetail: return "Profile"
        case .settingsDetail(let category): return category.rawValue
        case .toolLibrary: return "Tool Library"
        case .addMCPServer: return "Add MCP Server"
        case .editMCPServer: return "Edit MCP Server"
        case .promptDetail: return "Prompt"
        case .scheduledTaskDetail: return "Scheduled Task"
        case .scheduledTaskCreate: return "New Scheduled Task"
        case .ollamaModelStore: return "Ollama Models"
        case .mlxModelStore: return "MLX Models"
        case .downloadManager: return "Downloads"
        case .userPersonalProfile: return "Your Profile"
        }
    }
}

/// Manages push/pop stack navigation for the main content area.
///
/// The chat view is kept alive via opacity toggling (never torn down),
/// while non-chat destinations are lazily created on demand.
@Observable @MainActor
final class MainViewRouter {
    var activeDestination: MainViewDestination = .chat
    private(set) var navigationStack: [MainViewDestination] = []

    var canGoBack: Bool { !navigationStack.isEmpty }

    var isShowingChat: Bool { activeDestination == .chat }

    /// Push the current destination onto the stack and navigate to a new one.
    func navigate(to destination: MainViewDestination) {
        navigationStack.append(activeDestination)
        activeDestination = destination

        // The Tool Library's navigation lives in the sidebar pane, so entering it with the
        // pane hidden (⌘B) would leave no way to change category or pick a server. Ask for
        // the pane; the shell honours it.
        if case .toolLibrary = destination {
            NotificationCenter.default.post(name: .requestSidebarVisible, object: nil)
        }
    }

    /// Pop the last destination from the stack.
    func goBack() {
        activeDestination = navigationStack.popLast() ?? .chat
    }

    /// Return directly to chat, clearing the entire stack.
    func returnToChat() {
        navigationStack.removeAll()
        activeDestination = .chat
    }

    /// Navigate to a profile detail, clearing any existing non-chat stack first.
    /// Used when tapping a different profile in the sidebar while already viewing one.
    ///
    /// Eagerly activates the edit buffer **before** publishing the new destination
    /// so `ProfileDetailContainerView` has the buffer ready on its first render
    /// (no "Profile not found" flash).
    func navigateToProfile(_ profileID: UUID, activatingBufferOn service: BackendProfileService) {
        service.activateEditBuffer(for: profileID)
        navigationStack.removeAll()
        navigationStack.append(.chat)
        activeDestination = .profileDetail(profileID: profileID)
    }

    /// Navigate to a settings category, clearing any existing non-chat stack first.
    func navigateToSettings(_ category: SettingsCategory) {
        navigationStack.removeAll()
        navigationStack.append(.chat)
        activeDestination = .settingsDetail(category: category)
    }

    /// Navigate to a prompt detail, clearing any existing non-chat stack first.
    func navigateToPrompt(_ promptID: UUID) {
        navigationStack.removeAll()
        navigationStack.append(.chat)
        activeDestination = .promptDetail(promptID: promptID)
    }

    /// Navigate to a scheduled task detail, clearing any existing non-chat stack first.
    func navigateToTask(_ taskID: UUID) {
        navigationStack.removeAll()
        navigationStack.append(.chat)
        activeDestination = .scheduledTaskDetail(taskID: taskID)
    }

    /// Navigate to the new-scheduled-task editor.
    /// `prefillPrompt` and `prefillConversationID` are used by the chat-input
    /// "Custom..." entry point so the form opens with the current message text
    /// and defaults the run mode to "Continue this conversation" with the
    /// active conversation pre-selected. Clears any existing non-chat stack
    /// so Back returns to chat.
    func navigateToNewTask(prefillPrompt: String? = nil, prefillConversationID: UUID? = nil) {
        navigationStack.removeAll()
        navigationStack.append(.chat)
        activeDestination = .scheduledTaskCreate(
            prefillPrompt: prefillPrompt,
            prefillConversationID: prefillConversationID
        )
    }

    /// Navigate to a model store from within a profile detail view.
    /// Pushes the current destination (profile) onto the stack so Back returns to it.
    func navigateToModelStore(backend: ModelBackendType, profileID: UUID, filterForTools: Bool = false) {
        switch backend {
        case .ollama:
            navigate(to: .ollamaModelStore(profileID: profileID))
        case .mlx:
            navigate(to: .mlxModelStore(profileID: profileID, filterForTools: filterForTools))
        case .whisper:
            break // Whisper models are managed via Settings > Speech Recognition
        }
    }

    /// Navigate to the download manager, clearing any existing non-chat stack first.
    func navigateToDownloadManager() {
        navigationStack.removeAll()
        navigationStack.append(.chat)
        activeDestination = .downloadManager
    }

    /// Navigate to the User Personal profile view.
    /// Uses `navigate(to:)` to push onto the existing stack, so Back returns
    /// to wherever the user came from (settings, welcome, etc.).
    func navigateToUserPersonalProfile() {
        navigate(to: .userPersonalProfile)
    }
}


extension Notification.Name {
    /// Posted when a destination needs the sidebar pane on screen to be usable at all.
    /// The Tool Library is the only such destination today: its navigation IS the pane.
    static let requestSidebarVisible = Notification.Name("dg.requestSidebarVisible")
}

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
    case toolLibrary(profileID: UUID)
    case promptDetail(promptID: UUID)
    case scheduledTaskDetail(taskID: UUID)
    case ollamaModelStore(profileID: UUID)
    case mlxModelStore(profileID: UUID, filterForTools: Bool)
    case downloadManager
}

/// Manages push/pop stack navigation for the main content area.
///
/// The chat view is kept alive via opacity toggling (never torn down),
/// while non-chat destinations are lazily created on demand.
@MainActor
final class MainViewRouter: ObservableObject {
    @Published var activeDestination: MainViewDestination = .chat
    @Published private(set) var navigationStack: [MainViewDestination] = []

    var canGoBack: Bool { !navigationStack.isEmpty }

    var isShowingChat: Bool { activeDestination == .chat }

    /// Push the current destination onto the stack and navigate to a new one.
    func navigate(to destination: MainViewDestination) {
        navigationStack.append(activeDestination)
        activeDestination = destination
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
    func navigateToProfile(_ profileID: UUID) {
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

    /// Navigate to a model store from within a profile detail view.
    /// Pushes the current destination (profile) onto the stack so Back returns to it.
    func navigateToModelStore(backend: ModelBackendType, profileID: UUID, filterForTools: Bool = false) {
        switch backend {
        case .ollama:
            navigate(to: .ollamaModelStore(profileID: profileID))
        case .mlx:
            navigate(to: .mlxModelStore(profileID: profileID, filterForTools: filterForTools))
        }
    }

    /// Navigate to the download manager, clearing any existing non-chat stack first.
    func navigateToDownloadManager() {
        navigationStack.removeAll()
        navigationStack.append(.chat)
        activeDestination = .downloadManager
    }
}

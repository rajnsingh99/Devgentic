// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MainViewRouter.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Represents a destination that can be shown in the main content area.
enum MainViewDestination: Equatable, Hashable {
    case chat
    case profileDetail(profileID: UUID)
    case settingsDetail(category: SettingsCategory)
    /// Profile is optional: the Tool Library is reachable with no backend chosen.
    /// Browsing, MCP servers and Discover need no profile; only per-tool enablement writes to one.
    /// That surface hides itself when there is nothing to write to.
    case toolLibrary(profileID: UUID?)
    /// The skills library: browsing, and the per-profile "link skills to this agent" surface.
    /// Profile is optional: only per-skill linking writes to one, and that surface hides itself without a profile.
    /// Editing one skill is its own screen (`.skillDetail`), so this route carries no skill id.
    case skillLibrary(profileID: UUID?)

    /// One skill, edited inline in the main content area.
    /// Carries no profile: profile-scoped controls (link toggle, pin menu, shell-tool offer) live on the library surface.
    case skillDetail(skillID: String)

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
        case .skillLibrary: return "Skills"
        case .skillDetail: return "Skill"
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
        // A repeat of the current destination, or a lateral move within one surface, replaces instead of pushing,
        // so Back does not walk through the same screen repeatedly (`isLateralMove` is the rule).
        if isLateralMove(from: activeDestination, to: destination) || destination == activeDestination {
            activeDestination = destination
            announceArrival(at: destination)
            return
        }
        navigationStack.append(activeDestination)
        activeDestination = destination
        announceArrival(at: destination)
    }

    /// Whether moving between these destinations is a sideways step within one surface rather than a descent.
    /// Descent still pushes (list to detail) so Back means "back to the list"; detail to detail replaces.
    /// Limited to the skills surface; other routes carrying an item id keep their existing Back behaviour.
    func isLateralMove(from current: MainViewDestination, to next: MainViewDestination) -> Bool {
        switch (current, next) {
        case (.skillDetail, .skillDetail):
            // Detail → detail is one screen whose contents changed. Library → detail is a DESCENT
            // and must push, or Back cannot mean "back to the library".
            return true
        default:
            return false
        }
    }

    // Why: keep one copy: arriving at a skills screen with the pane hidden
    // or Conversations selected leaves the user with no skill list.
    /// The pane/tab side effects of arriving somewhere, shared by the push and replace paths.
    private func announceArrival(at destination: MainViewDestination) {
        // The Tool Library's navigation lives in the sidebar pane, so entering it with the pane
        // hidden would leave no way to change category or pick a server.
        if case .toolLibrary = destination {
            NotificationCenter.default.post(name: .requestSidebarVisible, object: nil)
        }
        // Same for BOTH skills screens — the skill list lives in the pane, and a detail reached
        // with the pane hidden leaves no way to pick another skill or get back to the library.
        if destination.isSkillsSurface {
            NotificationCenter.default.post(name: .requestSidebarVisible, object: nil)
            // Select the Skills tab (not just reveal the pane) through `SidebarTab.storageKey`, the key the container reads.
            // Refused in the test host: the host is the real app, so this would write the developer's own saved tab.
            guard !TestHost.isRunning else { return }
            UserDefaults.standard.set(SidebarTab.skills.rawValue, forKey: SidebarTab.storageKey)
        }
        // Reveal sidebar and set tab when entering settings so the category list is visible.
        if case .settingsDetail = destination {
            NotificationCenter.default.post(name: .requestSidebarVisible, object: nil)
            guard !TestHost.isRunning else { return }
            UserDefaults.standard.set(SidebarTab.settings.rawValue, forKey: SidebarTab.storageKey)
        }
        // Reveal sidebar and set tab when entering profile detail so the profile list is visible.
        if case .profileDetail = destination {
            NotificationCenter.default.post(name: .requestSidebarVisible, object: nil)
            guard !TestHost.isRunning else { return }
            UserDefaults.standard.set(SidebarTab.backendProfiles.rawValue, forKey: SidebarTab.storageKey)
        }
    }

}

extension MainViewDestination {
    /// Both screens that live behind the Skills sidebar tab.
    /// Named once so the pane/tab side effects cover the library and the detail without duplicated `if case` arms.
    var isSkillsSurface: Bool {
        switch self {
        case .skillLibrary, .skillDetail: return true
        default: return false
        }
    }
}

extension MainViewRouter {
    /// Pop the last destination from the stack.
    func goBack() {
        activeDestination = navigationStack.popLast() ?? .chat
        announceArrival(at: activeDestination)
    }

    /// Return directly to chat, clearing the entire stack.
    func returnToChat() {
        navigationStack.removeAll()
        activeDestination = .chat
    }

    /// Navigates to a profile detail, clearing any existing non-chat stack first.
    /// Used when tapping a different profile in the sidebar while already viewing one.
    /// Activates the edit buffer before publishing the destination so the container has it on first render.
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

    /// Navigates to the new-scheduled-task editor, clearing any non-chat stack so Back returns to chat.
    /// `prefillPrompt` and `prefillConversationID` seed the form from the chat input's "Custom..." entry point,
    /// defaulting the run mode to "Continue this conversation" with that conversation selected.
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

    /// Navigates to the download manager, clearing any existing non-chat stack first.
    /// Called from `DownloadSidebarView`'s header.
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
    static let toggleSidebar = Notification.Name("dg.toggleSidebar")
    static let toggleCommandPalette = Notification.Name("dg.toggleCommandPalette")
    static let openFilePicker = Notification.Name("openFilePicker")
    static let newChatSession = Notification.Name("dg.newChatSession")
    static let selectSidebarTab = Notification.Name("dg.selectSidebarTab")
    static let focusChatInput = Notification.Name("dg.focusChatInput")
    static let selectNextConversation = Notification.Name("dg.selectNextConversation")
    static let selectPreviousConversation = Notification.Name("dg.selectPreviousConversation")
    static let renameActiveConversation = Notification.Name("dg.renameActiveConversation")
    static let togglePinActiveConversation = Notification.Name("dg.togglePinActiveConversation")
    static let deleteActiveConversation = Notification.Name("dg.deleteActiveConversation")
    static let exportActiveConversation = Notification.Name("dg.exportActiveConversation")
    static let findInChat = Notification.Name("dg.findInChat")
    static let findNextInChat = Notification.Name("dg.findNextInChat")
    static let findPreviousInChat = Notification.Name("dg.findPreviousInChat")

    // MARK: - Module 4: Library & Tooling Notifications
    static let newPrompt = Notification.Name("dg.newPrompt")
    static let newScheduledTask = Notification.Name("dg.newScheduledTask")
    static let createSkill = Notification.Name("dg.createSkill")
    static let importSkills = Notification.Name("dg.importSkills")
    static let addMCPServer = Notification.Name("dg.addMCPServer")
    static let clearDownloadHistory = Notification.Name("dg.clearDownloadHistory")

    // MARK: - Module 6: Settings & Profiles Notifications
    static let newProfile = Notification.Name("dg.newProfile")
}

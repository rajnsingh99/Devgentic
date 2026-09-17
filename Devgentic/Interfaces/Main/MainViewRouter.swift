// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    /// Profile is OPTIONAL for the same reason the Tool Library's is: the Skills tab is reachable
    /// with no profile chosen (browsing the library, importing, creating), and only per-skill LINKING
    /// writes to one — a surface that hides itself when there is nothing to write to.
    /// `openSkillID` opens that skill's detail sheet on arrival.
    ///
    /// ⚠️ Carried ON THE ROUTE rather than through shared state because the sidebar row and the
    /// library are different views with no other channel between them. Without it the row that
    /// The skills LIBRARY: browsing, and the per-profile "link skills to this agent" surface.
    ///
    /// ⚠️ It no longer names a skill. `openSkillID` lived here and was consumed by turning it into a
    /// `.sheet`, so one destination meant two different screens — and the router's whole push/replace
    /// decision keys on destination identity, which made `(profileID, openSkillID)` ambiguous:
    /// `(X, nil)` the link surface, `(nil, id)` a detail, `(X, id)` undefined. Editing one skill is
    /// its own screen, so it is its own case, matching `.profileDetail` and `.promptDetail`.
    case skillLibrary(profileID: UUID?)

    /// One skill, edited inline in the main content area.
    ///
    /// ⚠️ Carries NO profile. Every profile-scoped control — the link toggle, the pin menu, the
    /// shell-tool offer — lives on the library surface; the detail holds only the skill's own
    /// content. Adding a profile here would recreate the ambiguity the split exists to remove.
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
        // ⚠️ A repeat of where we already are REPLACES rather than pushes. Clicking three skills in
        // the sidebar used to stack three identical library entries, so Back walked through the
        // same screen three times before reaching whatever came before it.
        //
        // ⚠️⚠️ THAT GUARD ONLY EVER COVERED CLICKING THE **SAME** ROW TWICE, and the comment above
        // read as though it covered more. `openSkillID` is part of a destination's identity — which
        // it must be, or routing to a second skill would be a no-op — so skill A then B then C are
        // three DIFFERENT destinations and pushed three entries. Back then walked A←B←C through
        // screens the user experienced as one. `isLateralMove` is the actual rule.
        if isLateralMove(from: activeDestination, to: destination) || destination == activeDestination {
            activeDestination = destination
            announceArrival(at: destination)
            return
        }
        navigationStack.append(activeDestination)
        activeDestination = destination
        announceArrival(at: destination)
    }

    /// Whether moving between these two destinations is a sideways step within one surface rather
    /// than a descent into a new one.
    ///
    /// ⚠️ DESCENT STILL PUSHES, and that asymmetry is the whole point rather than an oversight. A
    /// list → detail move must push, because that is what makes Back mean "back to the list"; a
    /// detail → detail move must replace, because the user experienced one screen whose contents
    /// changed. Treating every same-case move as lateral would collapse both, leaving Back to pop
    /// straight past the list to whatever preceded it.
    ///
    /// ⚠️ Deliberately limited to the skills surface. The same stacking exists in principle wherever
    /// a route carries an item id, but changing `.profileDetail` or `.promptDetail` would alter Back
    /// on surfaces this change did not audit — and a routing change that "looks obviously right
    /// everywhere" is how a Back button starts skipping a screen nobody tested.
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

    /// The pane/tab side effects of arriving somewhere, shared by the push and replace paths.
    ///
    /// ⚠️⚠️ ONE COPY, DELIBERATELY. These side effects used to be duplicated byte-for-byte in the
    /// push branch of `navigate(to:)` and here, so a new destination that needed them had to be
    /// added to BOTH — and the source-reading guard test only greps for the first occurrence, so
    /// omitting the second would have stayed green. Arriving at a skills screen with the pane
    /// hidden (⌘B) or with Conversations selected strands the user with no skill list, which is
    /// exactly the failure that omission produces.
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
            // ⚠️ Revealing the pane is not enough — it shows whichever tab was last selected. The
            // library's empty state points at the Skills sidebar to add one, so arriving from the
            // profile editor's "Manage Skills" button with Conversations selected instructed an
            // action that was nowhere on screen. Selecting the tab is what makes the instruction
            // true. Written through the same @AppStorage key the menu command uses
            // (SidebarTab.storageKey), because that is the one the container reads.
            // ⚠️⚠️ REFUSED IN THE TEST HOST, and this was found the hard way — by a test run
            // changing the developer's own saved sidebar tab on their real machine.
            //
            // The test host IS the app, so this line wrote `SidebarTab.storageKey` in the REAL user
            // defaults every time any test called `navigate(to: .skillLibrary…)`. Two consequences,
            // and the second is why the crash was so confusing: the user's remembered tab silently
            // became Skills, and the host app then BOOTED into the Skills screen, whose live views
            // hold `SkillSD` objects — so any test that swapped `SkillStore`'s container left those
            // views dereferencing models destroyed by `ModelContext.reset`, killing the host.
            //
            // The codebase already had this rule: `SkillLibraryMigration.captureURL` redirects on
            // `TestHost.isRunning` for exactly this reason, and its comment says the per-test
            // override was not enough "precisely because the write happened somewhere no test
            // explicitly called". Same shape, same fix.
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
    ///
    /// ⚠️ Named rather than pattern-matched at each site: the pane/tab side effects apply to the
    /// library AND the detail, and adding a third skills screen later must not require remembering
    /// two separate `if case` arms — which is exactly the duplication that made the previous version
    /// of `announceArrival` easy to half-update.
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
    ///
    /// ⚠️ Called from `DownloadSidebarView`'s header. It had NO caller until 2026-09-15, which made
    /// `DownloadManagerContainerView` unreachable — `MainApplicationView` rendered it for
    /// `.downloadManager` and nothing could ever set that destination. The sidebar already held
    /// `@Environment(MainViewRouter.self)` for the call that was never written.
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

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  CommandPaletteView.swift
//  Devgentic
//
//  Universal Command Palette (⌘K) for quick navigation, mode switching, and actions.
//

import SwiftUI
import SwiftData

struct CommandPaletteView: View {

    @Binding var isPresented: Bool
    @Binding var isSidebarVisible: Bool

    @Environment(\.appTheme) private var theme
    @Environment(MainApplicationViewModel.self) private var viewModel
    @Environment(MainViewRouter.self) private var router
    @Environment(BackendProfileService.self) private var profileService
    @Environment(\.openWindow) private var openWindow

    @Query(sort: \ConversationSD.timestamp, order: .reverse)
    private var allConversations: [ConversationSD]

    @State private var searchText: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isSearchFocused: Bool

    @AppStorage(SidebarTab.storageKey) private var selectedTabRawValue: String = SidebarTab.conversations.rawValue

    private var paletteItems: [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        // MARK: - Interface Modes
        items.append(
            CommandPaletteItem(
                title: "Switch to Chat Mode",
                subtitle: "Direct conversation interface",
                icon: "bubble.left.and.text.bubble.right",
                category: .mode,
                shortcutBadge: ["⌃", "1"],
                keywords: ["chat", "talk", "messages"]
            ) {
                viewModel.switchInterfaceMode(to: .chat)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Switch to Workflow Canvas",
                subtitle: "Multi-agent node orchestration",
                icon: "point.3.connected.trianglepath.dotted",
                category: .mode,
                shortcutBadge: ["⌃", "2"],
                keywords: ["workflow", "canvas", "nodes", "graph"]
            ) {
                viewModel.switchInterfaceMode(to: .workflow)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Switch to Code Workspace",
                subtitle: "Developer workspace & code sessions",
                icon: "chevron.left.forwardslash.chevron.right",
                category: .mode,
                shortcutBadge: ["⌃", "3"],
                keywords: ["code", "developer", "ide", "workspace"]
            ) {
                viewModel.switchInterfaceMode(to: .code)
            }
        )

        // MARK: - Actions
        items.append(
            CommandPaletteItem(
                title: "New Chat / Session",
                subtitle: "Start fresh conversation or return to Welcome",
                icon: "plus.message.fill",
                category: .action,
                shortcutBadge: ["⌘", "N"],
                keywords: ["new", "create", "start", "fresh"]
            ) {
                if viewModel.interfaceMode == .workflow || viewModel.interfaceMode == .code {
                    viewModel.deselectConversationAndShowWelcome()
                } else {
                    viewModel.startNewConversation()
                }
                if isSidebarVisible { isSidebarVisible = false }
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Add Context / Attach Files",
                subtitle: "Select files or folders to attach",
                icon: "paperclip",
                category: .action,
                shortcutBadge: ["⌘", "O"],
                keywords: ["attach", "files", "context", "open", "upload"]
            ) {
                NotificationCenter.default.post(name: NSNotification.Name("openFilePicker"), object: nil)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Toggle Sidebar",
                subtitle: isSidebarVisible ? "Hide navigation sidebar" : "Show navigation sidebar",
                icon: "sidebar.left",
                category: .action,
                shortcutBadge: ["⌘", "B"],
                keywords: ["sidebar", "panel", "drawer", "activity bar"]
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSidebarVisible.toggle()
                }
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Toggle Voice Input",
                subtitle: "Start or stop microphone dictation",
                icon: "mic.fill",
                category: .action,
                shortcutBadge: ["⇧", "⌘", "V"],
                keywords: ["voice", "microphone", "dictate", "speak"]
            ) {
                NotificationCenter.default.post(name: GlobalConstants.toggleVoiceInputNotification, object: nil)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Go to Welcome Screen",
                subtitle: "Deselect conversation and view greeting & widgets",
                icon: "house.fill",
                category: .action,
                shortcutBadge: ["⇧", "⌘", "H"],
                keywords: ["home", "welcome", "dashboard"]
            ) {
                if !router.isShowingChat { router.returnToChat() }
                viewModel.deselectConversationAndShowWelcome()
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Keyboard Shortcuts Reference",
                subtitle: "View cheatsheet of all keyboard shortcuts",
                icon: "command",
                category: .action,
                shortcutBadge: ["⌘", "/"],
                keywords: ["shortcuts", "hotkeys", "cheatsheet", "help", "keys"]
            ) {
                openWindow(id: "shortcuts-window")
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Observability Trends",
                subtitle: "Inspect tool reliability & metrics",
                icon: "chart.xyaxis.line",
                category: .action,
                shortcutBadge: ["⌥", "⇧", "⌘", "T"],
                keywords: ["trends", "telemetry", "metrics", "observability", "logs"]
            ) {
                openWindow(id: "trends-window")
            }
        )

        items.append(
            CommandPaletteItem(
                title: "Focus Chat Composer",
                subtitle: "Jump cursor directly to the prompt input",
                icon: "character.cursor.ibeam",
                category: .action,
                shortcutBadge: ["⌘", "L"],
                keywords: ["focus", "input", "composer", "type", "prompt", "chat"]
            ) {
                NotificationCenter.default.post(name: .focusChatInput, object: nil)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Find in Chat",
                subtitle: "Search messages in current conversation",
                icon: "magnifyingglass",
                category: .action,
                shortcutBadge: ["⌘", "F"],
                keywords: ["search", "find", "filter", "messages", "query"]
            ) {
                NotificationCenter.default.post(name: .findInChat, object: nil)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Next Conversation",
                subtitle: "Select the next conversation in the sidebar",
                icon: "arrow.down",
                category: .navigation,
                shortcutBadge: ["⌥", "⌘", "↓"],
                keywords: ["next", "down", "conversation", "chat", "forward"]
            ) {
                NotificationCenter.default.post(name: .selectNextConversation, object: nil)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Previous Conversation",
                subtitle: "Select the previous conversation in the sidebar",
                icon: "arrow.up",
                category: .navigation,
                shortcutBadge: ["⌥", "⌘", "↑"],
                keywords: ["previous", "up", "conversation", "chat", "back"]
            ) {
                NotificationCenter.default.post(name: .selectPreviousConversation, object: nil)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Rename Active Conversation",
                subtitle: "Edit the title of the selected conversation",
                icon: "pencil",
                category: .action,
                shortcutBadge: ["⇧", "⌘", "R"],
                keywords: ["rename", "title", "edit", "name"]
            ) {
                NotificationCenter.default.post(name: .renameActiveConversation, object: nil)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Pin / Unpin Active Conversation",
                subtitle: "Toggle pinned status for quick access",
                icon: "pin.fill",
                category: .action,
                shortcutBadge: ["⌘", "P"],
                keywords: ["pin", "favorite", "star", "bookmark", "unpin"]
            ) {
                NotificationCenter.default.post(name: .togglePinActiveConversation, object: nil)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Export Conversation as Markdown",
                subtitle: "Export full transcript to Markdown file",
                icon: "square.and.arrow.up",
                category: .action,
                shortcutBadge: ["⇧", "⌘", "S"],
                keywords: ["export", "markdown", "save", "share", "transcript"]
            ) {
                NotificationCenter.default.post(name: .exportActiveConversation, object: nil)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Delete Active Conversation",
                subtitle: "Permanently delete the selected conversation",
                icon: "trash.fill",
                category: .action,
                shortcutBadge: ["⌘", "⌫"],
                keywords: ["delete", "remove", "trash", "destroy"]
            ) {
                NotificationCenter.default.post(name: .deleteActiveConversation, object: nil)
            }
        )

        // MARK: - Library & Tooling Actions
        items.append(
            CommandPaletteItem(
                title: "New Prompt",
                subtitle: "Create a new prompt template in the library",
                icon: "plus.square.fill",
                category: .action,
                shortcutBadge: ["⌘", "N"],
                keywords: ["prompt", "new", "template", "create"]
            ) {
                selectedTabRawValue = SidebarTab.promptLibrary.rawValue
                isSidebarVisible = true
                NotificationCenter.default.post(name: .newPrompt, object: nil)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "New Scheduled Task",
                subtitle: "Schedule a recurring or autonomous agent run",
                icon: "clock.badge.checkmark",
                category: .action,
                shortcutBadge: ["⌘", "N"],
                keywords: ["schedule", "task", "cron", "new", "job"]
            ) {
                router.navigateToNewTask()
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Create New Skill",
                subtitle: "Write a custom agent capability from scratch",
                icon: "square.and.pencil",
                category: .action,
                shortcutBadge: ["⌘", "N"],
                keywords: ["skill", "create", "write", "new", "agent"]
            ) {
                selectedTabRawValue = SidebarTab.skills.rawValue
                isSidebarVisible = true
                NotificationCenter.default.post(name: .createSkill, object: nil)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Import Skills...",
                subtitle: "Import skills from folder, archive, or .md file",
                icon: "square.and.arrow.down",
                category: .action,
                shortcutBadge: ["⌘", "I"],
                keywords: ["skill", "import", "zip", "folder", "load"]
            ) {
                selectedTabRawValue = SidebarTab.skills.rawValue
                isSidebarVisible = true
                NotificationCenter.default.post(name: .importSkills, object: nil)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Add Custom MCP Server",
                subtitle: "Configure and connect an external tool server",
                icon: "plus.circle",
                category: .action,
                shortcutBadge: ["⌘", "N"],
                keywords: ["mcp", "tool", "server", "custom", "add"]
            ) {
                router.navigate(to: .addMCPServer)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Browse MCP Marketplace",
                subtitle: "Discover and install official MCP server registries",
                icon: "storefront",
                category: .action,
                keywords: ["mcp", "marketplace", "registry", "browse", "discover", "tools"]
            ) {
                ToolLibraryNavigationState.shared.section = .mcp
                ToolLibraryNavigationState.shared.selectedSidebar = .marketplace
                router.navigate(to: .toolLibrary(profileID: nil))
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Clear Download History",
                subtitle: "Remove completed and cancelled records from download history",
                icon: "trash",
                category: .action,
                keywords: ["downloads", "clear", "clean", "history", "purge"]
            ) {
                selectedTabRawValue = SidebarTab.downloads.rawValue
                isSidebarVisible = true
                NotificationCenter.default.post(name: .clearDownloadHistory, object: nil)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "New Backend Profile...",
                subtitle: "Create a new AI agent, bot, or image generation profile",
                icon: "plus.circle",
                category: .action,
                shortcutBadge: ["⌘", "N"],
                keywords: ["profile", "agent", "backend", "new", "create", "bot", "imagegen"]
            ) {
                selectedTabRawValue = SidebarTab.backendProfiles.rawValue
                isSidebarVisible = true
                NotificationCenter.default.post(name: .newProfile, object: nil)
            }
        )

        // MARK: - Navigation Tabs
        items.append(
            CommandPaletteItem(
                title: "Go to Chats",
                subtitle: "Browse conversation history",
                icon: "message",
                category: .navigation,
                shortcutBadge: ["⌘", "⌥", "1"],
                keywords: ["chats", "conversations", "history"]
            ) {
                selectedTabRawValue = SidebarTab.conversations.rawValue
                isSidebarVisible = true
                if !router.isShowingChat { router.returnToChat() }
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Go to Explorer",
                subtitle: "Project directory and files",
                icon: "folder",
                category: .navigation,
                shortcutBadge: ["⌘", "⇧", "E"],
                keywords: ["explorer", "files", "folder", "tree", "directory"]
            ) {
                selectedTabRawValue = SidebarTab.explorer.rawValue
                isSidebarVisible = true
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Go to Prompt Library",
                subtitle: "Browse and edit reusable prompts",
                icon: "square.stack.3d.up.fill",
                category: .navigation,
                shortcutBadge: ["⌘", "⌥", "3"],
                keywords: ["prompts", "templates", "library"]
            ) {
                selectedTabRawValue = SidebarTab.promptLibrary.rawValue
                isSidebarVisible = true
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Go to Scheduler",
                subtitle: "Automated recurring tasks",
                icon: "clock.badge",
                category: .navigation,
                shortcutBadge: ["⌘", "⌥", "4"],
                keywords: ["scheduler", "tasks", "cron", "recurring"]
            ) {
                selectedTabRawValue = SidebarTab.scheduler.rawValue
                isSidebarVisible = true
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Go to Backend Profiles",
                subtitle: "Manage AI agents, models and providers",
                icon: "cpu",
                category: .navigation,
                shortcutBadge: ["⇧", "⌘", "P"],
                keywords: ["profiles", "backends", "models", "agents", "llm"]
            ) {
                if let first = profileService.sharedProfiles.first {
                    router.navigateToProfile(first.id, activatingBufferOn: profileService)
                } else {
                    selectedTabRawValue = SidebarTab.backendProfiles.rawValue
                    isSidebarVisible = true
                    router.returnToChat()
                }
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Go to Tool Library & MCP",
                subtitle: "Manage MCP servers and capabilities",
                icon: "wrench.and.screwdriver",
                category: .navigation,
                shortcutBadge: ["⌘", "⌥", "6"],
                keywords: ["tools", "mcp", "servers", "capabilities"]
            ) {
                router.navigate(to: .toolLibrary(profileID: nil))
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Go to Skills Library",
                subtitle: "Browse and import agent skills",
                icon: "puzzlepiece",
                category: .navigation,
                shortcutBadge: ["⌘", "⌥", "7"],
                keywords: ["skills", "abilities", "functions"]
            ) {
                router.navigate(to: .skillLibrary(profileID: nil))
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Go to Download Manager",
                subtitle: "Check model and asset download progress",
                icon: "arrow.down.circle",
                category: .navigation,
                shortcutBadge: ["⌘", "⌥", "8"],
                keywords: ["downloads", "manager", "progress", "history"]
            ) {
                router.navigate(to: .downloadManager)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Go to Settings",
                subtitle: "Configure preferences, appearance, and audio",
                icon: "gearshape",
                category: .navigation,
                shortcutBadge: ["⌘", ","],
                keywords: ["settings", "preferences", "config"]
            ) {
                router.navigateToSettings(.general)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Settings: General",
                subtitle: "Speech, notifications, and local storage preferences",
                icon: "gear",
                category: .navigation,
                keywords: ["settings", "general", "speech", "storage", "notifications"]
            ) {
                router.navigateToSettings(.general)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Settings: Core Intelligence",
                subtitle: "On-device intelligence and ML acceleration",
                icon: "cpu.fill",
                category: .navigation,
                keywords: ["settings", "core", "intelligence", "neural", "metal", "acceleration"]
            ) {
                router.navigateToSettings(.coreIntelligence)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Settings: Theme & Appearance",
                subtitle: "Colors, typography, contrast, and surface effects",
                icon: "paintbrush",
                category: .navigation,
                keywords: ["settings", "theme", "appearance", "dark", "light", "typography", "colors"]
            ) {
                router.navigateToSettings(.theme)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Settings: ChatOps",
                subtitle: "Remote Telegram and Slack control bot settings",
                icon: "paperplane.fill",
                category: .navigation,
                keywords: ["settings", "chatops", "telegram", "slack", "remote", "bot"]
            ) {
                router.navigateToSettings(.chatOps)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Settings: Quick Access",
                subtitle: "Global hotkey and floating HUD panel options",
                icon: "bolt.circle",
                category: .navigation,
                keywords: ["settings", "quick", "access", "floating", "panel", "hud", "hotkey"]
            ) {
                router.navigateToSettings(.quickAccess)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Settings: Jarvis Assistant",
                subtitle: "Voice assistant, wake word, and live listening",
                icon: "atom",
                category: .navigation,
                keywords: ["settings", "jarvis", "voice", "assistant", "listening", "speech"]
            ) {
                router.navigateToSettings(.jarvis)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Settings: About & Licenses",
                subtitle: "Devgentic version, build info, and third-party notices",
                icon: "info.circle",
                category: .navigation,
                keywords: ["settings", "about", "version", "licenses", "credits", "legal"]
            ) {
                router.navigateToSettings(.about)
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Open MLX Model Store",
                subtitle: "Browse Apple Silicon optimized models",
                icon: "shippingbox",
                category: .navigation,
                keywords: ["mlx", "huggingface", "apple silicon", "store"]
            ) {
                router.navigate(to: .mlxModelStore(profileID: UUID(), filterForTools: false))
            }
        )
        items.append(
            CommandPaletteItem(
                title: "Open Ollama Model Store",
                subtitle: "Manage local Ollama models",
                icon: "cube.box",
                category: .navigation,
                keywords: ["ollama", "local models", "store"]
            ) {
                router.navigate(to: .ollamaModelStore(profileID: UUID()))
            }
        )

        // MARK: - Recent Conversations
        // ⚠️ Titles derive from `toRowStruct().displayTitle`, NOT the `ConversationSD.displayTitle`
        // extension in ConversationSidebarView — that one is `userDefinedTitle` or the literal
        // "New Conversation", with no first-message fallback, so every untitled conversation would
        // render identically here and never match a search on its own content. The sidebar rows and
        // the ChatOps `ConversationRow` bridge both render this one; matching them is deliberate.
        //
        // `toRowStruct()` decodes message blobs to find that fallback and `paletteItems` re-runs on
        // every keystroke, so the projection stays lazy: the unfiltered path touches only 4
        // conversations, and the filtered one stops at the 4th match.
        let clean = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let titled = allConversations.lazy.map { (id: $0.id, title: $0.toRowStruct().displayTitle) }
        let matchingConversations: [(id: UUID, title: String)]
        if clean.isEmpty {
            matchingConversations = Array(titled.prefix(4))
        } else {
            matchingConversations = Array(
                titled.filter { $0.title.lowercased().contains(clean) }.prefix(4)
            )
        }

        for conv in matchingConversations {
            items.append(
                CommandPaletteItem(
                    id: "conv-\(conv.id)",
                    // `displayTitle` falls back to "New Chat"; it is never empty.
                    title: conv.title,
                    subtitle: "Jump to conversation",
                    icon: "bubble.left",
                    category: .recentChat,
                    keywords: [conv.title]
                ) {
                    if !router.isShowingChat { router.returnToChat() }
                    viewModel.selectedConversationID = conv.id
                }
            )
        }

        return items
    }

    private var filteredItems: [CommandPaletteItem] {
        let clean = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !clean.isEmpty else { return paletteItems }
        return paletteItems.filter { $0.matches(query: clean) }
    }

    var body: some View {
        ZStack {
            // Blurred Dismiss Backdrop
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            // Palette Card
            VStack(spacing: 0) {
                searchHeaderView
                Divider().opacity(0.5)
                resultsListView
            }
            .frame(width: 620)
            .background(theme.primaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(theme.surfaceOverlayStrong, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.3), radius: 24, x: 0, y: 10)
            .padding(.top, 90)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
        }
        .onExitCommand {
            dismiss()
        }
    }

    // MARK: - Search Header

    private var searchHeaderView: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(theme.accentColor)

            TextField("Type a command, screen name, or search chats…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundColor(theme.primaryText)
                .focused($isSearchFocused)
                .onChange(of: searchText) { _, _ in
                    selectedIndex = 0
                }
                .onSubmit {
                    executeSelected()
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }

            Text("Esc")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(theme.surfaceOverlay)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Results List

    private var resultsListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if filteredItems.isEmpty {
                    emptyResultsView
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                            paletteRow(item: item, index: index)
                                .id(item.id)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                }
            }
            .frame(maxHeight: 340)
            .onMoveCommand { direction in
                switch direction {
                case .down:
                    if selectedIndex < filteredItems.count - 1 {
                        selectedIndex += 1
                        proxy.scrollTo(filteredItems[selectedIndex].id, anchor: .center)
                    }
                case .up:
                    if selectedIndex > 0 {
                        selectedIndex -= 1
                        proxy.scrollTo(filteredItems[selectedIndex].id, anchor: .center)
                    }
                default: break
                }
            }
        }
    }

    // MARK: - Row

    private func paletteRow(item: CommandPaletteItem, index: Int) -> some View {
        let isSelected = index == selectedIndex

        return HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(theme.primaryText)

                if let sub = item.subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let badges = item.shortcutBadge {
                HStack(spacing: 3) {
                    ForEach(badges, id: \.self) { badge in
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(theme.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(theme.surfaceOverlayStrong, lineWidth: 0.8)
                            )
                    }
                }
            }

            Text(item.category.rawValue)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(theme.surfaceOverlay)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? theme.surfaceOverlayStrong : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedIndex = index
            executeSelected()
        }
    }

    // MARK: - Empty State

    private var emptyResultsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(theme.tertiaryText.opacity(0.6))
            Text("No matching commands")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Actions

    private func executeSelected() {
        guard filteredItems.indices.contains(selectedIndex) else { return }
        let item = filteredItems[selectedIndex]
        dismiss()
        item.action()
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.15)) {
            isPresented = false
        }
    }
}

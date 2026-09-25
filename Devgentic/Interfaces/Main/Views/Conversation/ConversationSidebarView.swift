// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationSidebarView.swift
//  Devgentic
//
//  Created by Raj Singh on 28/02/26.
//

import Foundation
import SwiftUI
import SwiftData
import os

private let logger = DGLogger(category: "ConversationSidebarView")


// MARK: - ConversationSD Extension
/// Extensions to `ConversationSD` to provide stable, computed properties for the UI.
extension ConversationSD {

    /// Computes a user-friendly display title for the conversation.
    /// It prioritizes a user-defined title or defaults to "New Conversation".
    var displayTitle: String {
        if let userTitle = userDefinedTitle, !userTitle.isEmpty {
            return userTitle
        }
        return "New Conversation"
    }
}



// MARK: - Sidebar Empty State
/// Displayed when there are no conversations available.

// MARK: - Sidebar Group Header View
/// A custom disclosure group header representing categories (e.g., "Pinned").
struct SidebarGroupHeaderView: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool

    @State private var isHovering = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "chevron.right")
                .font(theme.fontCaption2.weight(.semibold))
                .foregroundColor(theme.secondaryText.opacity(0.5))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isExpanded)
                .frame(width: 16)

            Text(title)
                .font(theme.fontCaption.weight(.semibold))
                .foregroundColor(theme.secondaryText)
                .padding(.leading, 2)

            Text("\(count)")
                .font(theme.fontCaption2.weight(.medium))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(theme.surfaceOverlay)
                .clipShape(Capsule())
                .padding(.leading, 6)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? theme.surfaceOverlay : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                isExpanded.toggle()
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
    }
}

/// A project's header in the Code sidebar: folder name, a collapse chevron, and — on hover — a
/// "+" that starts a new session in that folder.
struct CodeProjectHeaderView: View {
    let title: String
    let path: String?
    let isMissing: Bool
    @Binding var isExpanded: Bool
    let onNewSession: (() -> Void)?

    @State private var isHovering = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(theme.fontCaption2.weight(.semibold))
                .foregroundColor(theme.secondaryText.opacity(0.5))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)

            Image(systemName: path == nil ? "tray" : (isMissing ? "folder.badge.questionmark" : "folder"))
                .font(theme.fontCaption)
                .foregroundColor(theme.secondaryText)

            Text(title)
                .font(theme.fontCaption.weight(.semibold))
                .foregroundColor(isMissing ? theme.tertiaryText : theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if let onNewSession, isHovering, !isMissing {
                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(theme.fontCaption.weight(.semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "New session in \(title)"))
                .accessibilityLabel(String(localized: "New session in \(title)"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? theme.surfaceOverlay : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isExpanded.toggle() }
        }
        .onHover { isHovering = $0 }
        .help(isMissing
              ? String(localized: "\(path ?? "") — this folder was moved or deleted. Its sessions can be read but not continued.")
              : (path ?? String(localized: "Sessions from before project folders were recorded")))
    }
}

/// Wrapper around `ConversationRowView` that specifically handles sidebar behaviors
/// such as context menus (pinning, renaming, deleting) and inline state preparation.
struct ConversationSidebarRow: View {
    let conversation: ConversationSD

    /// [B] Whether a background task in this conversation will report into it when it ends.
    /// Refreshed from `.backgroundTaskChanged`; see the handler for why it is not a bare read.
    @State private var hasPendingBackgroundReport: Bool = false

    var viewModel: MainApplicationViewModel
    @Environment(MainViewRouter.self) private var router

    // Inline Renaming State
    @Binding var renamingConversationID: UUID?
    @Binding var editableConversationName: String
    var isRenameFieldFocused: FocusState<Bool>.Binding

    // Deletion State
    @Binding var conversationToDelete: ConversationSD?
    @Binding var showingDeleteAlert: Bool

    // Batch Selection
    @Binding var isSelectionMode: Bool
    @Binding var selectedIDs: Set<UUID>

    var body: some View {
        ConversationRowView(
            // [P1] Row-weight projection: `toStruct()` decoded EVERY message's four
            // JSON blobs per row per render (MainActor, re-run on every mid-stream
            // flush). `toRowStruct()` decodes at most one content blob for the title.
            conversation: conversation.toRowStruct(),
            isSelected: viewModel.selectedConversationID == conversation.id,
            isRenaming: renamingConversationID == conversation.id,
            editableName: $editableConversationName,
            isRenameFieldFocused: isRenameFieldFocused,
            onSelect: {
                handleSelection()
            },
            onCommitRename: {
                if let id = renamingConversationID {
                    viewModel.renameConversation(conversationID: id, newTitle: editableConversationName)
                }
                renamingConversationID = nil
            },
            onDelete: {
                triggerDelete()
            },
            isSelectionMode: isSelectionMode,
            isBatchSelected: selectedIDs.contains(conversation.id),
            needsInput: viewModel.interactionCenter.hasPending(for: conversation.id),   // [F2]
            // [P8] Live truth from the stream manager (observable — the row updates the
            // moment a stream starts/ends). First time the pulse has ever been reachable.
            isStreamingLive: viewModel.activeStreamManager.hasActiveStream(inConversation: conversation.id),
            // [B] Not observable — `BackgroundProcessRegistry` is an `NSLock`-guarded singleton,
            // not an `@Observable`, so a bare read here would never redraw. State + the same
            // `.backgroundTaskChanged` notice the pill and the footer listen to.
            hasPendingBackgroundReport: hasPendingBackgroundReport
        )
        .contextMenu {
            contextMenuContent
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            enterSelectionMode()
        }
        .onAppear(perform: reloadPendingBackgroundReport)
        .onReceive(NotificationCenter.default.publisher(for: .backgroundTaskChanged)) { note in
            // ⚠️ Scoped to THIS row's conversation. Every row in the sidebar observes this notice,
            // so an unfiltered handler would recompute the registry once per row per task event.
            guard note.userInfo?[BackgroundTaskNotificationKey.conversationID] as? UUID == conversation.id
            else { return }
            reloadPendingBackgroundReport()
        }
    }

    private func reloadPendingBackgroundReport() {
        hasPendingBackgroundReport = PendingBackgroundReports.count(forConversation: conversation.id) > 0
    }

    private func handleSelection() {
        if isSelectionMode {
            toggleBatchSelection()
        } else {
            // Guarded: if a workflow canvas has unsaved edits, prompt Save/Discard/Cancel
            // before switching conversations (otherwise the edits are silently lost).
            viewModel.workflowEditGuard.attempt {
                viewModel.selectedConversationID = conversation.id
                // Return to chat if currently viewing a non-chat destination
                if !router.isShowingChat {
                    router.returnToChat()
                }
            }
        }
    }

    private func toggleBatchSelection() {
        let id = conversation.id
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }

        // Auto-exit if nothing selected? No, let user cancel.
    }

    private func enterSelectionMode() {
        let id = conversation.id
        isSelectionMode = true
        selectedIDs.insert(id)
    }

    // MARK: - Context Menu
    @ViewBuilder
    private var contextMenuContent: some View {
        if isSelectionMode {
            let isSelected = selectedIDs.contains(conversation.id)
            Button {
                toggleBatchSelection()
            } label: {
                Label(
                    isSelected ? "Deselect" : "Select",
                    systemImage: isSelected ? "minus.circle" : "checkmark.circle"
                )
            }
        } else {
            Button {
                enterSelectionMode()
            } label: {
                Label("Select", systemImage: "checkmark.circle")
            }
        }

        Divider()

        Button {
            viewModel.togglePinStatus(for: conversation.id)
        } label: {
            if conversation.isPinned {
                Label("Unpin", systemImage: "pin.slash")
            } else {
                Label("Pin", systemImage: "pin")
            }
        }
        .tint(conversation.isPinned ? .gray : .primary)

        Button {
            prepareForRename()
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            viewModel.exportConversation(conversationID: conversation.id)
        } label: {
            Label("Export to Markdown", systemImage: "square.and.arrow.up")
        }

        Divider()

        Button(role: .destructive) {
            triggerDelete()
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Actions
    private func prepareForRename() {
        self.editableConversationName = conversation.displayTitle
        self.renamingConversationID = conversation.id

        // Slight delay ensures the TextField is rendered before forcing focus
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            self.isRenameFieldFocused.wrappedValue = true
        }
    }

    private func triggerDelete() {
        self.conversationToDelete = conversation
        self.showingDeleteAlert = true
    }
}

/// The main orchestrator view for the sidebar.
/// Manages fetching conversations, sorting them into time-based groups, and coordinating state.

struct ConversationSidebarView: View {
    @Environment(MainApplicationViewModel.self) var viewModel
    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme

    // MARK: - Data Fetching
    @Query(sort: \ConversationSD.timestamp, order: .reverse) private var conversations: [ConversationSD]

    // MARK: - Filter
    private enum ConversationFilter: String, CaseIterable {
        case all = "All"
        case pinned = "Pinned"

        /// Display form — `Text(rawValue)` does not localize (audit C2).
        var localizedTitle: LocalizedStringKey {
            switch self {
            case .all:    return "All"
            case .pinned: return "Pinned"
            }
        }
    }
    @State private var selectedFilter: ConversationFilter = .all

    // MARK: - View State
    @State private var searchText = ""
    @State private var showingDeleteAlert = false
    @State private var conversationToDelete: ConversationSD? = nil

    // Renaming State
    @State private var renamingConversationID: UUID?
    @State private var editableConversationName: String = ""
    @FocusState private var isRenameFieldFocused: Bool

    @State private var isPinnedExpanded: Bool = true

    // Code sidebar: per-project collapse and "Show more", by project path ("" = No project).
    @State private var collapsedProjects: Set<String> = []
    @State private var fullyShownProjects: Set<String> = []
    private static let collapsedProjectsKey = "codeSidebarCollapsedProjects"

    // Batch Selection State
    @State private var selectedConversationIDs: Set<UUID> = []
    @State private var isSelectionMode: Bool = false
    @State private var showingBatchDeleteAlert: Bool = false

    // MARK: - Mode-Aware Properties

    private var sidebarTitle: LocalizedStringKey {
        switch viewModel.interfaceMode {
        case .workflow: return "Workflows"
        case .code:     return "Projects"
        case .chat:     return "Chats"
        }
    }

    private var newButtonTitle: LocalizedStringKey {
        switch viewModel.interfaceMode {
        case .workflow: return "New Workflow"
        case .code:     return "New Session"
        case .chat:     return "New Chat"
        }
    }

    private var searchPlaceholder: String {
        switch viewModel.interfaceMode {
        case .workflow: return "Search workflows..."
        case .code:     return "Search sessions and projects..."
        case .chat:     return "Search conversations..."
        }
    }

    private var emptyStateTitle: LocalizedStringKey {
        viewModel.interfaceMode == .workflow ? "No Workflow Runs Yet" : "No Conversations Yet"
    }

    private var emptyStateSubtitle: LocalizedStringKey {
        viewModel.interfaceMode == .workflow ? "Select a workflow profile and run it" : "Start a new chat to begin exploring"
    }

    private var emptyStateIcon: String {
        viewModel.interfaceMode == .workflow ? "point.3.connected.trianglepath.dotted" : "bubble.left.and.text.bubble.right"
    }

    private var emptyStateActionTitle: LocalizedStringKey {
        switch viewModel.interfaceMode {
        case .workflow: return "Select a Workflow"
        case .code:     return "Start a Code Session"
        case .chat:     return "Start a Conversation"
        }
    }

    private var pinnedEmptyTitle: LocalizedStringKey {
        switch viewModel.interfaceMode {
        case .workflow: return "No Pinned Workflows"
        case .code:     return "No Pinned Code Sessions"
        case .chat:     return "No Pinned Chats"
        }
    }

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {

            if isSelectionMode {
                batchHeaderRow
                    .transition(.opacity)
            } else {
                SidebarHeaderView(
                    title: sidebarTitle,
                    buttonTitle: newButtonTitle,
                    systemImage: "plus",
                    shortcut: "⌘N",
                    onAction: {
                        // Workflow + Code both need full reset (deselect clears profile + code session).
                        // Chat just creates a new empty conversation.
                        if viewModel.interfaceMode == .workflow || viewModel.interfaceMode == .code {
                            viewModel.deselectConversationAndShowWelcome()
                        } else {
                            viewModel.startNewConversation()
                        }
                    }
                )
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

                SidebarSearchBarView(searchPlaceholder, text: $searchText)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)

                // MARK: - Filter Chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ConversationFilter.allCases, id: \.self) { filter in
                            CategoryChip(
                                title: filter.localizedTitle,
                                isSelected: selectedFilter == filter,
                                action: { selectedFilter = filter }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.bottom, 10)
            }

            if filteredConversationCount == 0 && searchText.isEmpty {
                SidebarEmptyStateView(
                    title: emptyStateTitle,
                    subtitle: emptyStateSubtitle,
                    buttonTitle: emptyStateActionTitle,
                    systemImage: emptyStateIcon,
                    onAction: {
                        if viewModel.interfaceMode == .workflow || viewModel.interfaceMode == .code {
                            viewModel.deselectConversationAndShowWelcome()
                        } else {
                            viewModel.startNewConversation()
                        }
                    }
                )
            } else {
                conversationList
            }
        }
        .background(Color.clear)
        .alert("Delete Conversation?", isPresented: $showingDeleteAlert, presenting: conversationToDelete) { conv in
            Button("Delete", role: .destructive) {
                viewModel.deleteConversation(conversationID: conv.id)
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete \(selectedConversationIDs.count) Conversations?", isPresented: $showingBatchDeleteAlert) {
            Button("Delete All", role: .destructive) {
                confirmBatchDelete()
            }
        } message: {
            Text("This will permanently delete \(selectedConversationIDs.count) conversations. This cannot be undone.")
        }
        .onAppear {
            isPinnedExpanded = UserDefaults.standard.object(forKey: "sidebarPinnedExpanded_v2") as? Bool ?? true
            collapsedProjects = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedProjectsKey) ?? [])
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectNextConversation)) { _ in
            selectNextConversation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectPreviousConversation)) { _ in
            selectPreviousConversation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .renameActiveConversation)) { _ in
            initiateRenameForActiveConversation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .deleteActiveConversation)) { _ in
            initiateDeleteForActiveConversation()
        }
    }

    // MARK: - List Component
    private var conversationList: some View {
        let data = partitioned
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch selectedFilter {
                case .pinned:
                    // Pinned-only flat list
                    if data.pinned.isEmpty {
                        SidebarEmptyStateView(
                            title: pinnedEmptyTitle,
                            subtitle: "Right-click a conversation to pin it",
                            buttonTitle: newButtonTitle,
                            systemImage: "pin",
                            onAction: {
                                if viewModel.interfaceMode == .workflow || viewModel.interfaceMode == .code {
                                    viewModel.deselectConversationAndShowWelcome()
                                } else {
                                    viewModel.startNewConversation()
                                }
                            }
                        )
                    } else {
                        // [P1] Lazy: rows build only as they scroll into view.
                        LazyVStack(spacing: 2) {
                            ForEach(data.pinned) { conversation in
                                row(for: conversation)
                            }
                        }
                    }

                case .all where viewModel.interfaceMode == .code:
                    // Code: grouped by PROJECT (non-pinned only), most recently active first.
                    ForEach(data.projectGroups, id: \.id) { group in
                        projectSection(group)
                    }

                case .all:
                    // Date-Grouped Sections (non-pinned only)
                    ForEach(Array(data.dateSections.enumerated()), id: \.element.title) { index, section in
                        // [P1] Lazy: a large date section no longer builds every row up front.
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if index > 0 {
                                Divider()
                                    .background(theme.dividerColor)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 4)
                            }

                            Text(section.title)
                                .font(.system(.caption, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 8)
                                .padding(.top, 10)
                                .padding(.bottom, 4)

                            ForEach(section.conversations) { conversation in
                                row(for: conversation)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 20)
        }
    }

    @ViewBuilder
    private func projectSection(_ group: CodeProjectGrouping.Group<ConversationSD>) -> some View {
        let isExpanded = !collapsedProjects.contains(group.id)
        let showsAll = fullyShownProjects.contains(group.id) || !searchText.isEmpty
        let limit = CodeProjectGrouping.visibleSessionsPerProject
        let shown = showsAll ? group.items : Array(group.items.prefix(limit))

        LazyVStack(alignment: .leading, spacing: 2) {
            CodeProjectHeaderView(
                title: group.title,
                path: group.path,
                isMissing: group.isMissing,
                isExpanded: Binding(
                    get: { isExpanded },
                    set: { setProject(group.id, expanded: $0) }
                ),
                onNewSession: group.path.map { path in
                    { viewModel.startNewCodeSession(in: URL(fileURLWithPath: path)) }
                }
            )

            if isExpanded {
                ForEach(shown) { conversation in
                    row(for: conversation)
                        .padding(.leading, 12)
                        .opacity(group.isMissing ? 0.6 : 1)
                }
                if group.items.count > shown.count {
                    Button {
                        fullyShownProjects.insert(group.id)
                    } label: {
                        Text("Show \(group.items.count - shown.count) more")
                            .font(theme.fontCaption)
                            .foregroundColor(theme.secondaryText)
                            .padding(.leading, 30)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func setProject(_ id: String, expanded: Bool) {
        logger.debug("[CODE_SIDEBAR] Project '\(id.isEmpty ? "No project" : URL(fileURLWithPath: id).lastPathComponent)' \(expanded ? "expanded" : "collapsed").")
        if expanded { collapsedProjects.remove(id) } else { collapsedProjects.insert(id) }
        UserDefaults.standard.set(Array(collapsedProjects), forKey: Self.collapsedProjectsKey)
    }

    @ViewBuilder
    private func row(for conversation: ConversationSD) -> some View {
        ConversationSidebarRow(
            conversation: conversation,
            viewModel: viewModel,
            renamingConversationID: $renamingConversationID,
            editableConversationName: $editableConversationName,
            isRenameFieldFocused: $isRenameFieldFocused,
            conversationToDelete: $conversationToDelete,
            showingDeleteAlert: $showingDeleteAlert,
            isSelectionMode: $isSelectionMode,
            selectedIDs: $selectedConversationIDs
        )
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.95)),
            removal: .opacity.combined(with: .scale(scale: 0.95))
        ))
    }

    // MARK: - Filtering Logic (single-pass partition)

    private struct PartitionedConversations {
        let pinned: [ConversationSD]
        let dateSections: [DateSection]
        /// Code mode only — takes the place of `dateSections` there.
        var projectGroups: [CodeProjectGrouping.Group<ConversationSD>] = []
    }

    private struct DateSection: Equatable {
        let title: String
        let conversations: [ConversationSD]

        static func == (lhs: DateSection, rhs: DateSection) -> Bool {
            lhs.title == rhs.title && lhs.conversations.map(\.id) == rhs.conversations.map(\.id)
        }
    }

    /// Quick count of conversations visible in the current mode (for empty state detection).
    private var filteredConversationCount: Int {
        let p = partitioned
        let pinnedCount = p.pinned.count
        let dateCount = p.dateSections.reduce(0) { $0 + $1.conversations.count }
        let projectCount = p.projectGroups.reduce(0) { $0 + $1.items.count }
        return pinnedCount + dateCount + projectCount
    }

    /// Single-pass partition: filters by mode, splits pinned/unpinned, and date-groups in one traversal.
    private var partitioned: PartitionedConversations {
        // Build profile type lookup for mode-based filtering.
        let profiles = (try? BackendProfileStore.shared.fetchProfiles()) ?? []
        let typeMap = Dictionary(profiles.map { ($0.id, $0.profileType) }, uniquingKeysWith: { first, _ in first })
        let allowedTypes = viewModel.interfaceMode.allowedProfileTypes

        let calendar = Calendar.current
        let now = Date()
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)
        let monthAgo = calendar.date(byAdding: .month, value: -1, to: now)

        var pinned: [ConversationSD] = []
        var today: [ConversationSD] = []
        var yesterday: [ConversationSD] = []
        var thisWeek: [ConversationSD] = []
        var thisMonth: [ConversationSD] = []
        var earlier: [ConversationSD] = []
        let isCode = viewModel.interfaceMode == .code
        var codeSessions: [ConversationSD] = []

        for conversation in conversations {
            // Mode filter: prefer denormalized profileTypeRaw (covers Code mode + ephemeral profiles),
            // then fall back to store-based profile lookup for legacy conversations.
            let resolvedProfileType: ProfileType?
            if let raw = conversation.profileTypeRaw, let pt = ProfileType(rawValue: raw) {
                resolvedProfileType = pt
            } else if let profileID = conversation.backendEntityId, let pt = typeMap[profileID] {
                resolvedProfileType = pt
            } else {
                resolvedProfileType = nil
            }

            if let pt = resolvedProfileType {
                if !allowedTypes.contains(pt) { continue }
            } else {
                // No profile type resolved — always show in chat mode. Hide from workflow
                // (workflows always have a profile bound). Code conversations are now tagged
                // at creation time via `tagConversationWithCurrentMode`, so an untagged entry
                // reaching code mode implies a legacy/migrated row — show it there too so it's
                // discoverable rather than silently excluded.
                if viewModel.interfaceMode == .workflow { continue }
            }

            // Search text filter. In Code, the project's folder name matches too — "which
            // sessions were in Devgentic?" is a search the grouping invites.
            if !searchText.isEmpty,
               !conversation.displayTitle.localizedCaseInsensitiveContains(searchText),
               !(isCode && (conversation.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }?
                    .localizedCaseInsensitiveContains(searchText) ?? false)) {
                continue
            }

            if conversation.isPinned {
                pinned.append(conversation)
                continue
            }

            if isCode {
                codeSessions.append(conversation)
                continue
            }

            let date = conversation.timestamp

            if calendar.isDateInToday(date) {
                today.append(conversation)
            } else if calendar.isDateInYesterday(date) {
                yesterday.append(conversation)
            } else if let weekAgo, date >= weekAgo {
                thisWeek.append(conversation)
            } else if let monthAgo, date >= monthAgo {
                thisMonth.append(conversation)
            } else {
                earlier.append(conversation)
            }
        }

        var sections: [DateSection] = []
        if !today.isEmpty { sections.append(DateSection(title: "Today", conversations: today)) }
        if !yesterday.isEmpty { sections.append(DateSection(title: "Yesterday", conversations: yesterday)) }
        if !thisWeek.isEmpty { sections.append(DateSection(title: "This Week", conversations: thisWeek)) }
        if !thisMonth.isEmpty { sections.append(DateSection(title: "This Month", conversations: thisMonth)) }
        if !earlier.isEmpty { sections.append(DateSection(title: "Earlier", conversations: earlier)) }
        var result = PartitionedConversations(pinned: pinned, dateSections: sections)
        if isCode {
            result.projectGroups = CodeProjectGrouping.groups(codeSessions, path: \.projectPath, date: \.timestamp)
        }
        return result
    }

    private var pinnedConversations: [ConversationSD] { partitioned.pinned }
    private var dateGroupedSections: [DateSection] { partitioned.dateSections }

    // MARK: - Batch Selection Header
    //
    // Mirrors the PromptLibrarySidebarView pattern (2026-04-21): in selection
    // mode the normal title/search/chip chrome is hidden and replaced by
    // `[Cancel] [N selected] [Select All / Deselect All] [Delete]`. Keeps the
    // sidebar header slot used for exactly one purpose at a time.
    @ViewBuilder
    private var batchHeaderRow: some View {
        HStack(spacing: 10) {
            BatchHeaderTextButton(
                title: "Cancel",
                tint: theme.secondaryText,
                action: { cancelSelectionMode() }
            )
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel batch selection")

            Spacer()

            Text("\(selectedConversationIDs.count) selected")
                .font(theme.fontBody.weight(.semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            BatchHeaderTextButton(
                title: selectedConversationIDs == visibleConversationIDs ? "Deselect All" : "Select All",
                tint: theme.accentColor,
                action: { toggleSelectAllVisible() }
            )
            .help(selectedConversationIDs == visibleConversationIDs ? "Clear selection" : "Select all visible conversations")

            Button {
                deleteSelectedConversations()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(.caption, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.errorColor.opacity(0.15))
                .foregroundColor(theme.errorColor)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(selectedConversationIDs.isEmpty)
            .opacity(selectedConversationIDs.isEmpty ? 0.5 : 1)
            .keyboardShortcut(.delete, modifiers: [.command])
            .help("Delete selected (⌘⌫)")
            .accessibilityLabel("Delete \(selectedConversationIDs.count) selected conversations")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Visible Conversations for Sequential Navigation

    private var visibleConversationsList: [ConversationSD] {
        let p = partitioned
        if selectedFilter == .pinned {
            return p.pinned
        }
        return p.pinned + p.dateSections.flatMap(\.conversations) + p.projectGroups.flatMap(\.items)
    }

    /// Flattens the current partition (pinned + all date sections) into a
    /// set of IDs for Select-All semantics. Honors the filter chip — when
    /// `.pinned` is selected only pinned rows are visible, so only pinned
    /// IDs go into the set.
    private var visibleConversationIDs: Set<UUID> {
        Set(visibleConversationsList.map(\.id))
    }

    // MARK: - Keyboard Navigation & Actions

    private func selectNextConversation() {
        let list = visibleConversationsList
        guard !list.isEmpty else { return }
        guard let currentID = viewModel.selectedConversationID,
              let currentIndex = list.firstIndex(where: { $0.id == currentID }) else {
            selectConversation(list[0])
            return
        }
        let nextIndex = min(currentIndex + 1, list.count - 1)
        selectConversation(list[nextIndex])
    }

    private func selectPreviousConversation() {
        let list = visibleConversationsList
        guard !list.isEmpty else { return }
        guard let currentID = viewModel.selectedConversationID,
              let currentIndex = list.firstIndex(where: { $0.id == currentID }) else {
            selectConversation(list[0])
            return
        }
        let prevIndex = max(currentIndex - 1, 0)
        selectConversation(list[prevIndex])
    }

    private func selectConversation(_ conversation: ConversationSD) {
        viewModel.workflowEditGuard.attempt {
            viewModel.selectedConversationID = conversation.id
            if !router.isShowingChat {
                router.returnToChat()
            }
        }
    }

    private func initiateRenameForActiveConversation() {
        guard let currentID = viewModel.selectedConversationID,
              let conversation = conversations.first(where: { $0.id == currentID }) else { return }
        self.editableConversationName = conversation.displayTitle
        self.renamingConversationID = conversation.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            self.isRenameFieldFocused = true
        }
    }

    private func initiateDeleteForActiveConversation() {
        guard let currentID = viewModel.selectedConversationID,
              let conversation = conversations.first(where: { $0.id == currentID }) else { return }
        self.conversationToDelete = conversation
        self.showingDeleteAlert = true
    }

    private func toggleSelectAllVisible() {
        if selectedConversationIDs == visibleConversationIDs {
            selectedConversationIDs.removeAll()
            if selectedConversationIDs.isEmpty { cancelSelectionMode() }
        } else {
            selectedConversationIDs = visibleConversationIDs
        }
    }

    private func deleteSelectedConversations() {
        guard !selectedConversationIDs.isEmpty else { return }
        showingBatchDeleteAlert = true
    }

    private func confirmBatchDelete() {
        let count = selectedConversationIDs.count
        viewModel.deleteMultipleConversations(ids: selectedConversationIDs)
        cancelSelectionMode()
        logger.info("Deleted \(count) conversations in batch.")
    }

    private func cancelSelectionMode() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isSelectionMode = false
            selectedConversationIDs.removeAll()
        }
    }
}

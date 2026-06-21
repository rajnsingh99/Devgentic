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
                .font(.system(size: 9, weight: .semibold)) // Fixed size: intentional (small disclosure chevron)
                .foregroundColor(theme.secondaryText.opacity(0.5))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isExpanded)
                .frame(width: 16)

            Text(title)
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .padding(.leading, 2)

            Text("\(count)")
                .font(.system(.caption2, weight: .medium))
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


/// Wrapper around `ConversationRowView` that specifically handles sidebar behaviors
/// such as context menus (pinning, renaming, deleting) and inline state preparation.
struct ConversationSidebarRow: View {
    let conversation: ConversationSD

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
            // Assuming toConversationStruct() maps the entity to a UI model
            conversation: conversation.toStruct(),
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
            onPin: {
                viewModel.togglePinStatus(for: conversation.id)
            },
            onDelete: {
                triggerDelete()
            },
            isSelectionMode: isSelectionMode,
            isBatchSelected: selectedIDs.contains(conversation.id)
        )
        .contextMenu {
            contextMenuContent
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            enterSelectionMode()
        }
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
    @Environment(\.appTheme) private var theme

    // MARK: - Data Fetching
    @Query(sort: \ConversationSD.timestamp, order: .reverse) private var conversations: [ConversationSD]

    // MARK: - Filter
    private enum ConversationFilter: String, CaseIterable {
        case all = "All"
        case pinned = "Pinned"
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

    // Batch Selection State
    @State private var selectedConversationIDs: Set<UUID> = []
    @State private var isSelectionMode: Bool = false
    @State private var showingBatchDeleteAlert: Bool = false

    // MARK: - Mode-Aware Properties

    private var sidebarTitle: LocalizedStringKey {
        viewModel.interfaceMode == .workflow ? "Workflows" : "Chats"
    }

    private var newButtonTitle: LocalizedStringKey {
        viewModel.interfaceMode == .workflow ? "New Workflow" : "New Chat"
    }

    private var searchPlaceholder: String {
        viewModel.interfaceMode == .workflow ? "Search workflows..." : "Search conversations..."
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
                    .transition(.move(edge: .top).combined(with: .opacity))
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
                                title: filter.rawValue,
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
                        VStack(spacing: 2) {
                            ForEach(data.pinned) { conversation in
                                row(for: conversation)
                            }
                        }
                    }

                case .all:
                    // Date-Grouped Sections (non-pinned only)
                    ForEach(Array(data.dateSections.enumerated()), id: \.element.title) { index, section in
                        VStack(alignment: .leading, spacing: 2) {
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
        return pinnedCount + dateCount
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

            // Search text filter.
            if !searchText.isEmpty,
               !conversation.displayTitle.localizedCaseInsensitiveContains(searchText) {
                continue
            }

            if conversation.isPinned {
                pinned.append(conversation)
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
        return PartitionedConversations(pinned: pinned, dateSections: sections)
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

    /// Flattens the current partition (pinned + all date sections) into a
    /// set of IDs for Select-All semantics. Honors the filter chip — when
    /// `.pinned` is selected only pinned rows are visible, so only pinned
    /// IDs go into the set.
    private var visibleConversationIDs: Set<UUID> {
        let p = partitioned
        var ids = Set(p.pinned.map(\.id))
        if selectedFilter == .all {
            for section in p.dateSections {
                for convo in section.conversations {
                    ids.insert(convo.id)
                }
            }
        }
        return ids
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

//
//  ConversationSidebarView.swift
//  Devgentic
//
//  Created by Raj Singh on 28/02/26.
//

import Foundation
import SwiftUI
import CoreData
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ConversationSidebarView")


// MARK: - ConversationEntity Extension
/// Extensions to `ConversationEntity` to provide stable, computed properties for the UI.
extension ConversationEntity {
    
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
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(theme.secondaryText.opacity(0.5))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isExpanded)
                .frame(width: 16)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .padding(.leading, 2)

            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
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
    let conversation: ConversationEntity

    @ObservedObject var viewModel: MainApplicationViewModel
    @EnvironmentObject private var router: MainViewRouter

    // Inline Renaming State
    @Binding var renamingConversationID: UUID?
    @Binding var editableConversationName: String
    var isRenameFieldFocused: FocusState<Bool>.Binding

    // Deletion State
    @Binding var conversationToDelete: ConversationEntity?
    @Binding var showingDeleteAlert: Bool

    // Batch Selection
    @Binding var isSelectionMode: Bool
    @Binding var selectedIDs: Set<UUID>

    var body: some View {
        ConversationRowView(
            // Assuming toConversationStruct() maps the entity to a UI model
            conversation: conversation.toConversationStruct(),
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
                guard let id = conversation.id else { return }
                viewModel.togglePinStatus(for: id)
            },
            onDelete: {
                triggerDelete()
            },
            isSelectionMode: isSelectionMode,
            isBatchSelected: conversation.id.map { selectedIDs.contains($0) } ?? false
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
            viewModel.selectedConversationID = conversation.id
            // Return to chat if currently viewing a non-chat destination
            if !router.isShowingChat {
                router.returnToChat()
            }
        }
    }

    private func toggleBatchSelection() {
        guard let id = conversation.id else { return }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        
        // Auto-exit if nothing selected? No, let user cancel.
    }

    private func enterSelectionMode() {
        guard let id = conversation.id else { return }
        isSelectionMode = true
        selectedIDs.insert(id)
    }

    // MARK: - Context Menu
    @ViewBuilder
    private var contextMenuContent: some View {
        if isSelectionMode {
            let isSelected = conversation.id.map { selectedIDs.contains($0) } ?? false
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
            guard let id = conversation.id else { return }
            viewModel.togglePinStatus(for: id)
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
            if let id = conversation.id {
                viewModel.exportConversation(conversationID: id)
            }
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
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.appTheme) private var theme

    // MARK: - Data Fetching
    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \ConversationEntity.isPinned, ascending: false),
            NSSortDescriptor(keyPath: \ConversationEntity.timestamp, ascending: false)
        ],
        animation: .default)
    private var conversations: FetchedResults<ConversationEntity>

    // MARK: - Filter
    private enum ConversationFilter: String, CaseIterable {
        case all = "All"
        case pinned = "Pinned"
    }
    @State private var selectedFilter: ConversationFilter = .all

    // MARK: - View State
    @State private var searchText = ""
    @State private var showingDeleteAlert = false
    @State private var conversationToDelete: ConversationEntity? = nil

    // Renaming State
    @State private var renamingConversationID: UUID?
    @State private var editableConversationName: String = ""
    @FocusState private var isRenameFieldFocused: Bool

    @State private var isPinnedExpanded: Bool = true

    // Batch Selection State
    @State private var selectedConversationIDs: Set<UUID> = []
    @State private var isSelectionMode: Bool = false
    @State private var showingBatchDeleteAlert: Bool = false

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            
            SidebarHeaderView(
                title: "Chats",
                buttonTitle: "New Chat",
                systemImage: "plus",
                shortcut: "⌘N",
                onAction: { viewModel.startNewConversation() }
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            SidebarSearchBarView("Search conversations...", text: $searchText)
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

            if isSelectionMode {
                batchSelectionToolbar
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            if conversations.isEmpty && searchText.isEmpty {
                SidebarEmptyStateView(
                    title: "No Conversations Yet",
                    subtitle: "Start a new chat to begin exploring",
                    buttonTitle: "Start a Conversation",
                    systemImage: "bubble.left.and.text.bubble.right",
                    onAction: { viewModel.startNewConversation() }
                )
            } else {
                conversationList
            }
        }
        .background(Color.clear)
        .alert("Delete Conversation?", isPresented: $showingDeleteAlert, presenting: conversationToDelete) { conv in
            Button("Delete", role: .destructive) {
                if let id = conv.id {
                    viewModel.deleteConversation(conversationID: id)
                }
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
                            title: "No Pinned Chats",
                            subtitle: "Right-click a conversation to pin it",
                            buttonTitle: "New Chat",
                            systemImage: "pin",
                            onAction: { viewModel.startNewConversation() }
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
                                .font(.system(size: 12, weight: .semibold))
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
    private func row(for conversation: ConversationEntity) -> some View {
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
        let pinned: [ConversationEntity]
        let dateSections: [DateSection]
    }

    private struct DateSection: Equatable {
        let title: String
        let conversations: [ConversationEntity]

        static func == (lhs: DateSection, rhs: DateSection) -> Bool {
            lhs.title == rhs.title && lhs.conversations.map(\.objectID) == rhs.conversations.map(\.objectID)
        }
    }

    /// Single-pass partition: filters, splits pinned/unpinned, and date-groups in one traversal.
    private var partitioned: PartitionedConversations {
        let calendar = Calendar.current
        let now = Date()
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)
        let monthAgo = calendar.date(byAdding: .month, value: -1, to: now)

        var pinned: [ConversationEntity] = []
        var today: [ConversationEntity] = []
        var yesterday: [ConversationEntity] = []
        var thisWeek: [ConversationEntity] = []
        var thisMonth: [ConversationEntity] = []
        var earlier: [ConversationEntity] = []

        for conversation in conversations {
            if !searchText.isEmpty,
               !conversation.displayTitle.localizedCaseInsensitiveContains(searchText) {
                continue
            }

            if conversation.isPinned {
                pinned.append(conversation)
                continue
            }

            guard let date = conversation.timestamp else {
                earlier.append(conversation)
                continue
            }

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

    private var pinnedConversations: [ConversationEntity] { partitioned.pinned }
    private var dateGroupedSections: [DateSection] { partitioned.dateSections }

    // MARK: - Batch Selection Components
    @ViewBuilder
    private var batchSelectionToolbar: some View {
        HStack {
            Button(role: .destructive) {
                deleteSelectedConversations()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Delete (\(selectedConversationIDs.count))")
                        .font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.errorColor.opacity(0.1))
                .foregroundColor(theme.errorColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(selectedConversationIDs.isEmpty)

            Spacer()

            Button {
                cancelSelectionMode()
            } label: {
                Text("Cancel")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.surfaceOverlay)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.surfaceOverlay)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.surfaceOverlayStrong, lineWidth: 0.5)
                )
        )
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

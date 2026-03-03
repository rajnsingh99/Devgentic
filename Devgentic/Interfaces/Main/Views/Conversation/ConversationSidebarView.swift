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
    
    /// Provides a stable, chronologically sorted array of messages from the unordered NSSet.
    /// - Returns: An array of `ChatMessageEntity` sorted by timestamp (oldest to newest).
    var messagesArray: [ChatMessageEntity] {
        let set = messages as? Set<ChatMessageEntity> ?? []
        return set.sorted {
            ($0.timestamp ?? Date.distantPast) < ($1.timestamp ?? Date.distantPast)
        }
    }

    /// Computes a user-friendly display title for the conversation.
    /// It prioritizes a user-defined title. If not available, it falls back to the text
    /// of the first message, or defaults to "New Conversation".
    var displayTitle: String {
        if let userTitle = userDefinedTitle, !userTitle.isEmpty {
            return userTitle
        }
        return messagesArray.first?.text_content ?? "New Conversation"
    }
}



// MARK: - Sidebar Empty State
/// Displayed when there are no conversations available.

// MARK: - Sidebar Group Header View
/// A custom disclosure group header representing time-based categories (e.g., "Today", "Previous 7 Days").
struct SidebarGroupHeaderView: View {
    let title: String
    let count: Int
    
    /// Binding determining if the group's contents are visible.
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
                .foregroundColor(.secondary.opacity(0.9))
                .padding(.leading, 2)

            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary.opacity(0.5))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.04))
                .clipShape(Capsule())
                .padding(.leading, 6)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? Color.white.opacity(0.04) : Color.clear)
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

    // Inline Renaming State
    @Binding var renamingConversationID: UUID?
    @Binding var editableConversationName: String
    var isRenameFieldFocused: FocusState<Bool>.Binding

    // Deletion State
    @Binding var conversationToDelete: ConversationEntity?
    @Binding var showingDeleteAlert: Bool

    var body: some View {
        ConversationRowView(
            // Assuming toConversationStruct() maps the entity to a UI model
            conversation: conversation.toConversationStruct(),
            isSelected: viewModel.selectedConversationID == conversation.id,
            isRenaming: renamingConversationID == conversation.id,
            editableName: $editableConversationName,
            isRenameFieldFocused: isRenameFieldFocused,
            onSelect: {
                viewModel.selectedConversationID = conversation.id
            },
            onCommitRename: {
                if let id = renamingConversationID {
                    viewModel.renameConversation(conversationID: id, newTitle: editableConversationName)
                }
                renamingConversationID = nil
            },
            onPin: {
                viewModel.togglePinStatus(for: conversation.id ?? UUID())
            },
            onDelete: {
                triggerDelete()
            }
        )
        .contextMenu {
            contextMenuContent
        }
    }

    // MARK: - Context Menu
    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            viewModel.togglePinStatus(for: conversation.id ?? UUID())
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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

    // MARK: - Data Fetching
    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \ConversationEntity.isPinned, ascending: false),
            NSSortDescriptor(keyPath: \ConversationEntity.timestamp, ascending: false)
        ],
        animation: .default)
    private var conversations: FetchedResults<ConversationEntity>

    // MARK: - View State
    @State private var searchText = ""
    @State private var showingDeleteAlert = false
    @State private var conversationToDelete: ConversationEntity? = nil

    // Renaming State
    @State private var renamingConversationID: UUID?
    @State private var editableConversationName: String = ""
    @FocusState private var isRenameFieldFocused: Bool

    // Group Expansion Persistence
    @State private var expandedGroups: Set<String> = []
    private let expandedGroupsKey = "sidebarExpandedGroups"

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
        }
        .onChange(of: viewModel.selectedConversationID) { _ in
            expandGroupForSelection()
        }
        .onChange(of: expandedGroups) { _ in
            saveExpandedGroupsState()
        }
        .onAppear {
            loadExpandedGroupsState()
            expandGroupForSelection()
        }
    }
    
    // MARK: - List Component
    private var conversationList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(sortedGroupKeys, id: \.self) { groupKey in
                    if let conversationsInGroup = groupedConversations[groupKey], !conversationsInGroup.isEmpty {
                        
                        VStack(alignment: .leading, spacing: 2) {
                            SidebarGroupHeaderView(
                                title: groupKey,
                                count: conversationsInGroup.count,
                                isExpanded: bindingForGroup(groupKey)
                            )

                            if expandedGroups.contains(groupKey) {
                                groupContent(for: conversationsInGroup)
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
    private func groupContent(for group: [ConversationEntity]) -> some View {
        VStack(spacing: 2) {
            ForEach(group) { conversation in
                ConversationSidebarRow(
                    conversation: conversation,
                    viewModel: viewModel,
                    renamingConversationID: $renamingConversationID,
                    editableConversationName: $editableConversationName,
                    isRenameFieldFocused: $isRenameFieldFocused,
                    conversationToDelete: $conversationToDelete,
                    showingDeleteAlert: $showingDeleteAlert
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.95)),
                    removal: .opacity.combined(with: .scale(scale: 0.95))
                ))
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)).animation(.easeInOut(duration: 0.2)))
    }

    // MARK: - Grouping Logic
    
    /// Filters and groups conversations based on search text and timestamp/pin status.
    private var groupedConversations: [String: [ConversationEntity]] {
        let filteredConversations = conversations.filter { conversation in
            guard !searchText.isEmpty else { return true }
            
            let titleMatch = conversation.displayTitle.localizedCaseInsensitiveContains(searchText)
            let messageMatch = conversation.messagesArray.contains { message in
                message.text_content?.localizedCaseInsensitiveContains(searchText) ?? false
            }
            return titleMatch || messageMatch
        }

        return Dictionary(grouping: filteredConversations) { conversation in
            if conversation.isPinned { return "Pinned" }
            return timeBasedGroupKey(for: conversation.timestamp ?? Date())
        }
    }

    /// Provides a sorted array of the keys present in `groupedConversations`.
    private var sortedGroupKeys: [String] {
        let keys = groupedConversations.keys
        let sortOrder = ["Pinned", "Today", "Yesterday", "Previous 7 Days", "Previous 30 Days"]

        return keys.sorted { key1, key2 in
            let index1 = sortOrder.firstIndex(of: key1)
            let index2 = sortOrder.firstIndex(of: key2)

            if let i1 = index1, let i2 = index2 { return i1 < i2 }
            if index1 != nil { return true }
            if index2 != nil { return false }

            // Fallback for custom month sorting
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMMM yyyy"
            if let date1 = dateFormatter.date(from: key1), let date2 = dateFormatter.date(from: key2) {
                return date1 > date2
            }
            return key1 > key2
        }
    }

    // MARK: - Helpers

    /// Classifies a Date into a string categorization bucket.
    private func timeBasedGroupKey(for date: Date) -> String {
        let now = Date()
        let calendar = Calendar.current

        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        if let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now), date > sevenDaysAgo {
            return "Previous 7 Days"
        }

        if let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now), date > thirtyDaysAgo {
            return "Previous 30 Days"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    /// Provides a binding for a specific disclosure group key to animate and store its expansion state.
    private func bindingForGroup(_ groupKey: String) -> Binding<Bool> {
        return Binding(
            get: { self.expandedGroups.contains(groupKey) },
            set: { isExpanding in
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanding { self.expandedGroups.insert(groupKey) }
                    else { self.expandedGroups.remove(groupKey) }
                }
            }
        )
    }

    /// Automatically expands the group containing the currently selected conversation.
    private func expandGroupForSelection() {
        guard let selectedID = viewModel.selectedConversationID,
              let selectedConv = conversations.first(where: { $0.id == selectedID }) else {
            return
        }

        let key = selectedConv.isPinned ? "Pinned" : timeBasedGroupKey(for: selectedConv.timestamp ?? Date())
        if !expandedGroups.contains(key) {
            expandedGroups.insert(key)
        }
    }

    // MARK: - Persistence
    
    private func loadExpandedGroupsState() {
        let savedGroups = UserDefaults.standard.stringArray(forKey: expandedGroupsKey)
        if let savedGroups = savedGroups {
            self.expandedGroups = Set(savedGroups)
        } else {
            // Default groups open on first load
            self.expandedGroups = ["Pinned", "Today", "Previous 7 Days"]
        }
    }

    private func saveExpandedGroupsState() {
        UserDefaults.standard.set(Array(self.expandedGroups), forKey: expandedGroupsKey)
    }
}

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
                viewModel.togglePinStatus(for: conversation.id ?? UUID())
            },
            onDelete: {
                triggerDelete()
            },
            isSelectionMode: isSelectionMode,
            isBatchSelected: (conversation.id != nil) ? selectedIDs.contains(conversation.id!) : false
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
            Button {
                toggleBatchSelection()
            } label: {
                Label(
                    selectedIDs.contains(conversation.id ?? UUID()) ? "Deselect" : "Select",
                    systemImage: selectedIDs.contains(conversation.id ?? UUID()) ? "minus.circle" : "checkmark.circle"
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

    @State private var isPinnedExpanded: Bool = true

    // Batch Selection State
    @State private var selectedConversationIDs: Set<UUID> = []
    @State private var isSelectionMode: Bool = false

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
        }
        .onAppear {
            isPinnedExpanded = UserDefaults.standard.object(forKey: "sidebarPinnedExpanded_v2") as? Bool ?? true
        }
        .onChange(of: isPinnedExpanded) { newValue in
            UserDefaults.standard.set(newValue, forKey: "sidebarPinnedExpanded_v2")
        }
    }
    
    // MARK: - List Component
    private var conversationList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Pinned Section
                if !pinnedConversations.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        SidebarGroupHeaderView(
                            title: "Pinned",
                            count: pinnedConversations.count,
                            isExpanded: $isPinnedExpanded
                        )
                        
                        if isPinnedExpanded {
                            VStack(spacing: 2) {
                                ForEach(pinnedConversations) { conversation in
                                    row(for: conversation)
                                }
                            }
                            .padding(.leading, 12)
                        }
                    }
                }

                // Others Section (Flat)
                VStack(spacing: 2) {
                    ForEach(otherConversations) { conversation in
                        row(for: conversation)
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

    // MARK: - Filtering Logic

    /// All filtered conversations.
    private var filteredConversations: [ConversationEntity] {
        conversations.filter { conversation in
            guard !searchText.isEmpty else { return true }
            return conversation.displayTitle.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Conversations that are pinned.
    private var pinnedConversations: [ConversationEntity] {
        filteredConversations.filter { $0.isPinned }
    }

    /// Conversations that are NOT pinned.
    private var otherConversations: [ConversationEntity] {
        filteredConversations.filter { !$0.isPinned }
    }

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
                .background(Color.red.opacity(0.1))
                .foregroundColor(.red)
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
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
                )
        )
    }

    private func deleteSelectedConversations() {
        guard !selectedConversationIDs.isEmpty else { return }
        
        let count = selectedConversationIDs.count
        viewModel.deleteMultipleConversations(ids: selectedConversationIDs)
        
        // Success notification or just exit mode
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

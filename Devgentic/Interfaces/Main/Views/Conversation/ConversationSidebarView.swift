// Views/ConversationListView.swift
import SwiftUI
import CoreData
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ConversationListView")

// MARK: - ConversationEntity Extension
extension ConversationEntity {
    /// Provides a stable, sorted array of messages from the NSSet.
    var messagesArray: [ChatMessageEntity] {
        let set = messages as? Set<ChatMessageEntity> ?? []
        return set.sorted {
            ($0.timestamp ?? Date.distantPast) < ($1.timestamp ?? Date.distantPast)
        }
    }

    /// Computes a display title, falling back from a user-defined title to the first message content.
    var displayTitle: String {
        if let userTitle = userDefinedTitle, !userTitle.isEmpty {
            return userTitle
        }
        return messagesArray.first?.text_content ?? "New Conversation"
    }
}

struct ConversationSidebarView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.managedObjectContext) private var viewContext

    // --- Core Data Fetch Request ---
    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \ConversationEntity.isPinned, ascending: false),
            NSSortDescriptor(keyPath: \ConversationEntity.timestamp, ascending: false)
        ],
        animation: .default)
    private var conversations: FetchedResults<ConversationEntity>

    // --- Local State ---
    @State private var showingDeleteAlert = false
    @State private var conversationToDelete: ConversationEntity? = nil

    // --- State for Expanded Groups (with Persistence) ---
    @State private var expandedGroups: Set<String> = []
    private let expandedGroupsKey = "sidebarExpandedGroups" // UserDefaults key

    @State private var searchText = ""

    // --- State for Inline Renaming ---
    @State private var renamingConversationID: UUID?
    @State private var editableConversationName: String = ""

    // --- Focus States ---
    @FocusState private var isRenameFieldFocused: Bool
    @FocusState private var isSearchFieldFocused: Bool

    // --- Computed Properties for Grouping ---
    private var groupedConversations: [String: [ConversationEntity]] {
        let filteredConversations = conversations.filter { conversation in
            guard !searchText.isEmpty else { return true }
            let titleMatch = conversation.displayTitle.localizedCaseInsensitiveContains(searchText)
            let messageMatch = conversation.messagesArray.contains { message in
                message.text_content?.localizedCaseInsensitiveContains(searchText) ?? false
            }
            return titleMatch || messageMatch
        }

        return Dictionary(grouping: filteredConversations, by: {
            if $0.isPinned { return "Pinned" }
            return groupKey(for: $0.timestamp ?? Date())
        })
    }

    private var sortedGroupKeys: [String] {
        let keys = groupedConversations.keys
        let sortOrder = ["Pinned", "Today", "Yesterday", "Previous 7 Days", "Previous 30 Days"]

        return keys.sorted { key1, key2 in
            let index1 = sortOrder.firstIndex(of: key1)
            let index2 = sortOrder.firstIndex(of: key2)

            if let i1 = index1, let i2 = index2 { return i1 < i2 }
            if index1 != nil { return true }
            if index2 != nil { return false }

            // Month sorting
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMMM yyyy"
            if let date1 = dateFormatter.date(from: key1), let date2 = dateFormatter.date(from: key2) {
                return date1 > date2
            }
            return key1 > key2
        }
    }

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            // --- Sidebar Header with Title & New Chat ---
            sidebarHeader
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // --- Search Bar ---
            searchBar
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            // --- Conversation List or Empty State ---
            if conversations.isEmpty && searchText.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sortedGroupKeys, id: \.self) { groupKey in
                            if let conversationsInGroup = groupedConversations[groupKey], !conversationsInGroup.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    let isExpanded = bindingForGroup(groupKey)
                                    DisclosureGroupHeader(
                                        title: groupKey,
                                        count: conversationsInGroup.count,
                                        isExpanded: isExpanded
                                    )

                                    if isExpanded.wrappedValue {
                                        disclosureGroupContent(for: conversationsInGroup)
                                            .transition(.opacity.combined(with: .move(edge: .top)).animation(.easeInOut(duration: 0.2)))
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

    // MARK: - Sub Views

    /// Header with "Chats" title and "+ New Chat" button
    private var sidebarHeader: some View {
        HStack {
            Text("Chats")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            Button {
                viewModel.startNewConversation()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("New Chat")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.15))
                .foregroundColor(.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(ScaleButtonStyle())
            .help("Start a new conversation (⌘N)")
        }
    }

    /// Enhanced search bar with focus ring, accent glow, and clear button
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(isSearchFieldFocused ? .accentColor : .secondary.opacity(0.7))
                .font(.system(size: 14))
                .animation(.easeInOut(duration: 0.2), value: isSearchFieldFocused)

            TextField("Search conversations...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFieldFocused)

            // Clear button when text is present
            if !searchText.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        searchText = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isSearchFieldFocused ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.1),
                    lineWidth: isSearchFieldFocused ? 1.0 : 0.5
                )
        )
        .shadow(
            color: isSearchFieldFocused ? Color.accentColor.opacity(0.15) : Color.clear,
            radius: 6, x: 0, y: 0
        )
        .animation(.easeInOut(duration: 0.2), value: isSearchFieldFocused)
    }

    /// Animated empty state when no conversations exist
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.08), Color.purple.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 90, height: 90)

                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 36))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.accentColor.opacity(0.7), .purple.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 6) {
                Text("No Conversations Yet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)

                Text("Start a new chat to begin exploring")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                viewModel.startNewConversation()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Start a Conversation")
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(ScaleButtonStyle())
            .modifier(PulseAnimationModifier())

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func disclosureGroupContent(for conversationsInGroup: [ConversationEntity]) -> some View {
        VStack(spacing: 2) {
            ForEach(conversationsInGroup) { conversation in
                ConversationListRow(
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
    }

    // MARK: - Helper Methods

    private func groupKey(for date: Date) -> String {
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

    private func expandGroupForSelection() {
        guard let selectedID = viewModel.selectedConversationID,
              let selectedConv = conversations.first(where: { $0.id == selectedID }) else {
            return
        }

        let key = selectedConv.isPinned ? "Pinned" : groupKey(for: selectedConv.timestamp ?? Date())
        if !expandedGroups.contains(key) {
            expandedGroups.insert(key)
        }
    }

    // --- Persistence ---
    private func loadExpandedGroupsState() {
        let savedGroups = UserDefaults.standard.stringArray(forKey: expandedGroupsKey)
        if let savedGroups = savedGroups {
            self.expandedGroups = Set(savedGroups)
        } else {
            self.expandedGroups = ["Today", "Previous 7 Days"]
        }
    }

    private func saveExpandedGroupsState() {
        UserDefaults.standard.set(Array(self.expandedGroups), forKey: expandedGroupsKey)
    }
}

// MARK: - Refined Disclosure Group Header
private struct DisclosureGroupHeader: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            // Animated chevron (leading position)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.5))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isExpanded)
                .frame(width: 16)

            // Title (Title Case, not uppercase)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.9))
                .padding(.leading, 2)

            // Conversation count badge
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


// MARK: - Refactored Conversation Row
private struct ConversationListRow: View {
    let conversation: ConversationEntity
    @ObservedObject var viewModel: MainApplicationViewModel

    @Binding var renamingConversationID: UUID?
    @Binding var editableConversationName: String
    var isRenameFieldFocused: FocusState<Bool>.Binding

    @Binding var conversationToDelete: ConversationEntity?
    @Binding var showingDeleteAlert: Bool

    var body: some View {
        ConversationRowView(
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
                conversationToDelete = conversation
                showingDeleteAlert = true
            }
        )
        .contextMenu {
            contextMenuContent
        }
    }

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
            self.editableConversationName = conversation.displayTitle
            self.renamingConversationID = conversation.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.isRenameFieldFocused.wrappedValue = true
            }
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Divider()

        Button(role: .destructive) {
            self.conversationToDelete = conversation
            self.showingDeleteAlert = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

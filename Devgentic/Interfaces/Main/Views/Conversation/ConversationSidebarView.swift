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
            // --- Top Bar with Search ---
            searchBar
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

            // --- Conversation List ---
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { // Increased spacing between sections
                    ForEach(sortedGroupKeys, id: \.self) { groupKey in
                        if let conversationsInGroup = groupedConversations[groupKey], !conversationsInGroup.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                let isExpanded = bindingForGroup(groupKey)
                                DisclosureGroupHeader(title: groupKey, isExpanded: isExpanded)
                                
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
        // Removed the dark overlay to allow native window/sidebar translucency
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
    
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary.opacity(0.7))
                .font(.system(size: 14))
            
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFieldFocused)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Modern glass-morphism style background
        .background(Color.white.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }
    
    @ViewBuilder
    private func disclosureGroupContent(for conversationsInGroup: [ConversationEntity]) -> some View {
        VStack(spacing: 2) { // Tighter spacing between rows
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

// MARK: - Custom Disclosure Group Header
private struct DisclosureGroupHeader: View {
    let title: String
    @Binding var isExpanded: Bool
    @State private var isHovering = false

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .bold)) // Smaller, punchier header
                .tracking(0.5) // Slight letter spacing
                .foregroundColor(.secondary.opacity(0.8))
                .textCase(.uppercase)
                .padding(.leading, 12) // Align with row text
            
            Spacer()

            Image(systemName: "chevron.right") // Use right chevron for standard macOS disclosure feel
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.6))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .padding(.trailing, 8)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Color.white.opacity(0.04) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture {
            isExpanded.toggle()
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

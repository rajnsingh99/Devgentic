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
        
        // Define the fixed order for recent groups
        let sortOrder = ["Pinned", "Today", "Yesterday", "Previous 7 Days", "Previous 30 Days"]
        
        return keys.sorted { key1, key2 in
            let index1 = sortOrder.firstIndex(of: key1)
            let index2 = sortOrder.firstIndex(of: key2)

            // Case 1: Both keys are in the fixed sort order
            if let i1 = index1, let i2 = index2 {
                return i1 < i2
            }
            
            // Case 2: Only key1 is in the fixed sort order
            if index1 != nil {
                return true
            }
            
            // Case 3: Only key2 is in the fixed sort order
            if index2 != nil {
                return false
            }
            
            // Case 4: Neither key is in the fixed sort order (they are month strings)
            // Sort by date descending (e.g., "August 2025" comes before "July 2025")
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMMM yyyy"
            if let date1 = dateFormatter.date(from: key1), let date2 = dateFormatter.date(from: key2) {
                return date1 > date2
            }
            
            // Fallback for safety
            return key1 > key2
        }
    }
    
    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            // --- Top Bar with Search ---
            searchBar
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 8)

            // --- Conversation List ---
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sortedGroupKeys, id: \.self) { groupKey in
                        if let conversationsInGroup = groupedConversations[groupKey], !conversationsInGroup.isEmpty {
                            // --- Custom Disclosure Group Implementation ---
                            VStack(alignment: .leading, spacing: 0) {
                                let isExpanded = bindingForGroup(groupKey)
                                DisclosureGroupHeader(title: groupKey, isExpanded: isExpanded)
                                
                                if isExpanded.wrappedValue {
                                    disclosureGroupContent(for: conversationsInGroup)
                                        .transition(.opacity.combined(with: .slide))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 5)
            }
        }
        .background(Color.black.opacity(0.4))
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
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("Search Conversations", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFieldFocused)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.windowBackgroundColor))
        .cornerRadius(8)
    }
    
    @ViewBuilder
    private func disclosureGroupContent(for conversationsInGroup: [ConversationEntity]) -> some View {
        // The ForEach now directly contains the row view
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
        formatter.dateFormat = "MMMM yyyy" // e.g., "August 2025"
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
    
    // --- Persistence Methods ---
    private func loadExpandedGroupsState() {
        let savedGroups = UserDefaults.standard.stringArray(forKey: expandedGroupsKey)
        if let savedGroups = savedGroups {
            self.expandedGroups = Set(savedGroups)
        } else {
            // If nothing is saved, default to expanding "Today"
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
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 8)
            
            Spacer()

            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Color.white.opacity(0.05) : Color.clear)
        .cornerRadius(5)
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

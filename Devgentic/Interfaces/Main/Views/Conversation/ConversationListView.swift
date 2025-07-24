// Views/ConversationListView.swift
import SwiftUI
import CoreData
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ConversationListView")

struct ConversationListView: View {
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
    @State private var expandedGroups: Set<String> = [] // Initialize as empty
    
    @State private var searchText = ""
    
    // --- State for Inline Renaming ---
    @State private var renamingConversationID: UUID?
    @State private var editableConversationName: String = ""
    
    // --- Focus States ---
    @FocusState private var isRenameFieldFocused: Bool
    @FocusState private var isSearchFieldFocused: Bool

    // --- Computed Properties for Grouping ---
    private var groupedConversations: [String: [ConversationEntity]] {
        if !searchText.isEmpty {
            return ["Search Results": Array(conversations)]
        } else {
            return Dictionary(grouping: conversations, by: {
                if $0.isPinned { return "Pinned" }
                return groupKey(for: $0.timestamp ?? Date())
            })
        }
    }

    private var sortedGroupKeys: [String] {
        if !searchText.isEmpty {
            return ["Search Results"]
        }
        
        let groupDateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM d, yy"
            return formatter
        }()
        
        return groupedConversations.keys.sorted { key1, key2 in
            if key1 == "Pinned" { return true }
            if key2 == "Pinned" { return false }
            if key1 == "Today" { return true }
            if key2 == "Today" { return false }
            if key1 == "Yesterday" { return true }
            if key2 == "Yesterday" { return false }
            if let date1 = groupDateFormatter.date(from: key1), let date2 = groupDateFormatter.date(from: key2) {
                return date1 > date2
            }
            return key1 > key2
        }
    }
    
    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            // --- Enhanced Search Bar ---
            searchBar
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 5)

            // --- Conversation List ---
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(sortedGroupKeys, id: \.self) { groupKey in
                        if let conversationsInGroup = groupedConversations[groupKey], !conversationsInGroup.isEmpty {
                            // --- Custom Disclosure Group Implementation ---
                            VStack(alignment: .leading, spacing: 0) {
                                let isExpanded = bindingForGroup(groupKey)
                                DisclosureGroupHeader(title: groupKey, isExpanded: isExpanded.wrappedValue)
                                    .onTapGesture {
                                        // Toggling the binding triggers the animation in its setter
                                        isExpanded.wrappedValue.toggle()
                                    }
                                
                                if isExpanded.wrappedValue {
                                    disclosureGroupContent(for: conversationsInGroup)
                                        .transition(.opacity.combined(with: .slide))
                                }
                            }
                            .padding(.horizontal, 5)
                        }
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .alert("Delete Conversation?", isPresented: $showingDeleteAlert, presenting: conversationToDelete) { conv in
            Button("Delete", role: .destructive) {
                if let id = conv.id {
                    viewModel.deleteConversation(conversationID: id)
                }
            }
        }
        .onChange(of: searchText) { newValue in
            updatePredicate(with: newValue)
        }
        .onChange(of: viewModel.selectedConversationID) { _ in
            expandGroupForSelection()
        }
        .onAppear {
            // If no groups are expanded yet, expand the top-most date group (not "Pinned").
            if expandedGroups.isEmpty {
                if let firstDateGroup = sortedGroupKeys.first(where: { $0 != "Pinned" }) {
                    expandedGroups.insert(firstDateGroup)
                }
            }
            // Also ensure the selected conversation's group is expanded if it's different.
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
            
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSearchFieldFocused ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: 1.5)
        )
    }
    
    @ViewBuilder
    private func disclosureGroupContent(for conversationsInGroup: [ConversationEntity]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
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
        .padding(.leading, 10).padding(.top, 5).padding(.bottom, 5)
    }
    
    // MARK: - Helper Methods

    private func updatePredicate(with query: String) {
        if query.isEmpty {
            conversations.nsPredicate = nil
        } else {
            let titlePredicate = NSPredicate(format: "userDefinedTitle CONTAINS[c] %@", query)
            let messageContentPredicate = NSPredicate(format: "SUBQUERY(messages, $message, $message.text_content CONTAINS[c] %@).@count > 0", query)
            conversations.nsPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: [titlePredicate, messageContentPredicate])
        }
    }

    private func groupKey(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yy"
        return formatter.string(from: date)
    }
    
    private func bindingForGroup(_ groupKey: String) -> Binding<Bool> {
        if groupKey == "Search Results" {
            return .constant(true)
        }
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
}

// MARK: - Custom Disclosure Group Header
private struct DisclosureGroupHeader: View {
    let title: String
    let isExpanded: Bool
    @State private var isHovering = false

    var body: some View {
        HStack {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))

            Text(title)
                .font(.subheadline).fontWeight(.medium)
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Color.secondary.opacity(0.15) : Color.clear)
        .cornerRadius(5)
        .contentShape(Rectangle())
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
                Label("Unpin", systemImage: "pin.slash.fill")
            } else {
                Label("Pin", systemImage: "pin.fill")
            }
        }
        
        Button {
            self.editableConversationName = conversation.userDefinedTitle ?? ""
            self.renamingConversationID = conversation.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.isRenameFieldFocused.wrappedValue = true
            }
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button(role: .destructive) {
            self.conversationToDelete = conversation
            self.showingDeleteAlert = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

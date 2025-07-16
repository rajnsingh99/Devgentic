// Views/ConversationListView.swift
import SwiftUI
import CoreData
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ConversationListView")

struct ConversationListView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.managedObjectContext) private var viewContext

    // --- Core Data Fetch Request ---
    // This property wrapper fetches ConversationEntity objects from Core Data,
    // automatically sorts them, and updates the view when the data changes.
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ConversationEntity.timestamp, ascending: false)],
        animation: .default)
    private var conversations: FetchedResults<ConversationEntity>

    // --- Local State ---
    @State private var showingDeleteAlert = false
    @State private var conversationToDelete: ConversationEntity? = nil
    @State private var showingRenameAlert = false
    @State private var conversationToRename: ConversationEntity? = nil
    @State private var newConversationName: String = ""
    @State private var expandedGroups: Set<String> = ["Today"]

    // --- Computed Properties for Grouping ---
    private var groupedConversations: [String: [ConversationEntity]] {
        Dictionary(grouping: conversations, by: { groupKey(for: $0.timestamp ?? Date()) })
    }

    private var sortedGroupKeys: [String] {
        let groupDateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM d, yy"
            return formatter
        }()
        
        return groupedConversations.keys.sorted { key1, key2 in
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sortedGroupKeys, id: \.self) { groupKey in
                    if let conversationsInGroup = groupedConversations[groupKey] {
                        DisclosureGroup(
                            isExpanded: bindingForGroup(groupKey),
                            content: { disclosureGroupContent(for: conversationsInGroup) },
                            label: { disclosureGroupLabel(for: groupKey) }
                        )
                        .padding(.horizontal, 5).padding(.bottom, 3)
                    }
                }
            }
            .padding(.vertical, 10)
        }
        .alert("Delete Conversation?", isPresented: $showingDeleteAlert, presenting: conversationToDelete) { conv in
            Button("Delete", role: .destructive) {
                if let id = conv.id {
                    viewModel.deleteConversation(conversationID: id)
                }
            }
        }
        .alert("Rename Conversation", isPresented: $showingRenameAlert, presenting: conversationToRename) { conv in
            TextField("Enter new name", text: $newConversationName)
            Button("Rename") {
                if let id = conv.id {
                    viewModel.renameConversation(conversationID: id, newTitle: newConversationName)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        // --- FIX: Use modern closure-based syntax for onChange ---
        .onChange(of: viewModel.selectedConversationID) { _ in
            expandGroupForSelection()
        }
        // --------------------------------------------------------
        .onAppear(perform: expandGroupForSelection)
    }

    // MARK: - Sub Views
    
    @ViewBuilder
    private func disclosureGroupContent(for conversationsInGroup: [ConversationEntity]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(conversationsInGroup) { conversation in
                ConversationRowView(
                    // We convert the entity to a struct for the row view.
                    // This decouples the row view from Core Data.
                    conversation: conversation.toConversationStruct(),
                    isSelected: viewModel.selectedConversationID == conversation.id,
                    onSelect: {
                        viewModel.selectedConversationID = conversation.id
                    }
                )
                .contextMenu {
                    contextMenuContent(for: conversation)
                }
            }
        }
        .padding(.leading, 10).padding(.bottom, 5)
    }

    @ViewBuilder
    private func disclosureGroupLabel(for groupKey: String) -> some View {
        Text(groupKey)
            .font(.subheadline).fontWeight(.medium)
            .foregroundColor(.secondary)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func contextMenuContent(for conversation: ConversationEntity) -> some View {
        Button {
            self.conversationToRename = conversation
            self.newConversationName = conversation.userDefinedTitle ?? ""
            self.showingRenameAlert = true
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
    
    // MARK: - Helper Methods

    private func groupKey(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yy"
        return formatter.string(from: date)
    }
    
    private func bindingForGroup(_ groupKey: String) -> Binding<Bool> {
        Binding(
            get: { self.expandedGroups.contains(groupKey) },
            set: { isExpanding in
                if isExpanding { self.expandedGroups.insert(groupKey) }
                else { self.expandedGroups.remove(groupKey) }
            }
        )
    }
    
    private func expandGroupForSelection() {
        guard let selectedID = viewModel.selectedConversationID,
              let selectedConv = conversations.first(where: { $0.id == selectedID }) else {
            return
        }
        let key = groupKey(for: selectedConv.timestamp ?? Date())
        if !expandedGroups.contains(key) {
            expandedGroups.insert(key)
        }
    }
}

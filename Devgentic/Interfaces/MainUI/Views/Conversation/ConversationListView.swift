// Views/ConversationListView.swift
import SwiftUI
import os

// Logger
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ConversationListView")

struct ConversationListView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel // Uses EnvironmentObject
    // Removed `onNewConversation` property as it's handled by the New Chat tab now

    // State for Delete Confirmation Alert
    @State private var showingDeleteAlert = false
    @State private var conversationToDelete: Conversation? = nil

    // State for Rename Alert
    @State private var showingRenameAlert = false
    @State private var conversationToRename: Conversation? = nil
    @State private var newConversationName: String = ""

    var body: some View {
        // Removed outer ZStack and background color
        // Removed fixed frame modifier

        // List of Conversations (using ScrollView and DisclosureGroups)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Use ViewModel's data directly
                ForEach(viewModel.sortedGroupKeys, id: \.self) { groupKey in
                    // Check if group contains selected item
                    let isGroupSelected = viewModel.groupedConversations[groupKey]?.contains(where: { $0.id == viewModel.selectedConversationID }) ?? false
                    DisclosureGroup(
                        // Keep Today expanded or if selected item is in this group
                        isExpanded: .constant(isGroupSelected || groupKey == "Today"),
                        content: {
                            // Ensure group exists
                            if let conversationsInGroup = viewModel.groupedConversations[groupKey] {
                                VStack(alignment: .leading, spacing: 5) {
                                    ForEach(conversationsInGroup) { conversation in
                                        // Conversation Row
                                        HStack {
                                            Text(conversation.displayTitle) // Uses updated displayTitle
                                                // Use standard text colors that adapt
                                                .foregroundColor(viewModel.selectedConversationID == conversation.id ? .accentColor : .primary)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 6)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }
                                        // Use standard background highlight for selection
                                        .background(viewModel.selectedConversationID == conversation.id ? Color.accentColor.opacity(0.2) : Color.clear)
                                        .cornerRadius(5)
                                        .contentShape(Rectangle())
                                        .onTapGesture { viewModel.selectedConversationID = conversation.id } // Select via ViewModel
                                        .contextMenu { // Context Menu for Rename & Delete
                                            // Rename Button
                                            Button {
                                                self.conversationToRename = conversation
                                                self.newConversationName = conversation.userDefinedTitle ?? ""
                                                self.showingRenameAlert = true
                                                logger.debug("Rename context menu tapped for conversation: \(conversation.id.uuidString)")
                                            } label: {
                                                Label("Rename Conversation", systemImage: "pencil")
                                            }

                                            // Delete Button
                                            Button(role: .destructive) {
                                                self.conversationToDelete = conversation
                                                self.showingDeleteAlert = true
                                                logger.debug("Delete context menu tapped for conversation: \(conversation.id.uuidString)")
                                            } label: {
                                                Label("Delete Conversation", systemImage: "trash")
                                            }
                                        } // End contextMenu
                                    } // End ForEach Conversation
                                }
                                .padding(.leading, 10) // Indent items within the group
                                .padding(.bottom, 5)
                            } // End if let conversationsInGroup
                        }, // End DisclosureGroup Content
                        label: { // DisclosureGroup Label
                            Text(groupKey)
                                .font(.subheadline).fontWeight(.medium) // Adjusted font
                                .foregroundColor(.secondary) // Standard secondary color
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } // End DisclosureGroup Label
                    ) // End DisclosureGroup
                    .accentColor(.secondary) // Control disclosure indicator color
                    // Removed background highlighting for the group itself
                    .padding(.horizontal, 5) // Add horizontal padding to the group
                    .padding(.bottom, 3)
                } // End ForEach Group Key
            } // End VStack for Groups
            .padding(.vertical, 10) // Add padding top/bottom for the whole list
        } // End ScrollView
        // Alerts remain attached here as they are specific to this view's state
        .alert(
            "Delete Conversation?", isPresented: $showingDeleteAlert, presenting: conversationToDelete
        ) { conversation in
            Button(role: .destructive) {
                 logger.info("Confirmed deletion for conversation: \(conversation.id.uuidString)")
                 viewModel.deleteConversation(conversationID: conversation.id)
                 self.conversationToDelete = nil
            } label: { Text("Delete") }
            Button("Cancel", role: .cancel) { self.conversationToDelete = nil }
        } message: { conversation in
            Text("Are you sure you want to delete the conversation titled \"\(conversation.displayTitle)\"? This action cannot be undone.")
        }
        .alert(
            "Rename Conversation", isPresented: $showingRenameAlert, presenting: conversationToRename
        ) { conversation in
            TextField("Enter new name", text: $newConversationName)
                .onSubmit {
                    if conversationToRename != nil {
                         viewModel.renameConversation(conversationID: conversation.id, newTitle: newConversationName)
                         self.conversationToRename = nil; self.newConversationName = ""; self.showingRenameAlert = false
                    }
                }
            Button("Rename") {
                viewModel.renameConversation(conversationID: conversation.id, newTitle: newConversationName)
                self.conversationToRename = nil; self.newConversationName = ""
            }
            .disabled(newConversationName.trimmingCharacters(in: .whitespacesAndNewlines) == (conversation.userDefinedTitle ?? ""))
            Button("Cancel", role: .cancel) {
                self.conversationToRename = nil; self.newConversationName = ""
            }
        } message: { conversation in
            Text("Enter a new name for \"\(conversation.displayTitle)\":")
        }
    } // End body
} // End struct ConversationListView

// Preview Provider (Needs adjustment as onNewConversation is removed)
struct ConversationListView_Previews_Modified: PreviewProvider { // Renamed preview struct
    static let previewViewModel: MainApplicationViewModel = {
         let vm = MainApplicationViewModel()
         // Add some mock conversations for preview
         vm.conversations = [
             Conversation(id: UUID(), messages: [], timestamp: Date(), userDefinedTitle: "Today Chat 1"),
             Conversation(id: UUID(), messages: [], timestamp: Calendar.current.date(byAdding: .day, value: -1, to: Date())!, userDefinedTitle: "Yesterday Chat"),
             Conversation(id: UUID(), messages: [], timestamp: Calendar.current.date(byAdding: .day, value: -3, to: Date())!, userDefinedTitle: "Older Chat")
         ]
         vm.selectedConversationID = vm.conversations[0].id // Select the first one
         return vm
    }()

    static var previews: some View {
        // Removed onNewConversation closure
        ConversationListView()
            .environmentObject(previewViewModel)
            .frame(width: 250, height: 500) // Provide frame for preview context
            .previewDisplayName("Modified Conversation List")
    }
}

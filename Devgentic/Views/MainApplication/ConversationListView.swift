// Views/ConversationListView.swift
import SwiftUI
import os

// Logger
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ConversationListView")

struct ConversationListView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel // Uses EnvironmentObject
    let onNewConversation: () -> Void

    // State for Delete Confirmation Alert (Part A)
    @State private var showingDeleteAlert = false
    @State private var conversationToDelete: Conversation? = nil

    // State for Rename Alert (Part B)
    @State private var showingRenameAlert = false
    @State private var conversationToRename: Conversation? = nil
    @State private var newConversationName: String = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.25) // Background
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("Conversations")
                        .font(.title3).fontWeight(.semibold).foregroundColor(.white)
                    Spacer()
                    Button(action: onNewConversation) {
                        Image(systemName: "plus.circle.fill").foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding()

                Divider().background(Color.white.opacity(0.2))

                // List of Conversations
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Use ViewModel's data directly
                        ForEach(viewModel.sortedGroupKeys, id: \.self) { groupKey in
                            // Check if group contains selected item
                            let isGroupSelected = viewModel.groupedConversations[groupKey]?.contains(where: { $0.id == viewModel.selectedConversationID }) ?? false
                            DisclosureGroup(
                                isExpanded: .constant(isGroupSelected || groupKey == "Today"), // Keep Today expanded or if selected
                                content: {
                                    // Ensure group exists
                                    if let conversationsInGroup = viewModel.groupedConversations[groupKey] {
                                        VStack(alignment: .leading, spacing: 5) {
                                            ForEach(conversationsInGroup) { conversation in
                                                // Conversation Row
                                                HStack {
                                                    Text(conversation.displayTitle) // Uses updated displayTitle
                                                        .foregroundColor(viewModel.selectedConversationID == conversation.id ? .cyan : .white)
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 6)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .lineLimit(1)
                                                        .truncationMode(.tail)
                                                }
                                                .background(viewModel.selectedConversationID == conversation.id ? Color.blue.opacity(0.4) : Color.clear)
                                                .cornerRadius(5)
                                                .contentShape(Rectangle())
                                                .onTapGesture { viewModel.selectedConversationID = conversation.id } // Select via ViewModel
                                                .contextMenu { // Context Menu for Rename & Delete
                                                    // Rename Button (Part B)
                                                    Button {
                                                        self.conversationToRename = conversation
                                                        self.newConversationName = conversation.userDefinedTitle ?? ""
                                                        self.showingRenameAlert = true
                                                        logger.debug("Rename context menu tapped for conversation: \(conversation.id.uuidString)")
                                                    } label: {
                                                        Label("Rename Conversation", systemImage: "pencil")
                                                    }

                                                    // Delete Button (Part A)
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
                                        .padding(.leading, 10)
                                        .padding(.bottom, 5)
                                    } // End if let conversationsInGroup
                                }, // End DisclosureGroup Content
                                label: { // DisclosureGroup Label
                                    Text(groupKey)
                                        .font(.footnote).fontWeight(.semibold)
                                        .foregroundColor(isGroupSelected ? .white.opacity(0.9) : .gray)
                                        .padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } // End DisclosureGroup Label
                            ) // End DisclosureGroup
                            .accentColor(.white.opacity(0.7))
                            .background(isGroupSelected ? Color.white.opacity(0.1) : Color.clear)
                            .cornerRadius(4)
                            .padding(.horizontal, 5)
                            .padding(.leading, 5)
                            .padding(.bottom, 3)
                        } // End ForEach Group Key
                    } // End VStack for Groups
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                } // End ScrollView
                Spacer() // Pushes content to the top
            } // End Main VStack
        } // End ZStack
        .frame(width: 240) // Fixed width
        .transition(.move(edge: .leading))
        // Delete Alert (Part A)
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
        // Rename Alert (Part B - Requires macOS 13+)
        .alert(
            "Rename Conversation", isPresented: $showingRenameAlert, presenting: conversationToRename
        ) { conversation in
            TextField("Enter new name", text: $newConversationName)
                .onSubmit { // Handle Enter key submission
                    if conversationToRename != nil {
                         viewModel.renameConversation(conversationID: conversation.id, newTitle: newConversationName)
                         self.conversationToRename = nil; self.newConversationName = ""; self.showingRenameAlert = false
                    }
                }
            Button("Rename") {
                viewModel.renameConversation(conversationID: conversation.id, newTitle: newConversationName)
                self.conversationToRename = nil; self.newConversationName = ""
            }
            .disabled(newConversationName.trimmingCharacters(in: .whitespacesAndNewlines) == (conversation.userDefinedTitle ?? "")) // Disable if name hasn't effectively changed

            Button("Cancel", role: .cancel) {
                self.conversationToRename = nil; self.newConversationName = ""
            }
        } message: { conversation in
            Text("Enter a new name for \"\(conversation.displayTitle)\":")
        }
    } // End body
} // End struct ConversationListView

// Preview Provider (Keep as is, injects ViewModel)
struct ConversationListView_Previews: PreviewProvider {
    static let previewViewModel: MainApplicationViewModel = { /* ... create VM ... */
         let vm = MainApplicationViewModel()
         return vm
    }()

    static var previews: some View {
        ConversationListView(
            onNewConversation: { print("Preview: New Conversation Tapped") }
        )
        .environmentObject(previewViewModel)
        .frame(height: 500)
    }
}

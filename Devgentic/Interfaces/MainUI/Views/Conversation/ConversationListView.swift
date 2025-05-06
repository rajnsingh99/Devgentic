// Views/ConversationListView.swift
import SwiftUI
import os

// Logger
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ConversationListView")

struct ConversationListView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel

    // --- State for Standard Operations ---
    @State private var showingDeleteAlert = false
    @State private var conversationToDelete: Conversation? = nil
    @State private var showingRenameAlert = false
    @State private var conversationToRename: Conversation? = nil
    @State private var newConversationName: String = ""
    @State private var expandedGroups: Set<String> = ["Today"]

    // --- State for Multi-Select & Delete ---
    @State private var isEditing: Bool = false // To toggle multi-select mode
    @State private var selectedItemsForDeletion: Set<UUID> = []
    @State private var showingMultiDeleteAlert: Bool = false
    // ---------------------------------------

    // --- State for Group Delete ---
    @State private var showingGroupDeleteAlert: Bool = false
    @State private var groupToDelete: String? = nil
    // ------------------------------

    // Helper function for DisclosureGroup binding
    private func bindingForGroup(_ groupKey: String) -> Binding<Bool> {
        Binding(
            get: { self.expandedGroups.contains(groupKey) },
            set: { isExpanding in
                if isExpanding {
                    self.expandedGroups.insert(groupKey)
                    logger.debug("Expanding group: \(groupKey)")
                } else {
                    self.expandedGroups.remove(groupKey)
                    logger.debug("Collapsing group: \(groupKey)")
                }
            }
        )
    }

    // MARK: - Body
    var body: some View {
        // --- Root ScrollView ---
        ScrollView {
            // --- Main VStack for Groups ---
            VStack(alignment: .leading, spacing: 0) {
                // --- Loop Through Conversation Groups ---
                ForEach(viewModel.sortedGroupKeys, id: \.self) { groupKey in
                    DisclosureGroup(
                        isExpanded: bindingForGroup(groupKey),
                        content: { disclosureGroupContent(for: groupKey) },
                        label: { disclosureGroupLabel(for: groupKey) }
                    )
                    .accentColor(.secondary)
                    // --- Context Menu for Group Deletion ---
                    .contextMenu {
                        Button(role: .destructive) {
                            self.groupToDelete = groupKey
                            self.showingGroupDeleteAlert = true
                            logger.debug("Context menu: Delete group '\(groupKey)' tapped.")
                        } label: {
                            Label("Delete All in \"\(groupKey)\"", systemImage: "trash.fill")
                        }
                    }
                    // ---------------------------------------
                    .padding(.horizontal, 5)
                    .padding(.bottom, 3)
                } // End ForEach Group Key
            } // End VStack for Groups
            .padding(.vertical, 10)
        } // End ScrollView
        // --- Standard Alerts ---
        .alert( // Single Delete Alert
            "Delete Conversation?", isPresented: $showingDeleteAlert, presenting: conversationToDelete
        ) { conversation in deleteAlertButtons(conversation: conversation) }
        message: { conversation in deleteAlertMessage(conversation: conversation) }
        .alert( // Rename Alert
            "Rename Conversation", isPresented: $showingRenameAlert, presenting: conversationToRename
        ) { conversation in renameAlertContent(conversation: conversation) }
        message: { conversation in renameAlertMessage(conversation: conversation) }
        // --- Multi-Delete Alert ---
        .alert(
            "Delete \(selectedItemsForDeletion.count) Conversations?",
            isPresented: $showingMultiDeleteAlert,
            presenting: selectedItemsForDeletion // Pass the set for context if needed
        ) { itemsToDelete in // The itemsToDelete here is the Set<UUID>
            Button(role: .destructive) {
                logger.info("Confirmed multi-delete for \(itemsToDelete.count) items.")
                viewModel.deleteMultipleConversations(ids: itemsToDelete)
                // Exit edit mode and clear selection after deleting
                selectedItemsForDeletion.removeAll()
                isEditing = false
            } label: { Text("Delete \(itemsToDelete.count)") }
            Button("Cancel", role: .cancel) { /* Only dismisses alert */ }
        } message: { itemsToDelete in
            Text("Are you sure you want to permanently delete these \(itemsToDelete.count) conversations? This action cannot be undone.")
        }
        // --- Group Delete Alert ---
        .alert(
            "Delete All in \"\(groupToDelete ?? "Group")\"?",
            isPresented: $showingGroupDeleteAlert,
            presenting: groupToDelete // Pass the group key string
        ) { keyToDelete in // keyToDelete is the String group key
            Button(role: .destructive) {
                logger.info("Confirmed group delete for key: \(keyToDelete)")
                viewModel.deleteConversationsInGroup(groupKey: keyToDelete)
                self.groupToDelete = nil // Clear state
            } label: { Text("Delete All") }
            Button("Cancel", role: .cancel) { self.groupToDelete = nil }
        } message: { keyToDelete in
             // You might want to fetch the count here if needed, but a generic message is simpler
            Text("Are you sure you want to permanently delete all conversations in the \"\(keyToDelete)\" group? This action cannot be undone.")
        }
        // --- Lifecycle Modifiers ---
        .onAppear(perform: expandGroupForSelection)
        .onChange(of: viewModel.selectedConversationID) { _ in expandGroupForSelection() }
        // --- TODO: Add Toolbar/Buttons to toggle `isEditing` and trigger multi-delete ---
        // Example (conceptual, placement needs integration with parent view like SideBarPaneView):
        /*
         .toolbar {
             ToolbarItemGroup(placement: .automatic) { // Or other appropriate placement
                 if isEditing {
                     Button("Cancel") {
                         isEditing = false
                         selectedItemsForDeletion.removeAll()
                     }
                     Spacer()
                     Button("Delete \(selectedItemsForDeletion.count)") {
                         showingMultiDeleteAlert = true
                     }
                     .disabled(selectedItemsForDeletion.isEmpty)
                 } else {
                     Button("Edit") {
                         isEditing = true
                         // Optionally clear main selection when entering edit mode?
                         // viewModel.selectedConversationID = nil
                     }
                 }
             }
         }
         */
    } // End body

    // MARK: - Sub Views / Helper Functions

    /// Builds the content view for a disclosure group (the list of conversations).
    @ViewBuilder
    private func disclosureGroupContent(for groupKey: String) -> some View {
        // Ensure group exists in the view model's data
        if let conversationsInGroup = viewModel.groupedConversations[groupKey] {
            VStack(alignment: .leading, spacing: 2) { // Use a VStack for the list within the group
                // --- Loop Through Conversations in Group ---
                ForEach(conversationsInGroup) { conversation in
                    // --- Modified Row View Usage ---
                    HStack { // Wrap ConversationRowView to add selection controls if editing
                        if isEditing {
                            // Checkbox or similar indicator
                            Image(systemName: selectedItemsForDeletion.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selectedItemsForDeletion.contains(conversation.id) ? .accentColor : .secondary)
                                .onTapGesture {
                                    toggleMultiSelection(id: conversation.id)
                                }
                                .padding(.leading, 5) // Add padding for the checkbox
                        }

                        ConversationRowView(
                            conversation: conversation,
                            // Dim selection highlight if in edit mode and not selected for deletion
                            isSelected: !isEditing && viewModel.selectedConversationID == conversation.id,
                            onSelect: {
                                handleItemTap(conversation: conversation) // Use helper for tap logic
                            }
                        )
                        // Apply standard context menu only when NOT editing
                        .contextMenu {
                            if !isEditing {
                                contextMenuContent(for: conversation)
                            }
                            // Implicitly returns EmptyView if isEditing is true
                        }

                    } // End HStack wrapper
                    // -----------------------------
                } // End ForEach Conversation
            }
            .padding(.leading, isEditing ? 0 : 10) // Adjust indent based on editing state
            .padding(.bottom, 5)   // Space below the list within the group
        } else {
            // Optional: Show something if group is unexpectedly empty
            EmptyView()
        }
    }

    /// Builds the label view for a disclosure group (the date header).
    @ViewBuilder
    private func disclosureGroupLabel(for groupKey: String) -> some View {
        Text(groupKey)
            .font(.subheadline).fontWeight(.medium) // Style the date header
            .foregroundColor(.secondary)
            .padding(.vertical, 6) // Vertical padding for the header
            .frame(maxWidth: .infinity, alignment: .leading) // Ensure it takes full width
    }

    /// Builds the context menu content (Rename/Delete buttons) for a conversation row.
    @ViewBuilder
    private func contextMenuContent(for conversation: Conversation) -> some View {
        // Rename Button
        Button {
            // Set state variables to show the rename alert
            self.conversationToRename = conversation
            self.newConversationName = conversation.userDefinedTitle ?? "" // Pre-fill with current name
            self.showingRenameAlert = true
            logger.debug("Rename context menu tapped for conversation: \(conversation.id.uuidString)")
        } label: {
            Label("Rename Conversation", systemImage: "pencil")
        }

        // Single Delete Button
        Button(role: .destructive) {
            // Set state variable to show the delete alert
            self.conversationToDelete = conversation
            self.showingDeleteAlert = true
            logger.debug("Delete context menu tapped for conversation: \(conversation.id.uuidString)")
        } label: {
            Label("Delete Conversation", systemImage: "trash")
        }
    }

    // MARK: - Alert Content Helpers

    /// Builds the buttons for the delete confirmation alert.
    @ViewBuilder
    private func deleteAlertButtons(conversation: Conversation) -> some View {
        Button(role: .destructive) {
             logger.info("Confirmed deletion for conversation: \(conversation.id.uuidString)")
             viewModel.deleteConversation(conversationID: conversation.id) // Call ViewModel action
             self.conversationToDelete = nil // Clear state after action
        } label: { Text("Delete") }
        Button("Cancel", role: .cancel) { self.conversationToDelete = nil } // Clear state on cancel
    }

    /// Builds the message text for the delete confirmation alert.
    private func deleteAlertMessage(conversation: Conversation) -> Text {
        Text("Are you sure you want to delete the conversation titled \"\(conversation.displayTitle)\"? This action cannot be undone.")
    }

    /// Builds the content (TextField, Buttons) for the rename alert.
    @ViewBuilder
    private func renameAlertContent(conversation: Conversation) -> some View {
        TextField("Enter new name", text: $newConversationName)
            .onSubmit { // Handle submission via Enter key
                renameConversationAction(conversation: conversation)
            }
        Button("Rename") {
            renameConversationAction(conversation: conversation)
        }
        // Disable button if name hasn't changed (ignoring leading/trailing whitespace)
        .disabled(newConversationName.trimmingCharacters(in: .whitespacesAndNewlines) == (conversation.userDefinedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        Button("Cancel", role: .cancel) {
            // Clear state on cancel
            self.conversationToRename = nil
            self.newConversationName = ""
        }
    }

    /// Builds the message text for the rename alert.
    private func renameAlertMessage(conversation: Conversation) -> Text {
         Text("Enter a new name for \"\(conversation.displayTitle)\":")
    }

    // MARK: - Actions

    /// Handles tap action on a conversation row, switching between selection and multi-select.
    private func handleItemTap(conversation: Conversation) {
        if isEditing {
            // Toggle selection for multi-delete
            toggleMultiSelection(id: conversation.id)
        } else {
            // Normal selection behavior
            viewModel.selectedConversationID = conversation.id
        }
    }

    /// Adds or removes a conversation ID from the multi-delete selection set.
    private func toggleMultiSelection(id: UUID) {
        if selectedItemsForDeletion.contains(id) {
            selectedItemsForDeletion.remove(id)
            logger.trace("Removed \(id.uuidString) from multi-delete selection.")
        } else {
            selectedItemsForDeletion.insert(id)
            logger.trace("Added \(id.uuidString) to multi-delete selection.")
        }
    }


    /// Performs the actual rename logic and resets state variables.
    private func renameConversationAction(conversation: Conversation) {
        let trimmedName = newConversationName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only call ViewModel if the trimmed name is actually different from the original trimmed name
        if trimmedName != (conversation.userDefinedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
            viewModel.renameConversation(conversationID: conversation.id, newTitle: trimmedName)
        }
        // Reset state regardless of whether the rename call was made
        self.conversationToRename = nil
        self.newConversationName = ""
        self.showingRenameAlert = false // Explicitly dismiss alert by resetting state flag
    }

    /// Expands the disclosure group containing the currently selected conversation.
    /// Called on appear and when the selection changes.
    private func expandGroupForSelection() {
        // 1. Guard to get the selected conversation
        guard let selectedID = viewModel.selectedConversationID,
              let selectedConv = viewModel.conversations.first(where: { $0.id == selectedID }) else {
            return // Exit if no selection or conversation not found
        }

        // 2. Call the function to get the group key (it returns a non-optional String)
        let groupKey = viewModel.groupKey(for: selectedConv.timestamp)

        // If the group is not already in the set of expanded groups, add it
        if !expandedGroups.contains(groupKey) {
            expandedGroups.insert(groupKey)
            logger.debug("Expanding group '\(groupKey)' due to selection.")
        }
    }

} // End struct ConversationListView

// Preview Provider (Using the wrapper from previous version for edit mode testing)
struct ConversationListView_Previews_Modified: PreviewProvider {
    static let previewViewModel: MainApplicationViewModel = {
         let vm = MainApplicationViewModel()
         // Add some mock conversations for preview
         vm.conversations = [
             Conversation(id: UUID(), messages: [], timestamp: Date(), userDefinedTitle: "Today Chat 1"),
             Conversation(id: UUID(), messages: [], timestamp: Date(), userDefinedTitle: "Today Chat 2"),
             Conversation(id: UUID(), messages: [], timestamp: Calendar.current.date(byAdding: .day, value: -1, to: Date())!, userDefinedTitle: "Yesterday Chat"),
             Conversation(id: UUID(), messages: [], timestamp: Calendar.current.date(byAdding: .day, value: -3, to: Date())!, userDefinedTitle: "Older Chat")
         ]
         vm.selectedConversationID = vm.conversations[0].id // Select the first one
         return vm
    }()

    // --- Wrapper to manage @State for preview ---
    struct PreviewWrapper: View {
        @StateObject var vm = previewViewModel
        // Add state corresponding to ConversationListView's state
        // This allows the preview to simulate the parent view controlling edit mode
        @State private var isEditingPreview = false
        @State private var selectedItemsPreview: Set<UUID> = [] // This specific state isn't directly bound, ConversationListView manages its own

        var body: some View {
            VStack {
                 // Add controls to toggle edit mode in preview
                 Toggle("Edit Mode (Preview Control)", isOn: $isEditingPreview)
                     .padding(.horizontal)

                 ConversationListView(
                    // Pass the isEditing state down if ConversationListView expects it as a @Binding
                    // For now, ConversationListView uses its own @State for isEditing
                    // isEditing: $isEditingPreview // Example if binding was used
                 )
                 .environmentObject(vm)
                 // You might need to manually set the isEditing state inside ConversationListView
                 // for preview purposes if it's not bound from the parent.
                 // This preview currently doesn't directly control the isEditing state *inside* the list.
            }
        }
    }
    // -------------------------------------------

    static var previews: some View {
        // Use the PreviewWrapper
        PreviewWrapper()
            .frame(width: 250, height: 500)
            .previewDisplayName("Modified Conversation List")
    }
}

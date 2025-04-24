// Views/ConversationListView.swift
import SwiftUI
import os // For logger if needed later

// Logger (Optional, uncomment if needed)
// private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ConversationListView")

struct ConversationListView: View {
    // Data passed down from the parent view
    let groupedConversations: [String: [Conversation]]
    let sortedGroupKeys: [String]
    @Binding var selectedConversationID: UUID?
    let onNewConversation: () -> Void // Action to trigger new conversation

    var body: some View {
        ZStack {
            Color.black.opacity(0.25) // Background for the sidebar
            VStack(alignment: .leading, spacing: 0) {
                // Header with New Chat Button
                HStack {
                    Text("Conversations")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: onNewConversation) { // Use the passed closure
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding()

                Divider().background(Color.white.opacity(0.2))

                // List of Conversations (Using DisclosureGroup)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sortedGroupKeys, id: \.self) { groupKey in
                            // Determine if any conversation in this group is selected
                            let isGroupSelected = groupedConversations[groupKey]?.contains(where: { $0.id == selectedConversationID }) ?? false

                            DisclosureGroup(
                                // Keep Today expanded, or any group containing the selected chat
                                isExpanded: .constant(isGroupSelected || groupKey == "Today"),
                                content: {
                                    // Ensure the group exists before iterating
                                    if let conversationsInGroup = groupedConversations[groupKey] {
                                        VStack(alignment: .leading, spacing: 5) {
                                            ForEach(conversationsInGroup) { conversation in
                                                HStack {
                                                    Text(conversation.displayTitle)
                                                        .foregroundColor(selectedConversationID == conversation.id ? .cyan : .white)
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 6)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .lineLimit(1)
                                                        .truncationMode(.tail)
                                                }
                                                .background(selectedConversationID == conversation.id ? Color.blue.opacity(0.4) : Color.clear)
                                                .cornerRadius(5)
                                                .contentShape(Rectangle()) // Make the whole area tappable
                                                .onTapGesture {
                                                    // Update the binding when a conversation is tapped
                                                    selectedConversationID = conversation.id
                                                }
                                            }
                                        }
                                        .padding(.leading, 10) // Indent conversations under the group
                                        .padding(.bottom, 5)
                                    }
                                },
                                label: {
                                    Text(groupKey)
                                        .font(.footnote)
                                        .fontWeight(.semibold)
                                        .foregroundColor(isGroupSelected ? .white.opacity(0.9) : .gray)
                                        .padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading) // Ensure label takes full width
                                }
                            )
                            .accentColor(.white.opacity(0.7)) // Style the disclosure indicator
                            .background(isGroupSelected ? Color.white.opacity(0.1) : Color.clear) // Subtle background for selected group
                            .cornerRadius(4)
                            .padding(.horizontal, 5)
                            .padding(.leading, 5) // Consistent padding
                            .padding(.bottom, 3)
                        }
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 10) // Add padding at the bottom of the scroll content
                }
                Spacer() // Pushes content to the top
            }
        }
        .frame(width: 240) // Fixed width for the sidebar
        .transition(.move(edge: .leading)) // Animation for appearing/disappearing
    }
}

// Add a preview provider for isolated testing (Optional but recommended)
struct ConversationListView_Previews: PreviewProvider {
    @State static var previewSelectedId: UUID? = nil
    static let sampleConversations: [Conversation] = [
        Conversation(id: UUID(), messages: ["You: Today's chat"], timestamp: Date()),
        Conversation(id: UUID(), messages: ["You: Another Today"], timestamp: Date().addingTimeInterval(-60)),
        Conversation(id: UUID(), messages: ["You: Yesterday's chat"], timestamp: Date().addingTimeInterval(-86400)),
        Conversation(id: UUID(), messages: ["You: Older chat"], timestamp: Date().addingTimeInterval(-86400 * 3))
    ]

    // Helper to create grouped data for preview
    static func previewGroupedData() -> (groups: [String: [Conversation]], keys: [String]) {
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d, yyyy"

        let grouped = sampleConversations.reduce(into: [String: [Conversation]]()) { result, conversation in
            let timestamp = conversation.timestamp
            let groupKey: String
            if calendar.isDateInToday(timestamp) { groupKey = "Today" }
            else if calendar.isDateInYesterday(timestamp) { groupKey = "Yesterday" }
            else { groupKey = dateFormatter.string(from: timestamp) }
            result[groupKey, default: []].append(conversation)
        }
        let sortedGroups = grouped.mapValues { $0.sorted { $0.timestamp > $1.timestamp } }

        let sortedKeys = sortedGroups.keys.sorted { key1, key2 in
            if key1 == "Today" { return true }
            if key2 == "Today" { return false }
            if key1 == "Yesterday" { return true }
            if key2 == "Yesterday" { return false }
            if let date1 = dateFormatter.date(from: key1), let date2 = dateFormatter.date(from: key2) {
                return date1 > date2
            }
            return key1 > key2
        }
        return (sortedGroups, sortedKeys)
    }

    static var previews: some View {
        let previewData = previewGroupedData()
        ConversationListView(
            groupedConversations: previewData.groups,
            sortedGroupKeys: previewData.keys,
            selectedConversationID: $previewSelectedId,
            onNewConversation: { print("Preview: New Conversation Tapped") }
        )
        .frame(height: 500)
        .onAppear {
            // Optionally select one for preview
             previewSelectedId = previewData.groups["Today"]?.first?.id
        }
    }
}

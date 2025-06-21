// Models/Conversation.swift
import Foundation

struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var messages: [ChatMessage]
    var timestamp: Date // Represents last activity

    /// Optional user-defined title for the conversation. (Part B)
    var userDefinedTitle: String?

    /// Computed property to display a title for the conversation list.
    /// Uses userDefinedTitle if available, otherwise falls back to first message content. (Updated for Part B)
    var displayTitle: String {
        // Use the custom title if it exists and isn't just whitespace
        if let userTitle = userDefinedTitle, !userTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return userTitle
        }

        // Fallback: Generate title from first message content
        guard let firstMessage = messages.first(where: {
            switch $0.content {
            case .plainText(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .markdownText(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image(_, let alt): return alt != nil && !alt!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty // Consider alt text
            // Add other cases if they contribute to a title
            default: return false
            }
        }) else {
            return "New Chat" // Default for empty or non-text-based chats
        }

        // Extract text from the first relevant message
        let titleText: String
        switch firstMessage.content {
        case .plainText(let text), .markdownText(let text):
            titleText = text
        case .image(_, let alt):
            titleText = alt ?? "Image" // Use alt text or generic "Image"
        default:
            return "New Chat" // Should not happen due to guard above
        }

        // Generate a preview (e.g., first 30 characters)
        let previewLength = 30
        let trimmedText = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(trimmedText.prefix(previewLength))
        return trimmedText.count > previewLength ? prefix + "..." : prefix
    }

    // Equatable conformance
    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id
    }

    // Initializer
    init(id: UUID = UUID(), messages: [ChatMessage] = [], timestamp: Date = Date(), userDefinedTitle: String? = nil) {
        self.id = id
        self.messages = messages
        self.timestamp = timestamp
        self.userDefinedTitle = userDefinedTitle
    }
}

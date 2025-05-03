// Models/Conversation.swift
import Foundation

struct Conversation: Identifiable, Equatable {
    let id: UUID
    var messages: [ChatMessage] // <--- CHANGED
    var timestamp: Date

    // Helper to get a display title (Adapt based on ChatMessage)
    var displayTitle: String {
        // Find the first user message
        if let firstUserMessage = messages.first(where: { $0.sender == .user }) {
            if case .plainText(let text) = firstUserMessage.content { // <-- Check content type
                let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let maxLength = 30
                return String(content.prefix(maxLength)) + (content.count > maxLength ? "..." : "")
            }
        }
        // Fallback: Use first message of any kind
        if let firstMessage = messages.first {
             if case .plainText(let text) = firstMessage.content { // <-- Check content type
                let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let maxLength = 30
                // Optionally prepend "Agent: " if needed, but maybe less necessary now
                return String(content.prefix(maxLength)) + (content.count > maxLength ? "..." : "")
            }
        }
        return "New Chat" // Default title
    }

     // Implement Equatable based on ID
    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id
    }
}

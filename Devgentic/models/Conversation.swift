// Models/Conversation.swift
import Foundation

// Add Codable conformance (should be synthesized automatically)
struct Conversation: Identifiable, Equatable, Codable {
    let id: UUID
    var messages: [ChatMessage] // Now holds Codable ChatMessage
    var timestamp: Date // Codable

    // displayTitle (keep as is)
    var displayTitle: String {
        // ... (existing logic) ...
        if let firstUserMessage = messages.first(where: { $0.sender == .user }) {
            // Check content type before accessing text
            switch firstUserMessage.content {
            case .plainText(let text), .markdownText(let text): // Handle both text types
                let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let maxLength = 30
                return String(content.prefix(maxLength)) + (content.count > maxLength ? "..." : "")
            default: break // Ignore non-text messages for title
            }
        }
        // Fallback logic can also check content type
        if let firstMessage = messages.first {
             switch firstMessage.content {
             case .plainText(let text), .markdownText(let text):
                 let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
                 let maxLength = 30
                 return String(content.prefix(maxLength)) + (content.count > maxLength ? "..." : "")
             default: break
             }
        }
        return "New Chat"
    }

     // Equatable (keep as is)
    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id
    }
}

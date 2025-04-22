// Models/Conversation.swift
import Foundation // Needed for UUID and Date

// MARK: - Data Model
struct Conversation: Identifiable, Equatable {
    let id: UUID
    var messages: [String]
    var timestamp: Date // To help sort or display

    // Helper to get a display title (e.g., first user message)
    var displayTitle: String {
        // Find the first message starting with "You: "
        if let firstUserMessage = messages.first(where: { $0.starts(with: "You:") }) {
            let content = firstUserMessage.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            // Limit title length for display
            let maxLength = 30
            return String(content.prefix(maxLength)) + (content.count > maxLength ? "..." : "")
        }
        // Fallback if no user message yet or only agent messages
        if let firstMessage = messages.first {
            let content = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            // Limit title length for display
            let maxLength = 30
            // Include "Agent:" prefix if it's the first message
            if content.starts(with: "Agent:") {
                 return String(content.prefix(maxLength + 7)) + (content.count > (maxLength + 7) ? "..." : "") // Account for "Agent: "
            } else {
                 return String(content.prefix(maxLength)) + (content.count > maxLength ? "..." : "")
            }
        }
        return "New Chat"
    }
}

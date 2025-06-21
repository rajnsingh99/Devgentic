// Models/ChatMessage.swift
import Foundation

// Add Codable conformance (should be synthesized automatically)
struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let conversationId: UUID
    let timestamp: Date
    let sender: SenderRole
    let content: MessageContent

    // Initializer (keep as is)
    init(id: UUID = UUID(), conversationId: UUID, timestamp: Date = Date(), sender: SenderRole, content: MessageContent) {
        self.id = id
        self.conversationId = conversationId
        self.timestamp = timestamp
        self.sender = sender
        self.content = content
    }

    // Equatable (keep as is)
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}

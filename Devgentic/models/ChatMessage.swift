// Models/ChatMessage.swift
import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let conversationId: UUID // Keep track of which conversation it belongs to
    let timestamp: Date
    let sender: SenderRole
    let content: MessageContent

    // Initializer
    init(id: UUID = UUID(), // Default values for convenience
         conversationId: UUID,
         timestamp: Date = Date(),
         sender: SenderRole,
         content: MessageContent) {
        self.id = id
        self.conversationId = conversationId
        self.timestamp = timestamp
        self.sender = sender
        self.content = content
    }

    // Implement Equatable (based on ID is usually sufficient)
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}
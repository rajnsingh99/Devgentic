// Models/ChatMessage.swift
import Foundation

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let conversationId: UUID
    let timestamp: Date
    let sender: SenderRole
    var content: MessageContent // Changed to var
    
    var attachedTextFiles: [AttachedTextFile]?
    var attachedImageFiles: [AttachedImageFile]?
    
    var isStreaming: Bool = false

    init(id: UUID = UUID(), conversationId: UUID, timestamp: Date = Date(), sender: SenderRole, content: MessageContent, attachedTextFiles: [AttachedTextFile]? = nil, attachedImageFiles: [AttachedImageFile]? = nil, isStreaming: Bool = false) {
        self.id = id
        self.conversationId = conversationId
        self.timestamp = timestamp
        self.sender = sender
        self.content = content
        self.attachedTextFiles = attachedTextFiles
        self.attachedImageFiles = attachedImageFiles
        self.isStreaming = isStreaming
    }

    // --- FIX: Updated Equatable conformance ---
    // This now checks the content and streaming status, not just the ID.
    // This is crucial for SwiftUI to detect changes and re-render the view.
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id &&
        lhs.content == rhs.content && // Check if content has changed
        lhs.isStreaming == rhs.isStreaming // Check if streaming status has changed
    }
}

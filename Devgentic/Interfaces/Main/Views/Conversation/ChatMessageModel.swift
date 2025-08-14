// Models/ChatMessage.swift
import Foundation

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let conversationId: UUID
    let timestamp: Date
    let sender: SenderRole
    var content: MessageContent
    
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

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id &&
        lhs.content == rhs.content &&
        lhs.isStreaming == rhs.isStreaming
    }
}

struct AttachedTextFile: Codable, Equatable, Identifiable {
    var id = UUID()
    let name: String
    let url: URL
    let fileExtension: String
    let content: String
    let size: Int64 // Size in bytes

    static func == (lhs: AttachedTextFile, rhs: AttachedTextFile) -> Bool {
        return lhs.id == rhs.id && lhs.url == rhs.url
    }
}

/// A struct representing an image file attached to a chat message.
struct AttachedImageFile: Codable, Equatable, Identifiable {
    var id = UUID()
    let name: String
    let url: URL
    let fileExtension: String
    let binaryData: Data
    let size: Int64

    static func == (lhs: AttachedImageFile, rhs: AttachedImageFile) -> Bool {
        return lhs.id == rhs.id && lhs.url == rhs.url
    }
}

//
//  ConversationModel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftUI

extension Date {
    func timeAgoDisplay() -> String {
        // RelativeDateTimeFormatter is a powerful, locale-aware formatter
        // provided by Apple to handle exactly this kind of task.
        let formatter = RelativeDateTimeFormatter()
        
        // .full style results in strings like "1 day ago" instead of "1d ago".
        formatter.unitsStyle = .full
        
        // This calculates the difference between the date instance and the
        // current time, and returns the appropriate localized string.
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
    
struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var messages: [ChatMessage]
    var timestamp: Date
    var userDefinedTitle: String?
    var isPinned: Bool // New property for pinning
    
    var openAIThreadID: String?
    var backendType: BackendType?
    var backendEntityId: UUID?

    // MARK: - Display Properties

    var displayTitle: String {
        if let userTitle = userDefinedTitle, !userTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return userTitle
        }
        guard let firstMessage = messages.first(where: {
            switch $0.content {
            case .plainText(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .markdownText(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image(_, let alt): return alt != nil && !alt!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: return false
            }
        }) else {
            return "New Chat"
        }
        let titleText: String
        switch firstMessage.content {
        case .plainText(let text), .markdownText(let text):
            titleText = text
        case .image(_, let alt):
            titleText = alt ?? "Image"
        default:
            return "New Chat"
        }
        let previewLength = 30
        let trimmedText = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(trimmedText.prefix(previewLength))
        return trimmedText.count > previewLength ? prefix + "..." : prefix
    }
    
    // MARK: - Enhanced Row Properties

    var lastMessageSnippet: String {
        guard let lastMessage = messages.last else { return "No messages yet" }
        switch lastMessage.content {
        case .plainText(let text), .markdownText(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .codeBlock:
            return "Code block"
        case .image:
            return "Image attachment"
        case .error(_, let details):
            return "Error: \(details)"
        }
    }

    var relativeTimestamp: String {
        return timestamp.timeAgoDisplay()
    }
    
    var hasError: Bool {
        if case .error = messages.last?.content {
            return true
        }
        return false
    }
    
    var isStreaming: Bool {
        return messages.last?.isStreaming ?? false
    }
    
    var statusIcon: String {
        if isStreaming {
            return "ellipsis.bubble.fill"
        } else if hasError {
            return "exclamationmark.triangle.fill"
        }
        return "message.fill"
    }
    
    var statusColor: Color {
        if isStreaming {
            return .blue
        } else if hasError {
            return .red
        }
        return .secondary
    }

    // MARK: - Standard Conformance & Initializer

    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id && lhs.messages == rhs.messages && lhs.isPinned == rhs.isPinned
    }

    init(id: UUID = UUID(), messages: [ChatMessage] = [], timestamp: Date = Date(), userDefinedTitle: String? = nil, isPinned: Bool = false, openAIThreadID: String? = nil, backendType: BackendType? = .none, backendEntityId: UUID? = nil) {
        self.id = id
        self.messages = messages
        self.timestamp = timestamp
        self.userDefinedTitle = userDefinedTitle
        self.isPinned = isPinned // Initialize new property
        self.openAIThreadID = openAIThreadID
        self.backendType = backendType
        self.backendEntityId = backendEntityId
    }
}

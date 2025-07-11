//
//  ConversationModel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var messages: [ChatMessage]
    var timestamp: Date
    var userDefinedTitle: String?
    
    /// The thread ID from the OpenAI Assistants API, used for stateful conversations.
    var openAIThreadID: String?

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

    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id
    }

    init(id: UUID = UUID(), messages: [ChatMessage] = [], timestamp: Date = Date(), userDefinedTitle: String? = nil, openAIThreadID: String? = nil) {
        self.id = id
        self.messages = messages
        self.timestamp = timestamp
        self.userDefinedTitle = userDefinedTitle
        self.openAIThreadID = openAIThreadID
    }
}

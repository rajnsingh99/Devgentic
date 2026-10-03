// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationModel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftUI

// MARK: - String Extension for Markdown Stripping
extension String {
    /// Removes common markdown formatting from a string to create a clean preview.
    func strippingMarkdownFormatting() -> String {
        var result = self

        // Remove headers (e.g., #, ##) from the start of the string
        result = result.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)

        // Remove bold/italic markers like **word**, *word*, _word_
        // This regex finds text between pairs of *, **, or _ and replaces it with just the text.
        result = result.replacingOccurrences(of: "(\\*\\*|\\*|_)(.+?)\\1", with: "$2", options: .regularExpression)

        // Remove inline code backticks (`code`)
        result = result.replacingOccurrences(of: "`(.+?)`", with: "$1", options: .regularExpression)
        
        // Remove strikethrough (~~text~~)
        result = result.replacingOccurrences(of: "~~(.+?)~~", with: "$1", options: .regularExpression)

        // Remove images and links, keeping only the descriptive text: ![alt](url) or [text](url) -> alt/text
        result = result.replacingOccurrences(of: "!?\\[(.*?)\\]\\(.*?\\)", with: "$1", options: .regularExpression)

        // Clean up extra whitespace that might result from removals and trim the result
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        
        return result
    }
}


extension Date {
    /// Generates a compact, shorthand string representing the time elapsed since the date.
    /// e.g., "1y", "2mo", "3w", "4d", "5h", "6m", "7s"
    func timeAgoDisplay() -> String {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.year, .month, .weekOfYear, .day, .hour, .minute, .second], from: self, to: now)

        if let year = components.year, year > 0 {
            return "\(year)y"
        }
        if let month = components.month, month > 0 {
            return "\(month)mo"
        }
        if let week = components.weekOfYear, week > 0 {
            return "\(week)w"
        }
        if let day = components.day, day > 0 {
            return "\(day)d"
        }
        if let hour = components.hour, hour > 0 {
            return "\(hour)h"
        }
        if let minute = components.minute, minute > 0 {
            return "\(minute)m"
        }
        if let second = components.second, second > 0 {
            return "\(second)s"
        }
        return "now"
    }
}
    
struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var messages: [ChatMessage]
    var timestamp: Date
    var userDefinedTitle: String?
    var isPinned: Bool // New property for pinning
    
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
            default: return false
            }
        }) else {
            return "New Chat"
        }
        let titleText: String
        switch firstMessage.content {
        case .plainText(let text), .markdownText(let text):
            titleText = text
        default:
            return "New Chat"
        }
        let previewLength = 30
        // Use the cleaned-up text for the title as well
        let trimmedText = titleText.strippingMarkdownFormatting()
        let prefix = String(trimmedText.prefix(previewLength))
        return trimmedText.count > previewLength ? prefix + "..." : prefix
    }
    
    // MARK: - Enhanced Row Properties

    var lastMessageSnippet: String {
        guard let lastMessage = messages.last else { return "No messages yet" }
        switch lastMessage.content {
        case .plainText(let text), .markdownText(let text):
            // Apply the new markdown stripping method here
            return text.strippingMarkdownFormatting()
        case .codeBlock:
            return "Code block"
        case .error(_, let details, _, _):
            return "Error: \(details)"
        case .mediaArtifact(let artifact):
            return artifact.label ?? artifact.kind.rawValue
        case .checkpoint:
            return "History checkpoint"
        case .unknown:
            // Honest, and reassuring: the content is preserved, this build just cannot draw it.
            return "Content from a newer version"
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

    init(id: UUID = UUID(), messages: [ChatMessage] = [], timestamp: Date = Date(), userDefinedTitle: String? = nil, isPinned: Bool = false, backendEntityId: UUID? = nil) {
        self.id = id
        self.messages = messages
        self.timestamp = timestamp
        self.userDefinedTitle = userDefinedTitle
        self.isPinned = isPinned // Initialize new property
        self.backendEntityId = backendEntityId
    }
}

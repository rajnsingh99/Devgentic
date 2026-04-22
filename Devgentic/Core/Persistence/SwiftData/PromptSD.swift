//
//  PromptSD.swift
//  Devgentic
//
//  Created on 26/03/26.
//
//  SwiftData @Model class for prompt persistence.
//  Replaces PromptEntity. Tags stored natively as [String] — no ValueTransformer needed.
//

import Foundation
import SwiftData

@Model
final class PromptModel {

    @Attribute(.unique)
    var id: UUID

    var title: String
    var text: String
    var category: String
    var createdAt: Date
    var lastUsedAt: Date?
    var isUserDefined: Bool

    /// SwiftData natively persists Codable arrays — replaces StringArrayTransformer.
    var tags: [String]?

    /// Whether the user has pinned this prompt. Default `false` so SwiftData's
    /// lightweight migration can backfill existing rows without a schema version bump.
    var isPinned: Bool = false

    init(
        id: UUID = UUID(),
        title: String,
        text: String,
        category: String,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        isUserDefined: Bool,
        tags: [String]? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.category = category
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.isUserDefined = isUserDefined
        self.tags = tags
        self.isPinned = isPinned
    }
}

// MARK: - Conversion Helpers

extension PromptModel {
    /// Converts to the UI-layer `DevPrompt` value type.
    func toDevPrompt() -> DevPrompt {
        DevPrompt(
            id: id,
            title: title,
            text: text,
            category: category,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            isUserDefined: isUserDefined,
            tags: tags,
            isPinned: isPinned
        )
    }

    /// Updates this model's properties from a `DevPrompt`.
    func apply(from prompt: DevPrompt) {
        title = prompt.title
        text = prompt.text
        category = prompt.category
        createdAt = prompt.createdAt
        lastUsedAt = prompt.lastUsedAt
        isUserDefined = prompt.isUserDefined
        tags = prompt.tags
        isPinned = prompt.isPinned
    }
}

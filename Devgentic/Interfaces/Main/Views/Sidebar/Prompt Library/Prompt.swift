// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  Prompt.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import AppKit

/// Represents a reusable prompt in the Prompt Library.
struct DevPrompt: Identifiable, Codable, Hashable {
    /// Unique identifier for the prompt.
    var id: UUID = UUID()
    /// Title of the prompt (e.g., "Summarize Text", "Code Explainer").
    var title: String
    /// The actual text content of the prompt.
    var text: String
    /// Category of the prompt. Stored as raw String for forward-compatibility
    /// with user-imported prompts containing unknown categories; prefer
    /// `categoryEnum` in new code.
    var category: String
    /// Timestamp of when the prompt was created.
    var createdAt: Date = Date()
    /// Timestamp of when the prompt was last used. Optional, for sorting by recency.
    var lastUsedAt: Date?
    /// Flag to distinguish between pre-defined system prompts and user-created prompts.
    var isUserDefined: Bool
    /// Optional tags for more granular filtering and searching.
    var tags: [String]?
    /// Whether the user has pinned this prompt to the top of the sidebar.
    var isPinned: Bool = false

    /// Type-safe category accessor. Unknown raw strings degrade to `.custom`.
    var categoryEnum: PromptCategory {
        get { PromptCategory(tolerant: category) }
        set { category = newValue.rawValue }
    }

    init(id: UUID = UUID(),
         title: String,
         text: String,
         category: String,
         createdAt: Date = Date(),
         lastUsedAt: Date? = nil,
         isUserDefined: Bool,
         tags: [String]? = nil,
         isPinned: Bool = false) {
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

    /// Custom decoder tolerant of missing `isPinned` and `lastUsedAt`/`tags`
    /// — ensures older serialized payloads decode cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decodeIfPresent(UUID.self,    forKey: .id) ?? UUID()
        title         = try c.decode(String.self,           forKey: .title)
        text          = try c.decode(String.self,           forKey: .text)
        category      = try c.decode(String.self,           forKey: .category)
        createdAt     = try c.decodeIfPresent(Date.self,    forKey: .createdAt) ?? Date()
        lastUsedAt    = try c.decodeIfPresent(Date.self,    forKey: .lastUsedAt)
        isUserDefined = try c.decodeIfPresent(Bool.self,    forKey: .isUserDefined) ?? true
        tags          = try c.decodeIfPresent([String].self,forKey: .tags)
        isPinned      = try c.decodeIfPresent(Bool.self,    forKey: .isPinned) ?? false
    }
}

// Example Usage (for testing or default prompts):
extension DevPrompt {
    static let examplePrompts: [DevPrompt] = [
        DevPrompt(title: "Summarize Text",
               text: "Please summarize the following text in three key bullet points:\n\n[Paste text here]",
               category: PromptCategory.productivity.rawValue,
               isUserDefined: false,
               tags: ["summarization", "text analysis"]),
        DevPrompt(title: "Explain Code Snippet",
               text: "Explain the following code snippet, its purpose, and how it works:\n\n```\n[Paste code here]\n```",
               category: PromptCategory.development.rawValue,
               isUserDefined: false,
               tags: ["coding", "explanation", "debug"]),
        DevPrompt(title: "Brainstorm Ideas",
               text: "Help me brainstorm ideas for [topic/project]. I'm looking for innovative and practical suggestions.",
               category: PromptCategory.creativity.rawValue,
               isUserDefined: false,
               tags: ["ideation", "brainstorming"]),
        DevPrompt(title: "Write a short story",
               text: "Write a short story about a detective who solves a case using only a single, obscure detail.",
               category: PromptCategory.writing.rawValue,
               isUserDefined: false,
               tags: ["fiction", "storytelling", "creative"]),
        DevPrompt(title: "Explain REST APIs",
               text: "Explain the concept of RESTful APIs, including key principles like statelessness and standard HTTP methods, in a way that is easy for a beginner to understand.",
               category: PromptCategory.development.rawValue,
               isUserDefined: false,
               tags: ["development", "api", "web"]),
        DevPrompt(title: "Generate a marketing slogan",
               text: "Generate five catchy and effective marketing slogans for a new brand of sustainable coffee. The brand emphasizes fair trade and eco-friendly practices.",
               category: PromptCategory.marketing.rawValue,
               isUserDefined: false,
               tags: ["marketing", "slogan", "branding"]),
        DevPrompt(title: "Draft a professional email",
               text: "Draft a professional email to a client requesting a meeting to discuss the next steps on a project. Be concise and provide a clear call to action.",
               category: PromptCategory.productivity.rawValue,
               isUserDefined: false,
               tags: ["email", "professional", "writing"])
    ]
}

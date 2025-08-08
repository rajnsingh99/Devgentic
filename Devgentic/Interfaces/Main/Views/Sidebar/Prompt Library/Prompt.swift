//
//  Prompt.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import AppKit

/// Represents a reusable prompt in the Prompt Library.
struct Prompt: Identifiable, Codable, Hashable {
    /// Unique identifier for the prompt.
    var id: UUID = UUID()
    /// Title of the prompt (e.g., "Summarize Text", "Code Explainer").
    var title: String
    /// The actual text content of the prompt.
    var text: String
    /// Category of the prompt (e.g., "General", "Coding", "Creative Writing").
    /// This can be used for filtering and organization.
    var category: String
    /// Timestamp of when the prompt was created.
    var createdAt: Date = Date()
    /// Timestamp of when the prompt was last used. Optional, for sorting by recency.
    var lastUsedAt: Date?
    /// Flag to distinguish between pre-defined system prompts and user-created prompts.
    var isUserDefined: Bool
    /// Optional tags for more granular filtering and searching.
    var tags: [String]?

    /// Initializes a new prompt.
    init(id: UUID = UUID(),
         title: String,
         text: String,
         category: String,
         createdAt: Date = Date(),
         lastUsedAt: Date? = nil,
         isUserDefined: Bool,
         tags: [String]? = nil) {
        self.id = id
        self.title = title
        self.text = text
        self.category = category
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.isUserDefined = isUserDefined
        self.tags = tags
    }
}

// Example Usage (for testing or default prompts):
extension Prompt {
    static let examplePrompts: [Prompt] = [
        Prompt(title: "Summarize Text",
               text: "Please summarize the following text in three key bullet points:\n\n[Paste text here]",
               category: "Productivity",
               isUserDefined: false,
               tags: ["summarization", "text analysis"]),
        Prompt(title: "Explain Code Snippet",
               text: "Explain the following code snippet, its purpose, and how it works:\n\n```\n[Paste code here]\n```",
               category: "Development",
               isUserDefined: false,
               tags: ["coding", "explanation", "debug"]),
        Prompt(title: "Brainstorm Ideas",
               text: "Help me brainstorm ideas for [topic/project]. I'm looking for innovative and practical suggestions.",
               category: "Creativity",
               isUserDefined: false,
               tags: ["ideation", "brainstorming"]),
        Prompt(title: "Write a short story",
               text: "Write a short story about a detective who solves a case using only a single, obscure detail.",
               category: "Writing",
               isUserDefined: false,
               tags: ["fiction", "storytelling", "creative"]),
        Prompt(title: "Explain REST APIs",
               text: "Explain the concept of RESTful APIs, including key principles like statelessness and standard HTTP methods, in a way that is easy for a beginner to understand.",
               category: "Development",
               isUserDefined: false,
               tags: ["development", "api", "web"]),
        Prompt(title: "Generate a marketing slogan",
               text: "Generate five catchy and effective marketing slogans for a new brand of sustainable coffee. The brand emphasizes fair trade and eco-friendly practices.",
               category: "Marketing",
               isUserDefined: false,
               tags: ["marketing", "slogan", "branding"]),
        Prompt(title: "Draft a professional email",
               text: "Draft a professional email to a client requesting a meeting to discuss the next steps on a project. Be concise and provide a clear call to action.",
               category: "Productivity",
               isUserDefined: false,
               tags: ["email", "professional", "writing"])
    ]
}

//
//  LLMResponse.swift
//  Devgentic
//
//  Created by Raj Singh on 15/05/25.
//

import Foundation

/// Represents a standardized response from an LLM communication.
struct LLMResponse {
    /// The primary content of the LLM's response, parsed into `MessageContent` blocks.
    let content: [MessageContent] // Assuming MessageContent is your existing model for chat message pieces

    /// The raw response string from the LLM, useful for debugging or alternative parsing if needed.
    let rawResponseText: String?

    /// Optional: Any error that occurred during the LLM communication or response parsing,
    /// which couldn't be represented solely by `content` (e.g., network errors passed through).
    let error: Error?

    init(content: [MessageContent], rawResponseText: String? = nil, error: Error? = nil) {
        self.content = content
        self.rawResponseText = rawResponseText
        self.error = error
    }
}

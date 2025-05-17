//
//  OllamaModelInfo.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import Foundation

/// Represents information about a recommended Ollama model for the onboarding selection.
struct OllamaModelInfo: Identifiable, Hashable {
    let id = UUID() // Make identifiable for SwiftUI Lists
    let name: String // The actual model name used in `ollama pull`
    let displayName: String // User-friendly name
    let sizeDescription: String // e.g., "8B Parameters", "7B Instruct"
}

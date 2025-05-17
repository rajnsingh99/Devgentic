//
//  FileHandlingSettings.swift
//  Devgentic
//
//  Created by Raj Singh on 18/05/25.
//

import Foundation

// MARK: - Text File Inclusion Strategy

/// Defines how text and source code files are presented to Ollama.
enum TextFileInclusionStrategy: String, CaseIterable, Identifiable {
    /// Includes content directly in the prompt if within character limits. (Default)
    case preferInlining = "preferInlining"
    /// Always uses file paths, requiring the LLM to access the file system (if capable and configured).
    case alwaysUsePaths = "alwaysUsePaths"

    var id: String { self.rawValue }

    /// A user-friendly display name for the setting option.
    var displayName: String {
        switch self {
        case .preferInlining:
            return "Prefer Inlining Small Text/Source Files"
        case .alwaysUsePaths:
            return "Always Use File Paths for Text/Source Files"
        }
    }
}

// MARK: - Image Handling Strategy for Ollama Text Models

/// Defines how image attachments are handled when the selected Ollama model is likely text-only.
enum OllamaImageHandlingStrategy: String, CaseIterable, Identifiable {
    /// Includes the image path with a warning. (Default)
    case includePathWithWarning = "includePathWithWarning"
    /// Does not include images in the prompt.
    case doNotInclude = "doNotInclude"

    var id: String { self.rawValue }

    /// A user-friendly display name for the setting option.
    var displayName: String {
        switch self {
        case .includePathWithWarning:
            return "Include Image Path with Warning"
        case .doNotInclude:
            return "Do Not Include Images"
        }
    }
}

// MARK: - Binary File Handling Strategy for Ollama Text Models

/// Defines how non-text, non-image binary files (like PDFs, DOCX) are handled with text-based Ollama models.
enum OllamaBinaryFileHandlingStrategy: String, CaseIterable, Identifiable {
    /// Includes the file path with a warning. (Default)
    case includePathWithWarning = "includePathWithWarning"
    /// Does not include these file types in the prompt.
    case doNotInclude = "doNotInclude"

    var id: String { self.rawValue }

    /// A user-friendly display name for the setting option.
    var displayName: String {
        switch self {
        case .includePathWithWarning:
            return "Include File Path with Warning"
        case .doNotInclude:
            return "Do Not Include These File Types"
        }
    }
}

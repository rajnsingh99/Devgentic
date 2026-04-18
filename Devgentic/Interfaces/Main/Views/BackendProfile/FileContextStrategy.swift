//
//  FileContextStrategy.swift
//  Devgentic
//
//  Created on 29/03/26.
//
//  Controls how attached files and knowledge sources are processed
//  and made available to the model. Each profile has a strategy
//  (explicit or smart-defaulted by profile type).
//

import Foundation

// MARK: - File Context Strategy

enum FileContextStrategy: String, Codable, CaseIterable, Sendable, Hashable {

    /// Files are chunked, embedded, and stored in the vector database.
    /// On each query, relevant chunks are retrieved via semantic search.
    /// Best for: long conversations with many documents, research-style workflows.
    case contextualRAG = "contextual_rag"

    /// File content is extracted and injected directly into the prompt context window.
    /// No embedding or vector storage. Full text included with each relevant query.
    /// Best for: short task-focused sessions with few files.
    case directInjection = "direct_injection"

    /// No upfront file processing. The agent reads files on demand via tools (read_file).
    /// Nothing is persisted or pre-loaded. Truly stateless.
    /// Best for: code-heavy work, large repos, tool-driven exploration.
    case stateless = "stateless"

    // MARK: - Display Properties

    var displayName: String {
        switch self {
        case .contextualRAG:   return "Contextual RAG"
        case .directInjection: return "Direct Injection"
        case .stateless:       return "Stateless"
        }
    }

    var description: String {
        switch self {
        case .contextualRAG:
            return "Files are indexed for semantic search across the conversation. Best for long conversations with many documents."
        case .directInjection:
            return "File content is inserted directly into the prompt. Best for short tasks with few files."
        case .stateless:
            return "Files are not pre-processed. The agent reads files on demand via tools. Best for code-heavy work."
        }
    }

    var iconName: String {
        switch self {
        case .contextualRAG:   return "magnifyingglass.circle.fill"
        case .directInjection: return "doc.text.fill"
        case .stateless:       return "terminal.fill"
        }
    }

    // MARK: - Smart Defaults

    static func defaultStrategy(for profileType: ProfileType) -> FileContextStrategy {
        switch profileType {
        case .bot:      return .contextualRAG
        case .agent:    return .directInjection
        case .workflow:  return .directInjection
        case .imageGen: return .stateless
        case .code:     return .stateless
        }
    }
}

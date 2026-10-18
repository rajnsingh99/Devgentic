// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FileContextStrategy.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - File Context Strategy

/// How attached files and knowledge sources are delivered to the model: injected into the prompt or by file paths.
/// `resolve(_:for:)` is the single resolution seam and heals persisted values a profile type cannot honor.
enum FileContextStrategy: String, Codable, CaseIterable, Sendable, Hashable {

    /// Deprecated: not selectable and never returned by `resolve(_:for:)`.
    /// Kept so persisted profiles that stored it still decode; the value heals to the type default at read time.
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
    // `displayName` and `description` live as `localizedTitle` / `localizedDescription` in
    // `ProfileEnumLocalizedTitles.swift`; this file is Foundation-only so a SwiftUI type cannot live here.




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
        case .bot:      return .directInjection
        // Agents have file tools: paths let them read exactly what they need and learn where the file lives.
        // Injection exposes only a basename (a bare write path resolves to HOME); still selectable for read-and-explain.
        case .agent:    return .stateless
        case .workflow:  return .directInjection
        case .imageGen: return .stateless
        case .code:     return .stateless
        }
    }

    // MARK: - Availability

    /// Strategies a profile type can actually honor.
    /// Bot allows only `.directInjection` (bots run with no tools); Workflow, imageGen and code are pinned to their defaults.
    /// `.contextualRAG` is deprecated and available to no type.
    static func availableStrategies(for profileType: ProfileType) -> [FileContextStrategy] {
        switch profileType {
        case .bot:      return [.directInjection]
        case .agent:    return [.directInjection, .stateless]
        case .workflow: return [.directInjection]
        case .imageGen: return [.stateless]
        case .code:     return [.stateless]
        }
    }

    /// Resolves an optional user override against what the profile type supports:
    /// nil — or an override the type can't honor (e.g. a bot persisted as
    /// `.stateless` before availability was enforced) — falls back to the smart default.
    static func resolve(_ override: FileContextStrategy?, for profileType: ProfileType) -> FileContextStrategy {
        guard let override, availableStrategies(for: profileType).contains(override) else {
            return defaultStrategy(for: profileType)
        }
        return override
    }
}

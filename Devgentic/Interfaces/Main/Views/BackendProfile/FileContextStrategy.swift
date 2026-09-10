// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  FileContextStrategy.swift
//  Devgentic
//
//  Created on 29/03/26.
//
//  Controls how attached files and knowledge sources are DELIVERED to the
//  model: inject the content into the prompt, or hand the agent file paths
//  for tool-based access. Each profile has a strategy (explicit or
//  smart-defaulted by profile type); `resolve(_:for:)` is the single
//  resolution seam and heals persisted values a type can't honor.
//

import Foundation

// MARK: - File Context Strategy

enum FileContextStrategy: String, Codable, CaseIterable, Sendable, Hashable {

    /// DEPRECATED (2026-07 redesign): not selectable and never returned by `resolve(_:for:)` —
    /// kept only so previously-persisted profiles keep decoding; persisted values heal to the
    /// type default at read time. RAG is becoming a standard conversation-memory feature
    /// (not a file strategy), and knowledge sources move to a dedicated `<knowledge_base>`
    /// system-prompt layer.
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
    //
    // ⚠️ register A63 — `displayName` and `description` are now `localizedTitle` /
    // `localizedDescription` (`LocalizedStringKey`) in `ProfileEnumLocalizedTitles.swift`. This
    // file is Foundation-only by design, so a SwiftUI type cannot live here.




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
        // Agents have file tools, so handing them PATHS beats handing them prose: the
        // agent reads exactly what it needs, and — the reason this changed (2026-07-25) —
        // it learns where the file actually lives. Under injection it saw only a basename
        // and, asked to edit an attachment, emitted that bare name as the write path,
        // which resolves to HOME. Injection remains selectable for read-and-explain work.
        case .agent:    return .stateless
        case .workflow:  return .directInjection
        case .imageGen: return .stateless
        case .code:     return .stateless
        }
    }

    // MARK: - Availability

    /// Strategies a profile type can actually honor — the strategy governs how FILES are
    /// delivered (inject content vs tool-based access), nothing else.
    /// - `.contextualRAG` is deprecated and available to no type.
    /// - Bot allows only `.directInjection`: bots run with no tools (ChatExecutor passes
    ///   `availableTools: []`), so `.stateless`'s read_file note would point at a tool
    ///   that doesn't exist. One option → BotConfigDetailView shows no picker.
    /// - Workflow / imageGen / code are pinned to their defaults (no picker exists for them).
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

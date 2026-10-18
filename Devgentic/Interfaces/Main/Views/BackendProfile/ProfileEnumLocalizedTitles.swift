// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileEnumLocalizedTitles.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

// MARK: - Error Recovery

// Why: titles are `LocalizedStringKey`, not `String`: a `String` reaches `Text` without catalog extraction.
/// Localizable presentation strings for the profile-configuration enums.
/// Kept out of the enums because their files import only Foundation (they are Codable and reach SwiftData and JSON),
/// while `LocalizedStringKey` is a SwiftUI type.
extension ToolFailurePolicy {
    /// The human-facing label, separate from `rawValue`, which is the persisted identifier; never conflate them.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .abort: return "Abort"
        case .skipAndContinue: return "Skip & Continue"
        case .fallbackPrompt: return "Fallback Prompt"
        }
    }
}

extension ExhaustionPolicy {
    /// Human-facing label; `rawValue` stays the persisted identifier (see `ToolFailurePolicy.localizedTitle`).
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .synthesizeBestEffort: return "Best-effort Response"
        case .failHard: return "Fail Hard"
        }
    }
}

// MARK: - Conversation Memory

extension HistoryStrategy {
    /// Human-facing label; `rawValue` stays the identifier `BackendOrchestrationService` logs.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .recentHistory: return "Recent"
        case .fullHistory: return "Full"
        case .pointer: return "On-Demand"
        case .hybrid: return "Smart"
        }
    }

    var localizedDescription: LocalizedStringKey {
        switch self {
        case .recentHistory:
            return "Remembers your last 10 conversations. Works well for most everyday tasks."
        case .fullHistory:
            return "Remembers everything from the entire conversation. Best when working on long, multi-step projects."
        case .pointer:
            return "Keeps a lightweight overview of all conversations and recalls details only when needed. Uses the least resources."
        case .hybrid:
            return "Full recall of recent conversations with a lightweight overview of older ones. Best overall balance of speed and context."
        }
    }
}

// MARK: - File Context

extension FileContextStrategy {
    /// Human-facing label; `rawValue` stays the identifier persisted in the profile blob.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .contextualRAG: return "Contextual RAG"
        case .directInjection: return "Direct Injection"
        case .stateless: return "Stateless"
        }
    }

    var localizedDescription: LocalizedStringKey {
        switch self {
        case .contextualRAG:
            // Deprecated — never shown (availableStrategies excludes it everywhere).
            return "Files are indexed for semantic search across the conversation."
        case .directInjection:
            return "Attached files and knowledge sources are included in the prompt as text. Best for a few small-to-medium documents."
        case .stateless:
            return "Files are not pre-loaded — the agent reads them on demand with the read_file tool. Best for code-heavy work and large files."
        }
    }
}

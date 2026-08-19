//
//  ProfileEnumLocalizedTitles.swift
//  Devgentic
//
//  Created on 08/08/26.
//
//  Localizable presentation strings for the profile-configuration enums. Register A63.
//
//  ⚠️ WHY THESE ARE NOT ON THE ENUMS. `BackendProfile.swift` and `FileContextStrategy.swift` import
//  `Foundation` only, deliberately — their types are `Codable` and reach SwiftData and JSON, so
//  they must not import SwiftUI. `LocalizedStringKey` is a SwiftUI type, so the presentation layer
//  is where it can live. Two neighbouring files already record this exact reasoning for
//  `ApiProvider` and `ModelCognitiveCapability`.
//
//  ⚠️ WHY A `String` `displayName` WAS A BUG, NOT A STYLE CHOICE. A `String` reaches `Text` two ways
//  and both lose localization: `Text(someString)` binds to the non-localizing `StringProtocol`
//  overload, and `Text(LocalizedStringKey(someString))` builds the key at RUNTIME, invisible to the
//  String Catalog extractor. Verified against `Localizable.xcstrings`: the section headers above
//  these controls ("Error Recovery", "Conversation Memory") ARE extracted keys, while every option
//  label under them — "Abort", "Skip & Continue", "Fallback Prompt", "Best-effort Response",
//  "Fail Hard", "Full", "On-Demand", "Smart", "Direct Injection", "Stateless" — was absent. A
//  translator would have seen a complete-looking sheet and shipped it half-translated.
//
//  ⚠️ THE OLD `String` PROPERTIES ARE DELETED, NOT KEPT ALONGSIDE. Unlike `ApiProvider`, whose
//  `rawValue` is itself display text ("Ollama (Local)") and therefore needed a parallel accessor,
//  every enum here has an identifier-shaped `rawValue` (`abort`, `skipAndContinue`, `recentHistory`)
//  that carries the persistence and telemetry contract independently — `ErrorRecovery.init(from:)`,
//  `TraceConfigSnapshot` and `BackendOrchestrationService` all use `rawValue`, never `displayName`.
//  Keeping both would be the "two identical copies that then drift" pattern this module's register
//  names as its top recurring defect. Nothing persists or compares these strings, so **no migration
//  is required**.
//

import SwiftUI

// MARK: - Error Recovery

extension ToolFailurePolicy {
    /// ⚠️ Separate from `rawValue` on purpose: `rawValue` is the persisted identifier, this is the
    /// human-facing label. They must never be conflated.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .abort: return "Abort"
        case .skipAndContinue: return "Skip & Continue"
        case .fallbackPrompt: return "Fallback Prompt"
        }
    }
}

extension ExhaustionPolicy {
    /// ⚠️ Separate from `rawValue` on purpose — see `ToolFailurePolicy.localizedTitle`.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .synthesizeBestEffort: return "Best-effort Response"
        case .failHard: return "Fail Hard"
        }
    }
}

// MARK: - Conversation Memory

extension HistoryStrategy {
    /// ⚠️ Separate from `rawValue` on purpose — `BackendOrchestrationService` logs `rawValue`.
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
    /// ⚠️ Separate from `rawValue` on purpose — `rawValue` is persisted in the profile blob.
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

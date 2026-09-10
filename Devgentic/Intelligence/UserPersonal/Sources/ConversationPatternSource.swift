// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ConversationPatternSource.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import os

/// Extracts interaction style, communication markers, and domain knowledge
/// signals from conversation text patterns.
///
/// Pure text analysis — no IC inference. Produces fragments for:
/// - `.interactionStyle`: message length preferences, question vs directive ratio
/// - `.communicationMarkers`: vocabulary level, prompt style
/// - `.domainKnowledge`: frequent topics, programming languages, frameworks
final class ConversationPatternSource: UserPersonalSource, @unchecked Sendable {

    let id = "conversation_patterns"
    let displayName = "Conversation Patterns"
    var isEnabled: Bool { true }

    private let logger = DGLogger(category: "ConversationPatternSource")

    func gather(from conversations: [UserPersonalConversationData]) async -> [ProfileFragment] {
        guard !conversations.isEmpty else { return [] }

        var fragments: [ProfileFragment] = []

        // --- Interaction Style ---
        let styleObs = analyzeInteractionStyle(conversations)
        if !styleObs.isEmpty {
            fragments.append(ProfileFragment(
                sourceID: id,
                section: .interactionStyle,
                observations: styleObs,
                conversationCount: conversations.count
            ))
        }

        // --- Communication Markers ---
        let commObs = analyzeCommunicationMarkers(conversations)
        if !commObs.isEmpty {
            fragments.append(ProfileFragment(
                sourceID: id,
                section: .communicationMarkers,
                observations: commObs,
                conversationCount: conversations.count
            ))
        }

        // --- Domain Knowledge ---
        let domainObs = analyzeDomainKnowledge(conversations)
        if !domainObs.isEmpty {
            fragments.append(ProfileFragment(
                sourceID: id,
                section: .domainKnowledge,
                observations: domainObs,
                conversationCount: conversations.count
            ))
        }

        logger.debug("[ConversationPatternSource] Produced \(fragments.count) fragments from \(conversations.count) conversations.")
        return fragments
    }

    // MARK: - Interaction Style Analysis

    private func analyzeInteractionStyle(_ conversations: [UserPersonalConversationData]) -> String {
        let allUserLengths = conversations.flatMap(\.userMessageLengths)
        guard !allUserLengths.isEmpty else { return "" }

        var observations: [String] = []

        // Average message length → preference
        let avgLength = allUserLengths.reduce(0, +) / allUserLengths.count
        if avgLength < 50 {
            observations.append("- Tends to write short, concise prompts (avg ~\(avgLength) chars)")
        } else if avgLength < 150 {
            observations.append("- Writes moderately detailed prompts (avg ~\(avgLength) chars)")
        } else {
            observations.append("- Writes detailed, thorough prompts (avg ~\(avgLength) chars)")
        }

        // Question vs directive ratio
        let allTexts = conversations.flatMap(\.userMessageTexts)
        let questionCount = allTexts.filter { $0.contains("?") }.count
        let directiveCount = allTexts.count - questionCount
        if allTexts.count >= 3 {
            let questionRatio = Double(questionCount) / Double(allTexts.count)
            if questionRatio > 0.6 {
                observations.append("- Frequently asks questions rather than giving directives")
            } else if questionRatio < 0.3 {
                observations.append("- Primarily gives direct instructions rather than asking questions")
            } else {
                observations.append("- Balances between questions and direct instructions")
            }
        }

        // Multi-turn depth
        let avgMessages = conversations.map(\.messageCount).reduce(0, +) / max(conversations.count, 1)
        if avgMessages <= 4 {
            observations.append("- Tends toward quick, focused exchanges (avg ~\(avgMessages) messages per conversation)")
        } else if avgMessages <= 10 {
            observations.append("- Engages in moderate multi-turn conversations (avg ~\(avgMessages) messages)")
        } else {
            observations.append("- Prefers deep, extended conversations (avg ~\(avgMessages) messages)")
        }

        return observations.joined(separator: "\n")
    }

    // MARK: - Communication Markers

    private func analyzeCommunicationMarkers(_ conversations: [UserPersonalConversationData]) -> String {
        let allTexts = conversations.flatMap(\.userMessageTexts)
        guard !allTexts.isEmpty else { return "" }

        var observations: [String] = []

        // Technical vocabulary density
        let technicalTerms = [
            "function", "class", "struct", "protocol", "async", "await",
            "API", "endpoint", "database", "query", "model", "schema",
            "deploy", "build", "compile", "debug", "refactor", "optimize",
            "container", "docker", "kubernetes", "pipeline", "CI/CD",
            "repository", "branch", "commit", "merge", "PR", "pull request"
        ]

        let allText = allTexts.joined(separator: " ").lowercased()
        let totalWords = allText.split(separator: " ").count
        let techHits = technicalTerms.filter { allText.contains($0.lowercased()) }.count

        if totalWords > 0 {
            let techDensity = Double(techHits) / Double(technicalTerms.count)
            if techDensity > 0.4 {
                observations.append("- Uses highly technical vocabulary — likely a developer or engineer")
            } else if techDensity > 0.15 {
                observations.append("- Uses moderate technical vocabulary — technically comfortable")
            } else {
                observations.append("- Uses mostly non-technical, everyday language")
            }
        }

        // Prompt style: terse vs conversational
        let avgWordCount = allTexts.map { $0.split(separator: " ").count }.reduce(0, +) / max(allTexts.count, 1)
        if avgWordCount < 10 {
            observations.append("- Terse prompt style — uses minimal words")
        } else if avgWordCount < 30 {
            observations.append("- Clear and direct prompt style")
        } else {
            observations.append("- Conversational prompt style — provides context and detail")
        }

        // Politeness markers
        let politeTerms = ["please", "thank", "thanks", "could you", "would you", "appreciate"]
        let politeCount = politeTerms.filter { allText.contains($0) }.count
        if politeCount >= 3 {
            observations.append("- Tends to use polite, courteous language in prompts")
        }

        return observations.joined(separator: "\n")
    }

    // MARK: - Domain Knowledge

    private func analyzeDomainKnowledge(_ conversations: [UserPersonalConversationData]) -> String {
        let allTexts = conversations.flatMap(\.userMessageTexts)
        guard !allTexts.isEmpty else { return "" }

        let allText = allTexts.joined(separator: " ")
        var observations: [String] = []

        // Programming languages
        let languageSignals: [(name: String, signals: [String])] = [
            ("Swift", ["swift", "swiftui", "uikit", "xcode", "@State", "@Published", "@Observable", "struct ", "protocol "]),
            ("Python", ["python", "django", "flask", "numpy", "pandas", "pip install", "def ", "import "]),
            ("JavaScript/TypeScript", ["javascript", "typescript", "react", "vue", "angular", "node", "npm", "const ", "let "]),
            ("Go", ["golang", "go ", "goroutine", "chan ", "go func"]),
            ("Rust", ["rust", "cargo", "fn ", "impl ", "trait "]),
            ("Java/Kotlin", ["java", "kotlin", "spring", "gradle", "maven"]),
        ]

        let detectedLanguages = languageSignals.compactMap { lang -> String? in
            let hits = lang.signals.filter { allText.lowercased().contains($0.lowercased()) }.count
            return hits >= 2 ? lang.name : nil
        }

        if !detectedLanguages.isEmpty {
            observations.append("- Works with: \(detectedLanguages.joined(separator: ", "))")
        }

        // Domain areas
        let domainSignals: [(name: String, signals: [String])] = [
            ("macOS/iOS Development", ["macos", "ios", "swiftui", "appkit", "uikit", "xcode", "cocoa"]),
            ("Web Development", ["html", "css", "frontend", "backend", "REST", "GraphQL", "web"]),
            ("Data Science/ML", ["machine learning", "model", "training", "dataset", "neural", "tensor", "ML"]),
            ("DevOps/Infrastructure", ["docker", "kubernetes", "CI/CD", "deploy", "terraform", "aws", "cloud"]),
            ("Database", ["sql", "database", "postgres", "mysql", "mongodb", "redis", "query"]),
        ]

        let detectedDomains = domainSignals.compactMap { domain -> String? in
            let hits = domain.signals.filter { allText.lowercased().contains($0.lowercased()) }.count
            return hits >= 2 ? domain.name : nil
        }

        if !detectedDomains.isEmpty {
            observations.append("- Domain expertise: \(detectedDomains.joined(separator: ", "))")
        }

        return observations.joined(separator: "\n")
    }
}

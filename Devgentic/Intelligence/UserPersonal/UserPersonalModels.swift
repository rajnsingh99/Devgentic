// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  UserPersonalModels.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import UniformTypeIdentifiers
import SwiftUI

// MARK: - Profile Sections

/// The six canonical sections of the User Personal profile.
/// Each section header maps directly to a `## <rawValue>` line in the markdown file.
enum UserProfileSection: String, CaseIterable, Sendable {
    case interactionStyle = "Interaction Style"
    case workflowPatterns = "Workflow Patterns"
    case domainKnowledge = "Domain Knowledge"
    case preferences = "Preferences"
    case toolEffectiveness = "Tool Effectiveness"
    case communicationMarkers = "Communication Markers"

    /// SF Symbol for this section (used in the profile viewer).
    var icon: String {
        switch self {
        case .interactionStyle: return "bubble.left.and.text.bubble.right"
        case .workflowPatterns: return "arrow.triangle.branch"
        case .domainKnowledge: return "book.fill"
        case .preferences: return "slider.horizontal.3"
        case .toolEffectiveness: return "wrench.and.screwdriver.fill"
        case .communicationMarkers: return "text.quote"
        }
    }
}

// MARK: - Profile Fragment (Source → Service contract)

/// A raw observation contributed by a `UserPersonalSource`.
/// Fragments are aggregated and merged into the profile by the IC.
struct ProfileFragment: Identifiable, Sendable {
    let id: UUID
    /// Which source produced this fragment (matches `UserPersonalSource.id`).
    let sourceID: String
    /// The profile section this observation belongs to.
    let section: UserProfileSection
    /// Free-text observations to merge into the section.
    let observations: String
    /// How many conversations contributed to this observation.
    let conversationCount: Int
    /// When this fragment was gathered.
    let gatheredAt: Date

    init(
        id: UUID = UUID(),
        sourceID: String,
        section: UserProfileSection,
        observations: String,
        conversationCount: Int = 1,
        gatheredAt: Date = Date()
    ) {
        self.id = id
        self.sourceID = sourceID
        self.section = section
        self.observations = observations
        self.conversationCount = conversationCount
        self.gatheredAt = gatheredAt
    }
}

// MARK: - Conversation Data (for sources)

/// Enriched conversation data passed to sources.
/// The service queries SwiftData once and distributes this to all sources,
/// avoiding redundant database access.
struct UserPersonalConversationData: Sendable {
    let conversationID: UUID
    let title: String
    let timestamp: Date
    let messageCount: Int
    /// Condensed message content (role + first 200 chars per message).
    let condensedContent: String
    /// Decoded tool execution summaries from timelineEvents.
    let toolExecutions: [ToolExecutionSummary]
    /// Lengths of user messages (character counts) for style analysis.
    let userMessageLengths: [Int]
    /// Lengths of agent messages (character counts) for style analysis.
    let agentMessageLengths: [Int]
    /// Raw user message texts for keyword/domain analysis.
    let userMessageTexts: [String]
}

/// Lightweight summary of a single tool execution.
struct ToolExecutionSummary: Sendable {
    let toolName: String
    let isSuccess: Bool
    let isDenied: Bool
}

// MARK: - Profile Update Result

/// The result of an IC-powered profile merge operation.
struct ProfileUpdateResult: Sendable {
    let updatedMarkdown: String
    let sectionsModified: [UserProfileSection]
    let timestamp: Date

    init(updatedMarkdown: String, sectionsModified: [UserProfileSection] = [], timestamp: Date = Date()) {
        self.updatedMarkdown = updatedMarkdown
        self.sectionsModified = sectionsModified
        self.timestamp = timestamp
    }
}

// MARK: - Markdown Document (for Export)

/// A transferable document wrapping a markdown string, used with `.fileExporter`.
struct MarkdownProfileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var content: String

    init(content: String) {
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.content = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data = content.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Default Profile Template

/// Generates the initial empty profile markdown with all section headers.
enum UserProfileTemplate {

    static func defaultMarkdown() -> String {
        """
        # User Personal Profile

        > This profile is built automatically from your conversations and agent interactions.
        > You can edit any section directly — your changes will be preserved during future updates.

        ## Interaction Style

        _No observations yet._

        ## Workflow Patterns

        _No observations yet._

        ## Domain Knowledge

        _No observations yet._

        ## Preferences

        _No observations yet._

        ## Tool Effectiveness

        _No observations yet._

        ## Communication Markers

        _No observations yet._
        """
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .init(charactersIn: " ")) }
        .joined(separator: "\n")
    }

    /// All section headers that must appear in a valid profile.
    static var requiredHeaders: [String] {
        UserProfileSection.allCases.map { "## \($0.rawValue)" }
    }

    /// Validates that a profile markdown contains all required section headers.
    static func isValid(_ markdown: String) -> Bool {
        requiredHeaders.allSatisfy { markdown.contains($0) }
    }
}

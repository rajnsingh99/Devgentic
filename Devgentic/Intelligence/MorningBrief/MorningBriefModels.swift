//
//  MorningBriefModels.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation

// MARK: - Brief Item Destination

/// Represents where a tapped brief item should navigate to.
/// Extensible for future source types (calendar, git, etc.).
enum BriefItemDestination: Equatable {
    case conversation(id: UUID)
    // Future destinations:
    // case calendarEvent(eventID: String)
    // case reminder(reminderID: String)
    // case gitRepo(path: String)
    // case url(URL)
}

// MARK: - Brief Fragment (Internal)

/// A raw piece of context contributed by a `MorningBriefSource`.
/// Not displayed in the UI — used internally to pass data from sources
/// to the service, which feeds it to the Intelligence Core for processing.
struct BriefFragment: Identifiable, Equatable {
    let id: UUID
    /// Which source produced this fragment (matches `MorningBriefSource.id`).
    let sourceID: String
    /// Short display title for logging/debug.
    let title: String
    /// Secondary detail for logging/debug.
    let detail: String
    /// Tappable navigation target carried through to the generated insight.
    let destination: BriefItemDestination?
    /// Ordering hint — lower values are processed first.
    let priority: Int
    /// Raw text fed into the IC prompt.
    let rawContext: String

    init(
        id: UUID = UUID(),
        sourceID: String,
        title: String,
        detail: String,
        destination: BriefItemDestination? = nil,
        priority: Int = 0,
        rawContext: String = ""
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.detail = detail
        self.destination = destination
        self.priority = priority
        self.rawContext = rawContext
    }
}

// MARK: - Conversation Insight

/// An AI-generated summary of a single conversation, with an optional suggestion.
/// Each insight links back to its conversation for tap-to-navigate.
struct ConversationInsight: Identifiable, Equatable {
    let id: UUID
    /// The conversation this insight refers to.
    let conversationID: UUID
    /// The conversation's display title.
    let title: String
    /// How long ago the conversation was active (e.g. "2h").
    let timeAgo: String
    /// AI-generated 1-2 sentence summary of what was discussed/accomplished.
    let summary: String
    /// AI-generated actionable suggestion (e.g. "Consider writing tests for the parser").
    let suggestion: String?

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        title: String,
        timeAgo: String,
        summary: String,
        suggestion: String? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.title = title
        self.timeAgo = timeAgo
        self.summary = summary
        self.suggestion = suggestion
    }
}

// MARK: - Conversation Context (Internal)

/// Raw context gathered from a conversation before AI processing.
/// Used internally by sources; not shown in UI directly.
struct ConversationContext {
    let conversationID: UUID
    let title: String
    let timeAgo: String
    let messageCount: Int
    /// Condensed message content for the IC prompt (user + agent messages).
    let condensedContent: String
}

// MARK: - Morning Brief

/// The complete AI-generated morning brief, ready for display.
struct MorningBrief: Identifiable {
    let id: UUID
    let generatedAt: Date
    /// Per-conversation AI summaries with suggestions.
    let insights: [ConversationInsight]
    /// System health one-liner (chip, RAM, disk).
    let systemStatus: String?

    init(
        id: UUID = UUID(),
        generatedAt: Date = Date(),
        insights: [ConversationInsight],
        systemStatus: String? = nil
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.insights = insights
        self.systemStatus = systemStatus
    }

    /// Whether the brief has any meaningful content to display.
    var isEmpty: Bool {
        insights.isEmpty
    }
}

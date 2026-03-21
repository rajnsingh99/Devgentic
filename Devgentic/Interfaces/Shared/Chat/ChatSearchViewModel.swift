//
//  ChatSearchViewModel.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI
import Combine

struct SearchMatch: Identifiable {
    let id = UUID()
    let messageID: UUID
    let matchIndex: Int // Which match within this message (0-based)
}

@MainActor
class ChatSearchViewModel: ObservableObject {
    @Published var isSearchActive: Bool = false
    @Published var searchQuery: String = ""
    @Published var matches: [SearchMatch] = []
    @Published var currentMatchIndex: Int = 0

    private var searchCancellable: AnyCancellable?

    var totalMatchCount: Int { matches.count }

    var currentMatchMessageID: UUID? {
        guard !matches.isEmpty, currentMatchIndex >= 0, currentMatchIndex < matches.count else { return nil }
        return matches[currentMatchIndex].messageID
    }

    /// Returns the local match index within the current message for highlighting the "active" match.
    var currentMatchLocalIndex: Int? {
        guard !matches.isEmpty, currentMatchIndex >= 0, currentMatchIndex < matches.count else { return nil }
        return matches[currentMatchIndex].matchIndex
    }

    init() {
        searchCancellable = $searchQuery
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.currentMatchIndex = 0
            }
    }

    func performSearch(in messages: [ChatMessage]) {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            matches = []
            currentMatchIndex = 0
            return
        }

        var results: [SearchMatch] = []

        // Messages are stored newest-first; iterate reversed for oldest-first display order
        for message in messages.reversed() {
            let content: String?
            if message.sender == .agent, let agentContent = message.currentAgentContent {
                content = agentContent.textContent
            } else {
                content = message.content.textContent
            }

            guard let text = content, !text.isEmpty else { continue }

            var searchRange = text.startIndex..<text.endIndex
            var matchIndexInMessage = 0

            while let range = text.range(of: query, options: .caseInsensitive, range: searchRange) {
                results.append(SearchMatch(messageID: message.id, matchIndex: matchIndexInMessage))
                matchIndexInMessage += 1
                searchRange = range.upperBound..<text.endIndex
            }
        }

        matches = results
        if currentMatchIndex >= results.count {
            currentMatchIndex = results.isEmpty ? 0 : 0
        }
    }

    func nextMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matches.count
    }

    func previousMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
    }

    func activate() {
        isSearchActive = true
    }

    func dismiss() {
        isSearchActive = false
        searchQuery = ""
        matches = []
        currentMatchIndex = 0
    }

    func toggleSearch() {
        if isSearchActive {
            dismiss()
        } else {
            activate()
        }
    }

    /// Returns the number of matches for a specific message.
    func matchCount(for messageID: UUID) -> Int {
        matches.filter { $0.messageID == messageID }.count
    }

    /// Returns whether this message contains the currently active match.
    func isCurrentMatchMessage(_ messageID: UUID) -> Bool {
        currentMatchMessageID == messageID
    }

    /// Returns the local index of the active match within this message, or nil if not in this message.
    func activeMatchLocalIndex(for messageID: UUID) -> Int? {
        guard isCurrentMatchMessage(messageID) else { return nil }
        return currentMatchLocalIndex
    }
}

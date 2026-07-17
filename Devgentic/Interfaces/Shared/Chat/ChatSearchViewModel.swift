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

@Observable @MainActor
class ChatSearchViewModel {
    var isSearchActive: Bool = false
    var searchQuery: String = "" {
        didSet {
            if searchQuery != oldValue {
                currentMatchIndex = 0
                debouncedQuerySubject.send(searchQuery)
            }
        }
    }
    var matches: [SearchMatch] = []
    var currentMatchIndex: Int = 0

    // MARK: - Debounce Infrastructure
    /// Subject that receives raw query changes for debouncing.
    @ObservationIgnored private let debouncedQuerySubject = PassthroughSubject<String, Never>()
    /// The debounced query that actually triggers search execution.
    @ObservationIgnored private(set) var debouncedQuery: String = ""
    @ObservationIgnored private var debounceCancellable: AnyCancellable?

    /// Debounce interval in seconds. 150ms balances responsiveness with performance.
    static let debounceInterval: TimeInterval = 0.15

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
        setupDebounce()
    }

    /// Sets up the Combine debounce pipeline.
    /// Search executes only after the user stops typing for `debounceInterval`.
    private func setupDebounce() {
        debounceCancellable = debouncedQuerySubject
            .debounce(for: .seconds(Self.debounceInterval), scheduler: RunLoop.main)
            .sink { [weak self] query in
                self?.debouncedQuery = query
            }
    }

    /// The searchable text for a message: the selected agent variant when present
    /// (so results match what's on screen for regenerated responses), else `content`.
    private static func searchableText(for message: ChatMessage) -> String? {
        let content: String?
        if message.sender == .agent, let agentContent = message.currentAgentContent {
            content = agentContent.textContent
        } else {
            content = message.content.textContent
        }
        guard let text = content, !text.isEmpty else { return nil }
        return text
    }

    /// Runs the search against the CURRENT message contents — extraction and
    /// lowercasing happen at query time, so results are correct by construction.
    ///
    /// A pre-computed index (the previous design) went stale on every in-place
    /// content mutation: a streamed response finalizes without any membership
    /// change, so the just-completed answer was unsearchable until the next
    /// message arrived; variant switches (Redo) had the same hole. The 150ms
    /// debounce bounds how often this runs, and lowercasing even hundreds of KB
    /// is cheap relative to one keystroke.
    func performSearch(in messages: [ChatMessage]) {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            matches = []
            currentMatchIndex = 0
            return
        }

        let lowercasedQuery = query.lowercased()
        var results: [SearchMatch] = []

        // Messages are stored newest→oldest; scan reversed so matches come out
        // in display (oldest→newest) order for natural next/previous navigation.
        for message in messages.reversed() {
            guard let text = Self.searchableText(for: message) else { continue }
            let lowercasedText = text.lowercased()
            var searchRange = lowercasedText.startIndex..<lowercasedText.endIndex
            var matchIndexInMessage = 0

            while let range = lowercasedText.range(of: lowercasedQuery, range: searchRange) {
                results.append(SearchMatch(messageID: message.id, matchIndex: matchIndexInMessage))
                matchIndexInMessage += 1
                searchRange = range.upperBound..<lowercasedText.endIndex
            }
        }

        matches = results
        if currentMatchIndex >= results.count {
            currentMatchIndex = 0
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

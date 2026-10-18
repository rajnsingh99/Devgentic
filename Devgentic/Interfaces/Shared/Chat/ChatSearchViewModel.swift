// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatSearchViewModel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import Combine
import os

private let logger = DGLogger(category: "ChatSearch")

/// Where the active match lives inside a message. Value-comparable so
/// `ContentBlockView.==` keeps memoizing settled blocks during streaming.
struct ActiveSearchMatch: Equatable, Sendable {
    let blockID: String?
    let indexInBlock: Int
}

struct SearchMatch: Identifiable, Equatable, Sendable {
    let messageID: UUID
    /// `ContentBlock.id` of the block that renders this match, or nil when the message renders as one undecomposed `Text`
    /// (user bubbles, agent `.plainText`). `indexInBlock` counts occurrences within that block.
    let blockID: String?
    /// 0-based index of this match WITHIN that unit's highlightable string — exactly the index
    /// `SearchHighlighter.applyHighlights` enumerates for the same string.
    let indexInBlock: Int

    // Why: re-runs are membership- and query-driven, not streaming-driven: an in-place text mutation triggers none of them.
    /// Derived rather than a fresh UUID, so a re-run can re-anchor `currentMatchIndex` on the same match.
    var id: String { "\(messageID.uuidString)#\(blockID ?? "-")#\(indexInBlock)" }
}

@Observable @MainActor
class ChatSearchViewModel {
    var isSearchActive: Bool = false
    var searchQuery: String = "" {
        didSet {
            if searchQuery != oldValue {
                currentMatchIndex = 0
                currentMatchUnreachable = false
                    debouncedQuerySubject.send(searchQuery)
            }
        }
    }
    var matches: [SearchMatch] = []
    var currentMatchIndex: Int = 0

    /// The active match was found in stored history but lies beyond the resident window's cap, so navigation cannot
    /// scroll to it. Set by the chat view's scroll attempt; cleared on the next successful scroll, any query edit and
    /// dismiss, so the bar can say "older than the loaded history" instead of "3 of 12" while nothing scrolls.
    var currentMatchUnreachable: Bool = false

    // Why: never compute it in `ChatSearchBar.body`: it would walk the whole corpus on every keystroke and streaming flush.
    /// How many of `matches` lie past the resident window's cap: the "N older not shown" half of the badge.
    /// Stored, written by `ChatHistoryViewModel.runSearch` from the same corpus snapshot as `matches`;
    /// reset with `matches` and on dismiss.
    var unreachableMatchCount: Int = 0

    // Why: highlighters must use this, not `searchQuery`: untrimmed whitespace makes the two sides count different strings.
    /// The query both sides measure: `searchQuery` is the raw text, this is the trimmed string actually searched for.
    var effectiveQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The query `matches` were produced from, so a re-run can tell "same query, new events"
    /// from "the user edited the query".
    @ObservationIgnored private var matchedQuery: String?

    // MARK: - Debounce Infrastructure
    /// Subject that receives raw query changes for debouncing.
    @ObservationIgnored private let debouncedQuerySubject = PassthroughSubject<String, Never>()
    /// The debounced query that actually triggers search execution.
    @ObservationIgnored private(set) var debouncedQuery: String = ""
    @ObservationIgnored private var debounceCancellable: AnyCancellable?

    /// Debounce interval in seconds. 150ms balances responsiveness with performance.
    static let debounceInterval: TimeInterval = 0.15

    var totalMatchCount: Int { matches.count }

    /// The match-count badge's text, built from the STORED unreachable count ([vm-3]). Lives
    /// here rather than in `ChatSearchBar` so the string the badge shows is pinnable by a unit
    /// test — the bar's `body` is not.
    var matchCountLabel: String {
        if totalMatchCount == 0 { return String(localized: "No results") }
        let position = String(localized: "\(currentMatchIndex + 1) of \(totalMatchCount)")
        guard unreachableMatchCount > 0 else { return position }
        return String(localized: "\(position) · \(unreachableMatchCount) older not shown")
    }

    /// The badge's accessibility label — same inputs, spelled out.
    var matchCountAccessibilityLabel: String {
        if totalMatchCount == 0 { return String(localized: "No results") }
        let position = String(localized: "Match \(currentMatchIndex + 1) of \(totalMatchCount)")
        guard unreachableMatchCount > 0 else { return position }
        return String(localized: "\(position), \(unreachableMatchCount) older matches not loaded and cannot be reached")
    }

    var currentMatchMessageID: UUID? {
        guard !matches.isEmpty, currentMatchIndex >= 0, currentMatchIndex < matches.count else { return nil }
        return matches[currentMatchIndex].messageID
    }

    private var currentMatch: SearchMatch? {
        matches.indices.contains(currentMatchIndex) ? matches[currentMatchIndex] : nil
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

    // Why: "3 of 12" promises twelve visible highlights, so unpaintable units are never emitted as matches.
    /// Runs the search over the same decomposition and strings the renderer highlights, one match per paintable occurrence.
    /// Extracts at query time but only runs when called: an in-place text mutation does not re-run it.
    /// Units whose view takes no search query (code, tables, images, error cards, checkpoints) are counted as suppressed.
    func performSearch(in documents: [SearchDocument]) {
        let query = effectiveQuery
        guard !query.isEmpty else {
            matches = []
            matchedQuery = nil
            currentMatchIndex = 0
            currentMatchUnreachable = false
            unreachableMatchCount = 0
            return
        }

        // Re-anchor on the same match across re-runs, but only within the same query: `SearchMatch.id` has no query identity,
        // so after an edit the old anchor could drop the user mid-results instead of at the first hit.
        let previousKey = (matchedQuery == query) ? currentMatch?.id : nil
        var results: [SearchMatch] = []
        var suppressed = 0

        // Documents arrive newest→oldest; scan reversed so matches come out in display
        // (oldest→newest) order for natural next/previous navigation.
        for document in documents.reversed() {
            for unit in document.units {
                let count = SearchHighlighter.matchOffsets(in: unit.text, query: query).count
                guard count > 0 else { continue }
                guard unit.isHighlightable else {
                    suppressed += count
                    continue
                }
                for index in 0..<count {
                    results.append(SearchMatch(messageID: document.id,
                                               blockID: unit.blockID,
                                               indexInBlock: index))
                }
            }
        }

        matches = results
        // A new match set invalidates the old count; `runSearch` writes the new one from the same corpus snapshot after this
        // returns. Direct callers get "nothing known to be unreachable".
        unreachableMatchCount = 0
        currentMatchIndex = previousKey.flatMap { key in results.firstIndex { $0.id == key } }
            ?? (previousKey == nil ? 0 : (currentMatchIndex < results.count ? currentMatchIndex : 0))
        matchedQuery = query

        if suppressed > 0 {
            logger.info("[SEARCH] \(results.count) match(es) across \(documents.count) document(s); \(suppressed) NOT counted — they sit in code/table/image/error content whose view accepts no search query, so counting them would promise a highlight that cannot be painted.")
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
        matchedQuery = nil
        currentMatchIndex = 0
        currentMatchUnreachable = false
        unreachableMatchCount = 0
    }

    func toggleSearch() {
        if isSearchActive {
            dismiss()
        } else {
            activate()
        }
    }

    /// Returns whether this message contains the currently active match.
    func isCurrentMatchMessage(_ messageID: UUID) -> Bool {
        currentMatchMessageID == messageID
    }

    /// The active target when it lies inside this message; nil otherwise.
    func activeMatch(in messageID: UUID) -> ActiveSearchMatch? {
        guard let match = currentMatch, match.messageID == messageID else { return nil }
        return ActiveSearchMatch(blockID: match.blockID, indexInBlock: match.indexInBlock)
    }

    /// For single-unit surfaces (user bubble, agent `.plainText`), which have no block id.
    func activeMatchIndex(in messageID: UUID, blockID: String?) -> Int? {
        guard let active = activeMatch(in: messageID), active.blockID == blockID else { return nil }
        return active.indexInBlock
    }
}

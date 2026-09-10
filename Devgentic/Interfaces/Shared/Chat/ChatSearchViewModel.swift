// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ChatSearchViewModel.swift
//  Devgentic
//
//  Created by Raj Singh
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
    /// `ContentBlock.id` of the block that renders this match, or nil when the message renders
    /// as ONE undecomposed `Text` (user bubbles, agent `.plainText`).
    ///
    /// The old model stored a single index counted across the message's whole raw source and
    /// handed it to every block, which then compared it against its OWN offsets — so the
    /// active highlight landed on the wrong occurrence or on nothing.
    let blockID: String?
    /// 0-based index of this match WITHIN that unit's highlightable string — exactly the index
    /// `SearchHighlighter.applyHighlights` enumerates for the same string.
    let indexInBlock: Int

    /// Derived rather than a fresh UUID, so a re-run can re-anchor `currentMatchIndex` on the
    /// same match instead of silently jumping the user somewhere else.
    ///
    /// ⚠️ Re-runs are MEMBERSHIP- and QUERY-driven, not streaming-driven: the three call sites
    /// fire on `messagesToken` (count + first/last id), on the debounced query, and when the bar
    /// opens. A message whose text mutates in place changes none of those — see CH64.
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

    /// The active match was found in the stored history but sits beyond the resident
    /// window's cap, so navigation cannot scroll to it. Set by the chat view's scroll
    /// attempt (it owns the residency question); cleared on the next successful scroll, on
    /// any query edit, and on dismiss — so the search bar can say "older than the loaded
    /// history" instead of showing "3 of 12" while the transcript visibly does nothing (CF-35).
    var currentMatchUnreachable: Bool = false

    /// THE query both sides measure. `searchQuery` is the user's raw text (the TextField binds
    /// straight to it); this is what is actually searched for.
    ///
    /// ⚠️ Every consumer that highlights MUST use this, not `searchQuery`. The producer trimmed
    /// and the three render paths did not, so a query with leading/trailing whitespace made the
    /// two sides count occurrences of DIFFERENT strings — the same index-space drift CH28/CH29
    /// exist to prevent, one argument over from the one they fixed. `ChatSearchDecomposition`
    /// makes "the text we search IN" single-sourced; this does the same for "what we search FOR".
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

    /// Runs the search over the SAME decomposition and the SAME strings the renderer
    /// highlights (`SearchDocument`/`SearchUnit`), emitting one match per paintable
    /// occurrence, keyed by block.
    ///
    /// Extraction happens at query time, so whatever this is handed is read fresh — a
    /// pre-computed index (an older design) went stale on every in-place content mutation.
    ///
    /// ⚠️ That does NOT mean a streaming answer becomes searchable the moment it settles. This
    /// method only runs when something CALLS it, and nothing re-runs it on an in-place text
    /// mutation: a just-finished answer is still unsearchable until membership changes or the
    /// user edits the query. Filed as CH64 — do not read "query-time" as "live".
    ///
    /// Units whose view accepts no search query (code, tables, images, error cards,
    /// checkpoints) are counted as SUPPRESSED rather than emitted: "3 of 12" is a promise
    /// that pressing Next twelve times shows twelve highlights, and the old behaviour
    /// advertised positions that could never be painted.
    func performSearch(in documents: [SearchDocument]) {
        let query = effectiveQuery
        guard !query.isEmpty else {
            matches = []
            matchedQuery = nil
            currentMatchIndex = 0
            currentMatchUnreachable = false
                return
        }

        // Re-anchor on the SAME match across re-runs (membership changes re-run this) — but ONLY
        // within the same query. `SearchMatch.id` is a pure (message, block, ordinal) tuple with
        // no query identity, and `searchQuery.didSet` deliberately keeps the old `matches`, so
        // after an EDIT the old anchor could still be found in the new result set and drop the
        // user into the middle of it: broadening "error" to "err" jumped to "13 of 40" and
        // scrolled away from the first hit of what they had just typed.
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

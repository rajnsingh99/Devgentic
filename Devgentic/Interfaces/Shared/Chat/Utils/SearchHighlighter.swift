// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SearchHighlighter.swift
//  Devgentic
//
//  Single implementation of find-in-conversation match highlighting, shared by
//  every chat surface (agent bubbles, markdown blocks, user bubbles). Previously
//  this ~40-line offset-finding + forward-cursor apply pass was copy-pasted into
//  three views, which had already drifted on the active-match color.
//
//  Both passes are O(n): one incremental scan to record character offsets of each
//  match, then one forward-cursor pass to paint backgrounds. Highlight hues are
//  injected by the caller (theme tokens) so no surface hard-codes colors — see
//  `Theme.searchHighlight` / `Theme.searchHighlightActive`.
//

import SwiftUI

enum SearchHighlighter {

    /// Default hues for the theme-less static entry points (and the test suite).
    /// Kept in sync with the `Theme.searchHighlight` / `.searchHighlightActive` defaults.
    static let defaultBase: Color = Color.yellow.opacity(0.4)
    static let defaultActive: Color = Color.orange.opacity(0.6)

    /// Half-open character range `[start, end)` of one match, measured in Character
    /// units so offsets apply cleanly to an `AttributedString` cursor.
    struct MatchOffset: Equatable {
        let start: Int
        let end: Int
    }

    /// Character offsets of every case-insensitive, non-overlapping occurrence of
    /// `query` in `text`. Empty when the query is empty or unmatched.
    ///
    /// Each `distance(from: searchStart, ...)` measures only the gap since the last
    /// match, so the whole pass is O(n) rather than O(n·matches).
    static func matchOffsets(in text: String, query: String) -> [MatchOffset] {
        guard !query.isEmpty else { return [] }

        let lowerText = text.lowercased()
        let lowerQuery = query.lowercased()
        let queryLen = lowerQuery.count

        var offsets: [MatchOffset] = []
        var searchStart = lowerText.startIndex
        var running = 0

        while searchStart < lowerText.endIndex,
              let range = lowerText.range(of: lowerQuery, range: searchStart..<lowerText.endIndex) {
            running += lowerText.distance(from: searchStart, to: range.lowerBound)
            offsets.append(MatchOffset(start: running, end: running + queryLen))
            searchStart = range.upperBound
            running += queryLen
        }
        return offsets
    }

    /// Paints highlight backgrounds onto `attr` for the given offsets. The cursor
    /// advances only by the gap to each match (O(gap)), so the pass is O(n).
    /// The match at `activeIndex` gets `active`; the rest get `base`.
    static func applyHighlights(
        to attr: inout AttributedString,
        offsets: [MatchOffset],
        activeIndex: Int?,
        base: Color,
        active: Color
    ) {
        guard !offsets.isEmpty else { return }

        var cursor = attr.startIndex
        var cursorOffset = 0

        for (index, match) in offsets.enumerated() {
            let advanceToStart = match.start - cursorOffset
            if advanceToStart > 0 {
                cursor = attr.index(cursor, offsetByCharacters: advanceToStart)
                cursorOffset = match.start
            }
            let attrStart = cursor

            cursor = attr.index(cursor, offsetByCharacters: match.end - cursorOffset)
            cursorOffset = match.end

            attr[attrStart..<cursor].backgroundColor = (activeIndex == index) ? active : base
        }
    }

    /// Builds a highlighted `AttributedString` from plain `text` (plain-text path).
    static func highlight(
        _ text: String,
        query: String,
        activeMatchIndex: Int? = nil,
        base: Color = defaultBase,
        active: Color = defaultActive
    ) -> AttributedString {
        var attr = AttributedString(text)
        let offsets = matchOffsets(in: text, query: query)
        applyHighlights(to: &attr, offsets: offsets, activeIndex: activeMatchIndex, base: base, active: active)
        return attr
    }

    /// Applies highlights onto an already-styled `AttributedString` (markdown path),
    /// preserving its existing runs (bold, inline code, etc.).
    static func highlight(
        _ attr: AttributedString,
        query: String,
        activeMatchIndex: Int? = nil,
        base: Color = defaultBase,
        active: Color = defaultActive
    ) -> AttributedString {
        var result = attr
        let plain = String(result.characters)
        let offsets = matchOffsets(in: plain, query: query)
        applyHighlights(to: &result, offsets: offsets, activeIndex: activeMatchIndex, base: base, active: active)
        return result
    }
}

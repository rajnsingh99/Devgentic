// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TimelinePrimaryArgCacheTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class TimelinePrimaryArgCacheTests: XCTestCase {

    private let rowID = UUID()

    private func row(params: String, isExecuting: Bool, isSuccess: Bool?) -> ToolExecutionData {
        ToolExecutionData(
            id: rowID,
            name: "write_file",
            params: params,
            output: nil,
            isSuccess: isSuccess,
            isExecuting: isExecuting
        )
    }

    // MARK: - Hit: the cached label is used and the params are NOT parsed

    /// Malformed params would parse to "" — so a non-empty result proves the cache was
    /// read and the (expensive) parse was skipped.
    func test_matchingKey_returnsCachedLabel_withoutParsingParams() {
        let key = TimelineChipKey(id: rowID, isExecuting: false, isSuccess: true)
        let label = ActionDetailView.primaryArgLabel(
            cached: (key: key, label: "Cached.swift"),
            for: key,
            tool: "write_file",
            params: "{ this is not json"
        )
        XCTAssertEqual(label, "Cached.swift")
    }

    // MARK: - Miss: a fresh parse

    /// First body pass, before `.task` has populated the cache: still renders, from a parse.
    func test_noCache_parsesParams() {
        let key = TimelineChipKey(id: rowID, isExecuting: true, isSuccess: nil)
        let label = ActionDetailView.primaryArgLabel(
            cached: nil,
            for: key,
            tool: "write_file",
            params: #"{"path":"/Users/me/Fresh.swift","content":"..."}"#
        )
        XCTAssertEqual(label, "Fresh.swift")
    }

    /// Completion flips `isExecuting` (and rewrites `params`) — the stale cache must lose.
    func test_completionKeyChange_ignoresStaleCache() {
        let executing = TimelineChipKey(id: rowID, isExecuting: true, isSuccess: nil)
        let completed = TimelineChipKey(id: rowID, isExecuting: false, isSuccess: true)
        let label = ActionDetailView.primaryArgLabel(
            cached: (key: executing, label: "Original.swift"),
            for: completed,
            tool: "write_file",
            params: #"{"path":"/Users/me/Edited.swift"}"#
        )
        XCTAssertEqual(label, "Edited.swift", "the HITL-edited path must win over the pre-completion label")
    }

    /// A recycled row identity showing a different event must never display the previous
    /// event's label for even one pass.
    func test_differentRowID_ignoresCache() {
        let other = TimelineChipKey(id: UUID(), isExecuting: false, isSuccess: true)
        let mine = TimelineChipKey(id: rowID, isExecuting: false, isSuccess: true)
        let label = ActionDetailView.primaryArgLabel(
            cached: (key: other, label: "Theirs.swift"),
            for: mine,
            tool: "read_file",
            params: #"{"path":"/Users/me/Mine.swift"}"#
        )
        XCTAssertEqual(label, "Mine.swift")
    }

    // MARK: - The key the cache is built on

    /// The cache is only as good as its key: completion must change it, because completion
    /// is where `params` is rewritten (`completeToolTimelineEvent` and
    /// `CapabilityCardRouter.completeTool` both assign `params` and flip `isExecuting` in
    /// the same mutation).
    func test_chipKey_changesWhenTheToolCompletes() {
        let before = ActionDetailView.chipKey(for: row(params: "{}", isExecuting: true, isSuccess: nil))
        let after = ActionDetailView.chipKey(for: row(params: #"{"path":"/x"}"#, isExecuting: false, isSuccess: true))
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before.id, after.id, "same row, different completion state")
    }

    /// And it is stable across stream events that do NOT touch the row, which is what
    /// makes it a cache at all.
    func test_chipKey_isStableForAnUnchangedRow() {
        let data = row(params: #"{"path":"/x"}"#, isExecuting: false, isSuccess: true)
        XCTAssertEqual(ActionDetailView.chipKey(for: data), ActionDetailView.chipKey(for: data))
    }
}

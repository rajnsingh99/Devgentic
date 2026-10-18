// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  QueryRewriteGuardTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class QueryRewriteGuardTests: XCTestCase {

    // MARK: - Observed hallucinations (must be rejected)

    func testObservedHallucination_FireToWildfires_Rejected() {
        // Whole-word matching is load-bearing: "wildfires" CONTAINS "fire" as a
        // substring, so naive containment would wave this through.
        XCTAssertFalse(QueryRewritingService.rewriteRetainsOriginalTopic(
            original: "Write an essay on Fire",
            rewrite: "Write an essay on the impact of wildfires on biodiversity"
        ))
    }

    func testObservedHallucination_TechnologyToAttachedFile_Rejected() {
        XCTAssertFalse(QueryRewritingService.rewriteRetainsOriginalTopic(
            original: "Write an essay on technology",
            rewrite: "Explain attached file in composer application"
        ))
    }

    func testSymbolDropped_Rejected() {
        XCTAssertFalse(QueryRewritingService.rewriteRetainsOriginalTopic(
            original: "Tell me about addAttachedFiles method",
            rewrite: "How does the file picker work in the app"
        ))
    }

    // MARK: - Legitimate rewrites (must pass)

    func testExpansionWithHistoryContext_Passes() {
        // The rewriter's actual job: original content words retained, context added.
        XCTAssertTrue(QueryRewritingService.rewriteRetainsOriginalTopic(
            original: "what is \u{201C}captureDeniedPopover\u{201D}?",
            rewrite: "captureDeniedPopover"
        ))
        XCTAssertTrue(QueryRewritingService.rewriteRetainsOriginalTopic(
            original: "Tell me about addAttachedFiles method",
            rewrite: "addAttachedFiles method in ChatInputAreaView for attaching files"
        ))
    }

    func testUnchangedRewrite_Passes() {
        XCTAssertTrue(QueryRewritingService.rewriteRetainsOriginalTopic(
            original: "Write an essay on Earth",
            rewrite: "Write an essay on Earth"
        ))
    }

    func testPronounOnlyQuery_NoContentWords_Passes() {
        // Nothing to retain — the rewrite exists precisely to replace pure
        // references ("what about that?") with history-derived content.
        XCTAssertTrue(QueryRewritingService.rewriteRetainsOriginalTopic(
            original: "what about that?",
            rewrite: "the parser rewrite discussed in the previous message"
        ))
    }

    func testCaseInsensitiveRetention_Passes() {
        XCTAssertTrue(QueryRewritingService.rewriteRetainsOriginalTopic(
            original: "explain the VECTOR store",
            rewrite: "vector store implementation details"
        ))
    }
}

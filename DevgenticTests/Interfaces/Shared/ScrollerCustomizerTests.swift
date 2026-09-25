// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ScrollerCustomizerTests.swift
//  DevgenticTests
//
//  Tests for ScrollerCustomizer: verifying that scrollers are forced to overlay style
//  and scroller track / path drawing is suppressed across the application.
//

import XCTest
import AppKit
@testable import devgentic

final class ScrollerCustomizerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ScrollerCustomizer.install()
    }

    func testPreferredScrollerStyleIsOverlay() {
        XCTAssertEqual(
            NSScroller.preferredScrollerStyle,
            .overlay,
            "NSScroller.preferredScrollerStyle must always return .overlay"
        )
    }

    func testScrollViewScrollerStyleEnforcesOverlay() {
        let scrollView = NSScrollView()
        scrollView.scrollerStyle = .legacy
        XCTAssertEqual(
            scrollView.scrollerStyle,
            .overlay,
            "NSScrollView.scrollerStyle must be forced to .overlay even if set to .legacy"
        )
    }

    func testScrollerStyleEnforcesOverlay() {
        let scroller = NSScroller()
        scroller.scrollerStyle = .legacy
        XCTAssertEqual(
            scroller.scrollerStyle,
            .overlay,
            "NSScroller.scrollerStyle must be forced to .overlay even if set to .legacy"
        )
    }

    func testDrawKnobSlotExecutesCleanly() {
        let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 100))
        // Calling drawKnobSlot should execute the swizzled no-op cleanly without throwing or crashing
        scroller.drawKnobSlot(in: NSRect(x: 0, y: 0, width: 15, height: 100), highlight: false)
        scroller.drawKnobSlot(in: NSRect(x: 0, y: 0, width: 15, height: 100), highlight: true)
    }
}

//
//  ViewmodelSplitInsetAnimationTests.swift
//  DevgenticTests
//
//  [CF-15] In split mode the chat yields a trailing inset to the Code Viewer. The inset now
//  follows the divider LIVE (`codeViewerLiveDragWidth`, written per drag tick) instead of the
//  persisted width committed on release — but the `.animation(.easeInOut(duration: 0.2))`
//  that modifier was originally written for stayed on it. A 0.2s ease retargeted every frame
//  never catches up, so the chat column trailed a panel edge that tracks the cursor instantly
//  (the panel's `.frame(width:)` is unanimated) and kept sliding for another ~0.2s after the
//  mouse was released — the same overlap the row was filed about, just harder to spot.
//
//  What this pins is the RULE, not the rendering: a drag in flight means no animation.
//  Wiring is by inspection — `MainApplicationView.chatSplitInsetAnimation` returns
//  `Self.splitInsetAnimation(isDraggingDivider:)` and is the sole argument of
//  `.animation(chatSplitInsetAnimation, value: chatSplitInset)`.
//

import XCTest
import SwiftUI
@testable import devgentic

@MainActor
final class ViewmodelSplitInsetAnimationTests: XCTestCase {

    /// The defect: an ease that is retargeted on every drag tick. There must be none.
    func testNoAnimationWhileTheDividerIsBeingDragged() {
        XCTAssertNil(MainApplicationView.splitInsetAnimation(isDraggingDivider: true),
                     "a per-tick inset must apply instantly, or the chat column trails the divider "
                     + "for the whole drag and overruns it on release")
    }

    /// ...and the once-per-open/close/mode-change move keeps its ease: dropping animation
    /// everywhere would make the panel appearing in split mode snap the chat sideways.
    func testInsetIsStillAnimatedWhenNoDragIsRunning() {
        XCTAssertNotNil(MainApplicationView.splitInsetAnimation(isDraggingDivider: false),
                        "opening, closing and mode changes move the inset once and should ease")
    }
}

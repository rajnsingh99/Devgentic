// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ViewmodelSplitInsetAnimationTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DownloadManagerReachabilityTests.swift
//  devgenticTests
//
//  That the Download Manager can be opened at all.
//
//  ⚠️⚠️ IT COULD NOT. `DownloadManagerContainerView` existed, `MainApplicationView` rendered it for
//  `.downloadManager`, and `MainViewRouter.navigateToDownloadManager()` existed to get there — and
//  nothing called that method, so no user action could ever set the destination. The whole screen
//  was unreachable. `DownloadSidebarView` even declared `@Environment(MainViewRouter.self)` for the
//  call that was never written: the dependency was injected, the navigation was not.
//
//  Found by a reference-count sweep, not by anyone using the app — which is the point. This is the
//  same "correct code, no caller" shape that shipped four times in the skills feature.
//

import XCTest
@testable import devgentic

@MainActor
final class DownloadManagerReachabilityTests: XCTestCase {

    /// The destination is reachable, and arriving clears the stack back to chat so Back does not
    /// walk through whatever the user was doing before.
    func testNavigatingOpensTheDownloadManagerFromAClearStack() {
        let router = MainViewRouter()
        router.navigate(to: .settingsDetail(category: .general))

        router.navigateToDownloadManager()

        XCTAssertEqual(router.activeDestination, .downloadManager)
        XCTAssertEqual(router.navigationStack, [.chat],
                       "arriving from a deep stack must reset to chat, not accumulate")
    }

    /// The destination renders as a named screen rather than falling through to a default.
    func testTheDestinationHasItsOwnName() {
        XCTAssertEqual(MainViewDestination.downloadManager.displayName, "Downloads")
    }

    /// ⚠️⚠️ THE ORPHAN GUARD, and the reason this file exists. The test above passes perfectly well
    /// on a router method nothing calls — which was the actual state of the app. Asserted on source
    /// because the call is a SwiftUI button action with no observable seam.
    ///
    /// **Mutation check:** remove the call from `DownloadSidebarView` and only this goes red.
    func testTheDownloadsSidebarActuallyOffersAWayIn() throws {
        let source = try Self.read("Devgentic/Interfaces/Main/Views/Sidebar/DownloadSidebarView.swift")
        XCTAssertTrue(source.contains("router.navigateToDownloadManager()"),
                      "the Downloads sidebar must offer a way to open the manager — without it the screen is unreachable")
    }

    /// And the renderer still knows the destination, so the route does not dead-end in a blank pane.
    func testTheMainViewStillRendersTheDownloadManager() throws {
        let source = try Self.read("Devgentic/Interfaces/Main/Views/MainApplicationView.swift")
        XCTAssertTrue(source.contains("case .downloadManager:"))
        XCTAssertTrue(source.contains("DownloadManagerContainerView()"))
    }

    private static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath) from \(#filePath) — source-reading tests need the checkout present.")
    }
}

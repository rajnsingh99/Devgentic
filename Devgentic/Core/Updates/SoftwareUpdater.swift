// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SoftwareUpdater.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Combine
import Foundation
import Sparkle

private let logger = DGLogger(category: "SoftwareUpdater")

/// Owns the one Sparkle updater for the process and publishes whether "Check for Updates…" is
/// currently allowed (Sparkle disables it while a check or an install is already in flight).
@MainActor
final class SoftwareUpdater: ObservableObject {

    static let shared = SoftwareUpdater()

    /// Mirrors `SPUUpdater.canCheckForUpdates` — drives the menu item's enabled state.
    @Published private(set) var canCheckForUpdates = false

    /// Nil under XCTest, where the updater is never created.
    private let controller: SPUStandardUpdaterController?

    private init() {
        guard TestHost.permits("start the Sparkle updater", logger: logger) else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// The user's standing answer to Sparkle's "check automatically?" question — the Settings
    /// toggle. Sparkle persists it in the app's defaults, so this only relays it.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// When Sparkle last checked the feed (manual or scheduled), or nil if it never has — or
    /// under XCTest, where the updater does not exist.
    var lastUpdateCheckDate: Date? {
        controller?.updater.lastUpdateCheckDate
    }

    /// The user-initiated check behind the "Check for Updates…" menu item. Unlike a background
    /// check, this one shows its result either way — including "you're up to date" and any error
    /// reaching the feed.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

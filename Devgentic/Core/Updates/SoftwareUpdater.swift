// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SoftwareUpdater.swift
//  Devgentic
//
//  Sparkle 2 — in-app updates from https://rajnsingh99.github.io/devgentic/appcast.xml.
//
//  ⚠️⚠️ THE FEED URL AND THE PUBLIC KEY LIVE IN Devgentic/Info.plist (`SUFeedURL`, `SUPublicEDKey`)
//  AND ARE COMPILED INTO EVERY SHIPPED BINARY. Neither can be changed for installs already in the
//  field: a new key makes every existing copy reject every future update, and a new feed host is
//  only survivable through GitHub Pages' 301 from the same account + repo name. The PRIVATE half of
//  the key sits in the release machine's login Keychain (Sparkle's `generate_keys`) and must also
//  be backed up offline — losing it strands every install permanently.
//
//  ⚠️ NO AUTOMATIC CHECK WITHOUT CONSENT. `SUEnableAutomaticChecks` is deliberately ABSENT from
//  Info.plist, so Sparkle asks the user on the second launch whether to check automatically.
//  PRIVACY.md promises the app sends nothing "on its own"; a silent daily request to GitHub would
//  quietly break that. `SUEnableSystemProfiling` is pinned to NO for the same reason.
//
//  ⚠️ NOT STARTED UNDER XCTEST. The test host is the real app (see `TestHost`); an updater that
//  starts there would make scheduled network requests — and could present update UI — during an
//  ordinary test run. A refusal, not a redirect: there is no useful test version of "check GitHub".
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

    /// The user-initiated check behind the "Check for Updates…" menu item. Unlike a background
    /// check, this one shows its result either way — including "you're up to date" and any error
    /// reaching the feed.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MasterSwitchObservabilityTests.swift
//  DevgenticTests
//
//  ⚠️ WRITTEN TO FAIL FIRST. These two tests were added against the ORIGINAL
//  `@ObservationIgnored @AppStorage` declaration to prove the defect empirically rather than take a
//  review's word for it. Both were red before the fix.
//

import XCTest
import Observation
@testable import devgentic

@MainActor
final class MasterSwitchObservabilityTests: XCTestCase {

    private var originalStored: Any?
    private var originalValue = true

    override func setUp() async throws {
        try await super.setUp()
        originalStored = UserDefaults.standard.object(forKey: AppSettings.notificationsEnabledKey)
        originalValue = NotificationConfiguration.shared.isGloballyEnabled
    }

    override func tearDown() async throws {
        NotificationConfiguration.shared.isGloballyEnabled = originalValue
        if let originalStored {
            UserDefaults.standard.set(originalStored, forKey: AppSettings.notificationsEnabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppSettings.notificationsEnabledKey)
        }
        try await super.tearDown()
    }

    /// ⚠️ HALF ONE OF THE ROOT CAUSE: the property CACHES. `@AppStorage` is a `DynamicProperty`,
    /// and `DynamicProperty.update()` is only called for a `View` — never for a property declared
    /// on a class. So the wrapper reads the store once and then answers from its own copy forever,
    /// while `NotificationDispatcher` reads `UserDefaults` live. Two readers of "the same" setting,
    /// giving different answers.
    func testThePropertyReflectsTheStoreRatherThanACachedCopy() {
        let defaults = UserDefaults.standard
        let config = NotificationConfiguration.shared

        config.isGloballyEnabled = true
        XCTAssertTrue(config.isGloballyEnabled)

        // An out-of-band write — exactly what a different process, a defaults import, or the
        // dispatcher's own view of the world looks like.
        defaults.set(false, forKey: AppSettings.notificationsEnabledKey)

        XCTAssertFalse(config.isGloballyEnabled, """
            The settings pane still reports notifications as ON while the store — and therefore \\
            NotificationDispatcher.dispatch() — says OFF. The pane cannot be trusted to show what \\
            is actually enforced.
            """)
        XCTAssertEqual(config.isGloballyEnabled,
                       NotificationGatePolicy.isGloballyEnabled(in: defaults),
                       "the pane and the dispatcher must read the same state, not just the same rule")
    }

    /// ⚠️ HALF TWO OF THE ROOT CAUSE: writing the property notifies NOBODY. `@ObservationIgnored`
    /// removes it from `@Observable`'s tracking, and `@AppStorage` on a class publishes nothing of
    /// its own, so a SwiftUI body that reads it registers no dependency and is never invalidated.
    /// Any `.disabled(...)` or conditional built on it renders once and then lies.
    func testFlippingTheMasterSwitchInvalidatesAViewObservingIt() {
        let config = NotificationConfiguration.shared
        config.isGloballyEnabled = true

        var invalidated = false
        withObservationTracking {
            _ = config.isGloballyEnabled
        } onChange: {
            invalidated = true
        }

        config.isGloballyEnabled = false

        XCTAssertTrue(invalidated, """
            No observation fired, so SwiftUI never re-renders a view that reads this. The master \\
            Toggle's own binding and every control gated on it hold whatever value they had when \\
            the body last ran.
            """)
    }
}

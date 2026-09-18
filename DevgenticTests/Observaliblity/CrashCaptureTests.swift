// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CrashCaptureTests.swift
//  DevgenticTests
//
//  Regression coverage for crash capture (§12.1): the DiagnosticReports filename
//  matcher (which decides what gets harvested into a bundle — over-matching would leak
//  OTHER apps' crash reports into a user's bug report) and the clean-exit sentinel
//  state machine (crash vs quit detection at launch).
//

import XCTest
@testable import devgentic

final class CrashCaptureTests: XCTestCase {

    // MARK: - .ips filename matching

    func testMatcher_acceptsOwnCrashAndHangReports_caseInsensitively() {
        XCTAssertTrue(CrashDiagnosticsCollector.matchesCrashReport(
            filename: "devgentic-2026-06-11-101530.ips", processName: "devgentic"))
        XCTAssertTrue(CrashDiagnosticsCollector.matchesCrashReport(
            filename: "Devgentic-2026-06-11-101530.ips", processName: "devgentic"),
            "Apple capitalizes the process name in report filenames")
        XCTAssertTrue(CrashDiagnosticsCollector.matchesCrashReport(
            filename: "devgentic-2026-06-11-101530.hang", processName: "Devgentic"))
    }

    func testMatcher_rejectsOtherAppsAndOtherFileTypes() {
        // The privacy-critical case: another app's reports must never be harvested.
        XCTAssertFalse(CrashDiagnosticsCollector.matchesCrashReport(
            filename: "Safari-2026-06-11-101530.ips", processName: "devgentic"))
        // Prefix must be the full process name followed by the date separator —
        // "devgentic2" or "devgenticHelper" are different processes.
        XCTAssertFalse(CrashDiagnosticsCollector.matchesCrashReport(
            filename: "devgenticHelper-2026-06-11.ips", processName: "devgentic"))
        // Non-crash diagnostic types stay out (spin/diag are noisy and less useful).
        XCTAssertFalse(CrashDiagnosticsCollector.matchesCrashReport(
            filename: "devgentic-2026-06-11.spin", processName: "devgentic"))
        XCTAssertFalse(CrashDiagnosticsCollector.matchesCrashReport(
            filename: "devgentic.ips", processName: "devgentic"),
            "No date separator → not an Apple-named report")
    }

    // MARK: - Clean-exit sentinel

    private func freshDefaults() throws -> UserDefaults {
        let suite = "crash-capture-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testSentinel_firstLaunchCountsAsClean() throws {
        let defaults = try freshDefaults()
        XCTAssertTrue(CrashDiagnosticsCollector.consumeLaunchSentinel(defaults: defaults),
                      "Missing sentinel (first launch / pre-feature install) must NOT read as a crash")
    }

    func testSentinel_cleanQuitRoundTrip() throws {
        let defaults = try freshDefaults()
        // Launch → run → clean quit → next launch reads clean.
        CrashDiagnosticsCollector.consumeLaunchSentinel(defaults: defaults)
        CrashDiagnosticsCollector.markCleanExit(defaults: defaults)
        XCTAssertTrue(CrashDiagnosticsCollector.consumeLaunchSentinel(defaults: defaults))
    }

    func testSentinel_crashIsDetectedOnNextLaunch() throws {
        let defaults = try freshDefaults()
        // Launch marks the session dirty; a crash never calls markCleanExit…
        CrashDiagnosticsCollector.consumeLaunchSentinel(defaults: defaults)
        // …so the next launch reads dirty.
        XCTAssertFalse(CrashDiagnosticsCollector.consumeLaunchSentinel(defaults: defaults),
                       "A session that never marked clean exit must read as crashed/force-quit")
    }
}

//
//  DiagnosticsGatingTests.swift
//  DevgenticTests
//
//  Regression coverage for the Phase B3 "always-on diagnostics" change (Gap #4):
//   • the default-on opt-out consent flag
//   • the DGLogger persistence gate (warning/error always, info gated, dev-mode records all)
//   • TelemetrySanitizer correctness after the per-call → cached regex change (§12.9)
//

import XCTest
@testable import devgentic

final class DiagnosticsGatingTests: XCTestCase {

    // MARK: - Consent flag (default-on, opt-out)

    func testDiagnosticsRecordingEnabled_defaultsOnWhenUnset() {
        let key = AppSettings.diagnosticsEnabledKey
        let prior = UserDefaults.standard.object(forKey: key)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(AppSettings.diagnosticsRecordingEnabled, "Absence of the key means ENABLED (default-on)")

        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(AppSettings.diagnosticsRecordingEnabled, "Explicit opt-out disables recording")

        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(AppSettings.diagnosticsRecordingEnabled)
    }

    // MARK: - DGLogger persistence gate

    func testGate_recordsWarningAndError_whenDiagnosticsOn() {
        XCTAssertTrue(DGLogger.shouldPersist(level: .error, diagnosticsEnabled: true))
        XCTAssertTrue(DGLogger.shouldPersist(level: .warning, diagnosticsEnabled: true))
        XCTAssertFalse(DGLogger.shouldPersist(level: .notice, diagnosticsEnabled: true),
                       "the floor is warning — nothing below it is ever persisted")
        XCTAssertFalse(DGLogger.shouldPersist(level: .info, diagnosticsEnabled: true))
        XCTAssertFalse(DGLogger.shouldPersist(level: .debug, diagnosticsEnabled: true))
    }

    /// ⚠️ The opt-out is now ABSOLUTE. It previously read
    /// `developerMode || (level >= .warning && diagnosticsEnabled)`, so a user who turned
    /// diagnostics recording OFF still had every level written to disk whenever developer mode
    /// happened to be on — a consent switch another switch could silently veto.
    func testGate_optOutDropsEverything() {
        for level: LogLevel in [.debug, .info, .notice, .warning, .error] {
            XCTAssertFalse(DGLogger.shouldPersist(level: level, diagnosticsEnabled: false),
                           "\(level) must not persist once the user has opted out")
        }
    }

    /// The floor is a property of the LEVEL alone now — no second axis can raise it.
    /// Measured justification: with the old escalation on, `log_entries` reached 1,060,962 rows
    /// in a 295 MB store over 30 days, 95.1% of it info/notice, none of which any UI reads —
    /// the Run Report renders span_events and never loads a log row.
    func testGate_hasNoSecondAxisThatCanRaiseTheFloor() {
        for level: LogLevel in [.debug, .info, .notice] {
            XCTAssertFalse(DGLogger.shouldPersist(level: level, diagnosticsEnabled: true),
                           "\(level) is os_log-only by design; nothing may escalate it to disk")
        }
    }

    // MARK: - Sanitizer correctness after regex caching

    func testSanitizer_redactsSecrets_andIsStableAcrossRepeatCalls() {
        let input = "opened /Users/alice/Documents/secret.txt for alice@example.com using sk-ant-abc123DEF456ghi789JKL012mno345PQRS"

        let first = TelemetrySanitizer.sanitizeFull(input, level: .standard)
        let second = TelemetrySanitizer.sanitizeFull(input, level: .standard)

        XCTAssertEqual(first, second, "Cached regexes must produce identical output across calls")
        XCTAssertFalse(first.contains("/Users/alice"), "home path must be redacted")
        XCTAssertFalse(first.contains("alice@example.com"), "email must be redacted")
        XCTAssertFalse(first.contains("sk-ant-abc"), "API key must be redacted")
    }
}

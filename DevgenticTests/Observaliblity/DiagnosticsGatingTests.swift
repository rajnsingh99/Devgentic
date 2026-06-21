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
        XCTAssertTrue(DGLogger.shouldPersist(level: .error, developerMode: false, diagnosticsEnabled: true))
        XCTAssertTrue(DGLogger.shouldPersist(level: .warning, developerMode: false, diagnosticsEnabled: true))
        XCTAssertFalse(DGLogger.shouldPersist(level: .notice, developerMode: false, diagnosticsEnabled: true),
                       "Below warning is gated unless developer mode is on")
        XCTAssertFalse(DGLogger.shouldPersist(level: .info, developerMode: false, diagnosticsEnabled: true))
        XCTAssertFalse(DGLogger.shouldPersist(level: .debug, developerMode: false, diagnosticsEnabled: true))
    }

    func testGate_optOutDropsEverything_unlessDeveloperMode() {
        XCTAssertFalse(DGLogger.shouldPersist(level: .error, developerMode: false, diagnosticsEnabled: false))
        XCTAssertFalse(DGLogger.shouldPersist(level: .warning, developerMode: false, diagnosticsEnabled: false))
        // Developer mode is an explicit opt-in to full logging — it overrides the opt-out.
        XCTAssertTrue(DGLogger.shouldPersist(level: .info, developerMode: true, diagnosticsEnabled: false))
    }

    func testGate_developerMode_recordsAllLevels() {
        for level: LogLevel in [.debug, .info, .notice, .warning, .error] {
            XCTAssertTrue(DGLogger.shouldPersist(level: level, developerMode: true, diagnosticsEnabled: true))
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

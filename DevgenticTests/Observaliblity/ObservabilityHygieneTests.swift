// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ObservabilityHygieneTests.swift
//  devgenticTests
//
//  Two pre-existing P1s that had ZERO coverage: the log SUBSYSTEM string (29 sites logged under
//  an identifier the app does not have, so Console filtering silently missed them) and the
//  diagnostic-bundle ALLOWLIST (the control deciding what leaves the user's machine).
//

import XCTest
@testable import devgentic

final class LogSubsystemTests: XCTestCase {

    /// The constant must BE the app, not a lookalike. The bundle identifier is `app.devgentic.macos`
    /// while 29 sites hardcoded `"com.devgentic"` — a string that matches nothing, so
    /// `log stream --predicate 'subsystem == "app.devgentic.macos"'` returned none of them.
    func testSubsystemIsTheRealBundleIdentifier() {
        XCTAssertEqual(DGLogger.subsystem, Bundle.main.bundleIdentifier,
                       "the subsystem must be the running bundle, never a literal")
        XCTAssertFalse(DGLogger.subsystem.isEmpty)
    }

    /// A DGLogger created the normal way inherits it.
    func testDGLoggerDefaultsToTheSharedSubsystem() {
        XCTAssertEqual(DGLogger(category: "Test").subsystem, DGLogger.subsystem)
    }

    /// ⚠️ THE DRIFT GUARD, and the point of the exercise. Sweeping 34 call sites is worthless if
    /// the 35th retypes the literal — which is exactly how the original 29 accumulated. Scans the
    /// real source tree (located from this file's own compile-time path) and fails on any
    /// `Logger(subsystem:)` that is not routed through `DGLogger.subsystem`.
    func testNoSourceFileHardcodesALogSubsystem() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        // …/DevgenticTests/Observaliblity/ThisFile.swift → repo root
        let repoRoot = testFile.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sourceRoot = repoRoot.appendingPathComponent("Devgentic")
        guard FileManager.default.fileExists(atPath: sourceRoot.path) else {
            throw XCTSkip("source tree not reachable from \(sourceRoot.path)")
        }

        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.contains("Logger(subsystem:") else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }   // doc/comment
                if line.contains("DGLogger.subsystem") { continue }                    // routed
                if line.contains("subsystem: String = DGLogger.subsystem") { continue } // the init
                if url.lastPathComponent == "DGLogger.swift" { continue }              // the definition
                offenders.append("\(url.lastPathComponent):\(i + 1): \(trimmed)")
            }
        }

        XCTAssertTrue(offenders.isEmpty,
                      "every Logger must take DGLogger.subsystem — offenders:\n" + offenders.joined(separator: "\n"))
    }
}

final class DiagnosticBundleAllowlistTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "allowlist-tests-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    /// ⚠️ THE ACTUAL PRIVACY ASSERTION, which did not exist. The allowlist's own comment promises
    /// "anything not in this set does NOT appear in the bundle" — this seeds a store with secrets
    /// alongside allowlisted values and proves the promise, rather than reading the list and
    /// trusting the writer to honour it.
    func testSecretsSeededAlongsideAllowlistedKeysNeverReachTheSnapshot() {
        defaults.set(true, forKey: AppSettings.developerModeKey)          // allowlisted
        defaults.set("sk-live-SUPERSECRET", forKey: "anthropicAPIKey")    // must never export
        defaults.set("ghp_tokenvalue", forKey: "githubToken")
        defaults.set("hunter2", forKey: "userPassword")
        defaults.set("/Users/alice/private/notes.md", forKey: "lastOpenedFilePath")

        let snapshot = BundleExporter.exportablePreferenceSnapshot(from: defaults)

        XCTAssertTrue(snapshot.keys.contains(AppSettings.developerModeKey),
                      "an allowlisted key must still be exported")
        for secret in ["anthropicAPIKey", "githubToken", "userPassword", "lastOpenedFilePath"] {
            XCTAssertFalse(snapshot.keys.contains(secret),
                           "\(secret) is not allowlisted and must not leave the machine")
        }
        XCTAssertTrue(Set(snapshot.keys).isSubset(of: Set(BundleExporter.exportablePreferenceKeys)),
                      "the snapshot may never contain a key outside the allowlist")
    }

    /// Absent keys are simply omitted — the bundle must not fabricate defaults for settings the
    /// user never touched.
    func testUnsetAllowlistedKeysAreOmittedNotDefaulted() {
        let snapshot = BundleExporter.exportablePreferenceSnapshot(from: defaults)
        XCTAssertTrue(snapshot.isEmpty, "nothing was set, so nothing should be reported")
    }

    /// The allowlist itself must not acquire a secret-shaped key. Guards the review step the
    /// list's own comment asks for ("review this list carefully when adding new keys").
    func testAllowlistContainsNothingSecretShaped() {
        let banned = ["key", "token", "secret", "password", "credential", "auth", "path"]
        for entry in BundleExporter.exportablePreferenceKeys {
            let lower = entry.lowercased()
            for word in banned where lower.contains(word) {
                XCTFail("allowlisted preference '\(entry)' looks secret- or path-bearing (matched '\(word)') — review before exporting it")
            }
        }
    }

    /// A non-empty, de-duplicated list. A duplicate is a review smell and an empty list would make
    /// every other assertion here vacuously true.
    func testAllowlistIsNonEmptyAndUnique() {
        let keys = BundleExporter.exportablePreferenceKeys
        XCTAssertFalse(keys.isEmpty)
        XCTAssertEqual(Set(keys).count, keys.count, "duplicate entries in the allowlist")
    }
}

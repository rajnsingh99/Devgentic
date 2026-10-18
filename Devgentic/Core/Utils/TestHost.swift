// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TestHost.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Detects whether the process is an XCTest host (the test host runs the real app's launch code in full).
/// Detection uses the `XCTestCase` class, not an environment variable, so misconfigured runs are caught too.
enum TestHost {

    /// True when an XCTest bundle is loaded into this process.
    /// Computed, not cached: a lazy `static let` could be first read before the test bundle loads.
    static var isRunning: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// Refuses a side-effecting launch step when running under tests, and logs it once.
    /// `step` names what is skipped, for the log; returns true when the caller should proceed.
    /// Refuse rather than redirect: outward side effects (hotkeys, microphone, `npx`, LLM spend) have no test value.
    static func permits(_ step: String, logger: DGLogger) -> Bool {
        guard isRunning else { return true }
        logger.error("[TESTHOST] Refused to \(step) because this process is an XCTest host. CONSEQUENCE: the step did not run — deliberately. The test host is the real app, so without this it would have taken a REAL side effect on the developer's own machine during an ordinary `test-without-building` run.")
        return false
    }

    // MARK: - Defaults redirect

    /// `UserDefaults.standard`, or an isolated suite when running under XCTest.
    /// A real suite rather than a stub, so settings round-trip but never touch the user's own domain.
    /// Computed, never cached by a caller: an early read could pin `.standard` before the test bundle loads.
    static var defaults: UserDefaults {
        isRunning ? testHostSuite : .standard
    }

    // Why: the suite name includes the pid because a shared name let concurrent test hosts wipe each other's settings.
    /// Wiped once per process, so each run starts from a genuinely empty domain.
    private static let testHostSuite: UserDefaults = {
        let name = defaultsSuiteName
        removeStaleSuites()
        guard let suite = UserDefaults(suiteName: name) else {
            // Falling back to `.standard` silently restores the leak this isolation closes, so the failure is logged.
            DGLogger(category: "TestHost").error("[TESTHOST] Could not open the isolated defaults suite '\(name)'. CONSEQUENCE: settings reads fall back to UserDefaults.standard, which under a test host is the developer's REAL app domain — tests will see their machine's settings and may overwrite them.")
            return .standard
        }
        suite.removePersistentDomain(forName: name)
        return suite
    }()

    static let defaultsSuitePrefix = "devgentic.testhost.defaults"

    /// This process's isolated domain.
    static var defaultsSuiteName: String {
        "\(defaultsSuitePrefix).\(ProcessInfo.processInfo.processIdentifier)"
    }

    /// Domains to delete from `~/Library/Preferences`: those of test hosts that have exited
    /// (every run leaves one behind), and the old shared, unsuffixed one. Pure, for tests.
    static func staleSuiteNames(amongPreferenceFiles fileNames: [String], isAlive: (pid_t) -> Bool) -> [String] {
        fileNames.compactMap { file -> String? in
            guard file.hasSuffix(".plist") else { return nil }
            let domain = String(file.dropLast(".plist".count))
            if domain == defaultsSuitePrefix { return domain }
            guard domain.hasPrefix(defaultsSuitePrefix + "."),
                  let pid = pid_t(domain.dropFirst(defaultsSuitePrefix.count + 1)) else { return nil }
            return isAlive(pid) ? nil : domain
        }
    }

    private static func removeStaleSuites() {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let preferences = library.appendingPathComponent("Preferences", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        // `kill(pid, 0)` probes without signalling; EPERM still means the process exists.
        let stale = staleSuiteNames(amongPreferenceFiles: files) { kill($0, 0) == 0 || errno == EPERM }
        for domain in stale {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: preferences.appendingPathComponent(domain + ".plist"))
        }
    }
}

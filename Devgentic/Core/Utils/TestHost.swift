// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TestHost.swift
//  Devgentic
//
//  Whether this process is an XCTest host.
//
//  ⚠️⚠️ THE XCTEST HOST *IS* THE REAL APP, AND THAT IS NOT A FIGURE OF SPEECH. `DevgenticApp.init`
//  and `applicationDidFinishLaunching` run in full on every `test-without-building` invocation,
//  whatever the tests themselves do. Verified empirically on 2026-09-11: fifteen consecutive runs
//  each executed the ChatOps bootstrap. A comment telling future authors not to construct something
//  protects nothing, because the app constructs it before any test is named.
//
//  ⚠️ ONE DEFINITION, BECAUSE THE LITERAL WAS ALREADY SPREADING. `NSClassFromString("XCTestCase")`
//  was retyped at `TraceStore.swift:67`, `:104` and `ChatOpsCoordinator.swift:102`. Three copies of a
//  magic string is exactly how 29 hardcoded log subsystems accumulated, and the failure mode here is
//  worse than a missed log line: a site that spells it slightly differently silently stops guarding.
//
//  ⚠️ NOT AN ENVIRONMENT VARIABLE, DELIBERATELY. `XCTestConfigurationFilePath` and friends are set by
//  the runner, so a scheme that forgets one, a direct binary launch, or a differently-configured CI
//  job all read as "not a test" — and this must fire even when the run is misconfigured, because a
//  misconfigured run is precisely when nobody is watching. The class is loaded by the test bundle
//  itself, so it cannot be absent when tests are executing.
//
//  ⚠️ NOT `#if DEBUG`, and the asymmetry with `TraceStore`'s own flag is the reason. That one is
//  compiled out because it GRANTS something (an env-supplied store path a shipped app must never
//  honour). Everything gated here only ever REFUSES, so leaving it compiled in costs one nil check at
//  launch and removes any chance of a Release-only side effect. `XCTestCase` cannot load in a
//  shipped app, so the check is simply false there.
//

import Foundation

enum TestHost {

    /// True when an XCTest bundle is loaded into this process.
    ///
    /// ⚠️ Computed, not cached in a `let`: a `static let` is lazy and its first read could be
    /// ordered before the test bundle loads. The lookup is a dictionary hit in the ObjC runtime and
    /// runs at launch, not in a loop.
    static var isRunning: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// Refuses a side-effecting launch step when running under tests, and says so once.
    ///
    /// ⚠️⚠️ REFUSE, NOT REDIRECT — for these steps specifically. A redirect is right for PERSISTENCE
    /// (the store already redirects, and a test that writes rows is a test worth having). It is wrong
    /// for an outward side effect: there is no useful "test version" of stealing a system-wide
    /// hotkey, opening the microphone, spawning `npx` with the developer's environment, or spending
    /// money on an LLM turn. Those have no test value at all, so the honest guard is a refusal.
    ///
    /// - Parameter step: what is being skipped, for the log.
    /// - Returns: true when the caller should proceed.
    static func permits(_ step: String, logger: DGLogger) -> Bool {
        guard isRunning else { return true }
        logger.error("[TESTHOST] Refused to \(step) because this process is an XCTest host. CONSEQUENCE: the step did not run — deliberately. The test host is the real app, so without this it would have taken a REAL side effect on the developer's own machine during an ordinary `test-without-building` run.")
        return false
    }

    // MARK: - Defaults redirect

    /// `UserDefaults.standard`, or an isolated suite when running under XCTest.
    ///
    /// ⚠️⚠️ REDIRECT, not refuse — settings are PERSISTENCE, which `permits` above names as the
    /// case a redirect is right for. A test that reads a setting is a test worth having; it just
    /// must not read the developer's own.
    ///
    /// Field-observed 2026-09-20: nine `OrbWakeWordTests` failed on the author's machine and
    /// passed everywhere else. The test host IS the shipping app, so `UserDefaults.standard` is
    /// the real `app.devgentic.macos` domain — where the author had set a custom wake word. The
    /// tests exercise the NO-ARGUMENT call shape on purpose (that is the wiring coverage: an
    /// explicit argument would still pass if the setting were disconnected), so they can only be
    /// correct when "unset" genuinely means unset.
    ///
    /// ⚠️ A REAL suite, not a stub. `OrbConfigManager` writes settings and reads them back, so the
    /// round-trip has to work — what must not survive is the write reaching the user's domain, or
    /// their value reaching the test.
    ///
    /// ⚠️ Computed, never cached by a caller in a `let`. Same ordering hazard as `isRunning`: a
    /// stored property resolved during app launch could be evaluated before the test bundle loads
    /// and pin `.standard` for the whole run.
    static var defaults: UserDefaults {
        isRunning ? testHostSuite : .standard
    }

    /// Wiped once per process, so each run starts from a genuinely empty domain — otherwise a
    /// value written by one test would be "already configured" for the next run's defaults tests.
    private static let testHostSuite: UserDefaults = {
        let name = "devgentic.testhost.defaults"
        guard let suite = UserDefaults(suiteName: name) else {
            // ⚠️ Falling back to `.standard` would silently restore the exact leak this exists to
            // close, so say so — a mysteriously-failing settings test is the symptom.
            DGLogger(category: "TestHost").error("[TESTHOST] Could not open the isolated defaults suite '\(name)'. CONSEQUENCE: settings reads fall back to UserDefaults.standard, which under a test host is the developer's REAL app domain — tests will see their machine's settings and may overwrite them.")
            return .standard
        }
        suite.removePersistentDomain(forName: name)
        return suite
    }()
}

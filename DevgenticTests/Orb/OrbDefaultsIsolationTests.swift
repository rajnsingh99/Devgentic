// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbDefaultsIsolationTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class OrbDefaultsIsolationTests: XCTestCase {

    // MARK: - The redirect is real

    func testTheDefaultsStoreIsNotTheUsersUnderATestHost() {
        XCTAssertTrue(TestHost.isRunning, "this assertion is meaningless outside a test host")
        XCTAssertNotEqual(
            TestHost.defaults, UserDefaults.standard,
            "TestHost.defaults resolved to the shipping app's own domain. Every Orb settings test "
            + "is now reading — and writing — the developer's real configuration."
        )
    }

    func testWritesDoNotReachTheUsersDomain() {
        // The sharpest form: write through the manager, then look for it where it must NOT be.
        let key = AppSettings.orbWakeWordKey
        let userValueBefore = UserDefaults.standard.object(forKey: key)

        // ⚠️ No hyphen: `sanitizedWakeWord` drops everything that is not a letter, number or
        // space, so "zephyr-probe" reads back as "zephyr probe". Documented behaviour — but a
        // probe value that trips it makes this test look like an isolation failure when it is not.
        //
        // ⚠️⚠️ RESTORE WHAT WAS THERE, never a blank. This `defer` used to assign "" — which is
        // harmless while the redirect holds, and destroys the developer's configured wake word the
        // moment it does not. Proven on 2026-09-20: mutating `OrbConfigManager.defaults` back to
        // `.standard` to verify this very test made its own cleanup overwrite the author's real
        // setting with an empty string. A test that only behaves when the thing it tests is
        // working is not a safe test.
        //
        // ⚠️ And restore ABSENCE as absence. Restoring through `wakeWordRaw` wrote "" when nothing
        // was set (its getter reads unset as ""), which leaves exactly the stored key that
        // `testAnUnsetWakeWordMeansTheDefault` asserts is not there.
        let store = TestHost.defaults
        let previous = store.object(forKey: key)
        OrbConfigManager.shared.wakeWordRaw = "zephyrprobe"
        defer {
            if let previous { store.set(previous, forKey: key) } else { store.removeObject(forKey: key) }
        }

        XCTAssertEqual(OrbConfigManager.shared.wakeWord, "zephyrprobe",
                       "the write must still round-trip — an isolated store is not a disabled one")
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: key) as? String, userValueBefore as? String,
            "the write reached UserDefaults.standard, which under a test host is the developer's "
            + "real Orb configuration. Their wake word has just been overwritten by a test."
        )
    }

    /// Two test hosts at once must not share a settings domain — see `TestHost.testHostSuite`.
    func testEachTestHostProcessHasItsOwnDefaultsDomain() {
        XCTAssertTrue(TestHost.defaultsSuiteName.hasSuffix(".\(ProcessInfo.processInfo.processIdentifier)"))
        let key = "testhost.isolation.probe.\(UUID().uuidString)"
        TestHost.defaults.set("mine", forKey: key)
        defer { TestHost.defaults.removeObject(forKey: key) }
        XCTAssertEqual(UserDefaults(suiteName: TestHost.defaultsSuiteName)?.string(forKey: key), "mine",
                       "TestHost.defaults is not the per-process domain its name claims")
        XCTAssertNil(UserDefaults(suiteName: TestHost.defaultsSuitePrefix)?.string(forKey: key),
                     "a write reached the old machine-wide domain other test hosts read")
    }

    func testOnlyExitedHostsDomainsAreSwept() {
        let live: pid_t = 100, dead: pid_t = 200
        let prefix = TestHost.defaultsSuitePrefix
        let files = ["\(prefix).plist", "\(prefix).\(live).plist", "\(prefix).\(dead).plist",
                     "app.devgentic.macos.plist", "\(prefix).notapid.plist", "\(prefix).\(dead).lockfile"]
        XCTAssertEqual(TestHost.staleSuiteNames(amongPreferenceFiles: files) { $0 == live },
                       [prefix, "\(prefix).\(dead)"],
                       "a live host's domain, the app's own and unrelated files must never be swept")
    }

    func testAnUnsetWakeWordMeansTheDefault() {
        // ⚠️ THE REGRESSION GUARD for the nine failures. This is the assumption every no-argument
        // wake-word test rests on, asserted directly instead of implied.
        XCTAssertNil(TestHost.defaults.object(forKey: AppSettings.orbWakeWordKey),
                     "the isolated suite already carries a wake word, so 'unset' is not clean")
        XCTAssertEqual(OrbSessionController.wakeWord, OrbConfigManager.defaultWakeWord)
    }

    // MARK: - Nothing in Orb may reach around the seam

    /// ⚠️ A SOURCE SCAN, deliberately. A behavioural test can only cover the paths it happens to
    /// call; the leak was one `let` in one file, and the next one will be somewhere else. The
    /// invariant is structural — nothing under `Devgentic/Orb/` touches the global domain — so the
    /// check is structural too. Same shape as `ToolRegistryDriftTests`.
    func testNoOrbSourceReadsTheGlobalDefaultsDomain() throws {
        var offenders: [String] = []

        for relative in try Self.orbSourceFiles() {
            let source = try Self.read(relative)
            for line in source.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                if trimmed.contains("UserDefaults.standard") {
                    offenders.append("\(relative): \(trimmed.prefix(100))")
                }
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            \(offenders.count) Orb source line(s) read UserDefaults.standard directly:

              \(offenders.joined(separator: "\n  "))

            Under a test host that is the developer's own settings domain. Route them through \
            `TestHost.defaults`, which is `.standard` in the app and an isolated suite under XCTest.
            """)
    }

    /// Non-vacuity: a scan that found no files passes while checking nothing — the same shape as
    /// the empty-Resources bug this suite hit earlier the same day.
    func testTheSourceScanActuallyReadsFiles() throws {
        let files = try Self.orbSourceFiles()
        XCTAssertGreaterThan(files.count, 5, "only \(files.count) Orb sources found — the scan above is vacuous")
        let manager = try Self.read("Devgentic/Orb/OrbConfigManager.swift")
        XCTAssertTrue(manager.contains("var wakeWord"), "read the wrong file")
    }

    // MARK: - Source access

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Orb
            .deletingLastPathComponent()   // DevgenticTests
            .deletingLastPathComponent()   // repo root
    }

    private static func orbSourceFiles() throws -> [String] {
        let orb = repoRoot().appendingPathComponent("Devgentic/Orb")
        guard let e = FileManager.default.enumerator(at: orb, includingPropertiesForKeys: nil) else {
            throw XCTSkip("Devgentic/Orb not reachable — running outside a checkout")
        }
        return e.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { "Devgentic/Orb/" + $0.lastPathComponent }
            .sorted()
    }

    private static func read(_ relativePath: String) throws -> String {
        let url = repoRoot().appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("\(relativePath) not reachable — running outside a checkout")
        }
        return text
    }
}

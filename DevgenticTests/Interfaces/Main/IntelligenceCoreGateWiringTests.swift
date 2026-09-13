// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  IntelligenceCoreGateWiringTests.swift
//  DevgenticTests
//
//  The Core Intelligence toggle turned the UI on and nothing else.
//
//  `MainApplicationViewModel.isIntelligenceCoreEnabled` was a STORED var. Eleven consumers —
//  MorningBriefService, UserPersonalService, AgentConnect, BackendOrchestrationService and both
//  Welcome widgets among them — gate on `UserDefaults.bool(forKey: isIntelligenceCoreEnabledKey)`.
//  The only thing that wrote that key was `SettingsCoordinator.didChangeIntelligenceCoreEnabled`,
//  which had ZERO callers, and the `AnyCancellable` meant to bridge them was declared and never
//  assigned. So the settings pane revealed its model picker and debug card while every gate still
//  read false, and Run Morning Brief logged:
//
//      [Morning Brief] Gate check FAILED — IC enabled: false, Brief enabled: true, Model selected: true
//
//  ⚠️ These are source tests because `MainApplicationViewModel` cannot be constructed in a unit
//  test — its init builds the app's service graph. The invariant is structural anyway: the control
//  must write the same store the gates read, with no second copy in between.
//

import XCTest
@testable import devgentic

final class IntelligenceCoreGateWiringTests: XCTestCase {

    private static let viewModel = "Devgentic/Interfaces/Main/MainApplicationViewModel.swift"
    private static let coordinator = "Devgentic/Interfaces/Main/SettingsCoordinator.swift"

    /// ⚠️ THE DEFECT ITSELF. A stored property holds the toggle's value in memory where no gate
    /// can see it.
    func testTheToggleIsNotBackedByAStoredCopy() throws {
        let vm = try Self.source(Self.viewModel)
        XCTAssertFalse(vm.contains("var isIntelligenceCoreEnabled: Bool = false"), """
            Stored again. The settings toggle binds this property; every gate reads UserDefaults. \
            A stored copy means the switch changes the UI and nothing else.
            """)
        XCTAssertFalse(vm.contains("var useStreamingResponse: Bool = true"),
                       "same defect, same shape — it silently reverted on every relaunch")
    }

    /// The control must write the key the gates read.
    func testTheToggleWritesTheKeyTheGatesRead() throws {
        let vm = try Self.source(Self.viewModel)
        XCTAssertTrue(vm.contains("UserDefaults.standard.set(newValue, forKey: AppSettings.isIntelligenceCoreEnabledKey)"),
                      "the setter must persist to the key every consumer gates on")
        XCTAssertTrue(vm.contains("access(keyPath: \\.isIntelligenceCoreEnabled)"), """
            A computed property gets no observation for free. Without `access` the getter reads \
            correctly and never invalidates a view, so the toggle would stop moving.
            """)
        XCTAssertTrue(vm.contains("withMutation(keyPath: \\.isIntelligenceCoreEnabled)"))
    }

    /// ⚠️ EXACTLY ONE WRITER. The bug was two persistence paths where only one was wired; a second
    /// writer re-opens that shape.
    func testThereIsExactlyOneWriterOfTheIntelligenceCoreKey() throws {
        let writers = try Self.writeSites(forKeyNamed: "isIntelligenceCoreEnabledKey")
        XCTAssertEqual(writers.count, 1, "expected only the property setter, found: \(writers)")
        XCTAssertTrue(writers[0].hasSuffix("MainApplicationViewModel.swift"))
    }

    /// Streaming allows a second writer — and only one: the first-launch seed.
    ///
    /// ⚠️ That seed is load-bearing and must NOT be removed. `WorkflowPreferenceSource` reads this
    /// key directly with `bool(forKey:)`, which returns false for an absent key — the opposite of
    /// the shipped default, so without the seed a fresh install would disagree with the toggle.
    func testStreamingHasOnlyTheSetterAndTheFirstLaunchSeed() throws {
        let writers = try Self.writeSites(forKeyNamed: "useStreamingResponseKey")
        XCTAssertEqual(writers.count, 2, "expected the setter and the seed, found: \(writers)")
        XCTAssertTrue(try Self.source(Self.coordinator)
            .contains("UserDefaults.standard.set(true, forKey: AppSettings.useStreamingResponseKey)"),
            "the first-launch seed is what keeps direct readers agreeing with the default-true getter")
    }

    /// The dead hooks must not come back — they were the second, unwired path.
    /// ⚠️ CODE ONLY, COMMENTS STRIPPED. The replacement comments at both sites deliberately NAME
    /// the removed symbols to explain why they are gone, so a raw `contains` check fails on its
    /// own explanation — the same trap that bit the regex-count assertion in MLXStoreAuditFixTests.
    func testTheUnwiredPersistenceHooksAreGone() throws {
        let coordinator = try Self.code(Self.coordinator)
        XCTAssertFalse(coordinator.contains("func didChangeIntelligenceCoreEnabled()"))
        XCTAssertFalse(coordinator.contains("func didChangeUseStreamingResponse()"))
        let vm = try Self.code(Self.viewModel)
        XCTAssertFalse(vm.contains("useStreamingResponseObserver"), """
            This AnyCancellable was declared and never assigned — the Combine bridge that was \
            supposed to persist these toggles never existed.
            """)
        XCTAssertFalse(vm.contains("intelligenceCoreObserver"))
    }

    /// Disabling must still release the model — that behaviour lived in the deleted hook.
    func testDisablingStillUnloadsTheModel() throws {
        let vm = try Self.source(Self.viewModel)
        XCTAssertTrue(vm.contains("IntelligenceCoreService.shared.unloadNow(caller: .unknown)"),
                      "switching off must release an expensive idle MLX model")
    }

    /// The gates and the toggle must name the SAME key — the whole invariant in one assertion.
    func testEveryGateReadsTheKeyTheToggleWrites() throws {
        for path in [
            "Devgentic/Intelligence/MorningBrief/MorningBriefService.swift",
            "Devgentic/Intelligence/UserPersonal/UserPersonalService.swift",
            "Devgentic/Interfaces/Main/Views/WelcomeWidgets/MorningBriefWidget.swift",
            "Devgentic/Interfaces/Main/Views/WelcomeWidgets/UserPersonalWidget.swift",
        ] {
            XCTAssertTrue(try Self.source(path)
                .contains("bool(forKey: AppSettings.isIntelligenceCoreEnabledKey)"),
                "\(path) must gate on the same key the toggle writes")
        }
    }

    // MARK: - Helpers

    private static func repoRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Interfaces/Main
            .deletingLastPathComponent()   // …/Interfaces
            .deletingLastPathComponent()   // …/DevgenticTests
            .deletingLastPathComponent()   // repo root
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("repo root not reachable from \(#filePath) — running outside a checkout")
        }
        return root
    }

    /// `source` with comment-only lines removed, for assertions about what the code DOES.
    private static func code(_ relativePath: String) throws -> String {
        try source(relativePath)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = try repoRoot().appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("\(relativePath) no longer exists. A drift test guards this file by path; repoint it rather than letting the guard go silent.")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every `UserDefaults…set(…forKey: AppSettings.<key>)` under `Devgentic/`, as file paths.
    private static func writeSites(forKeyNamed key: String) throws -> [String] {
        let root = try repoRoot().appendingPathComponent("Devgentic")
        var hits: [String] = []
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("forKey: AppSettings.\(key)") {
                if line.contains(".set(") { hits.append(url.path) }
            }
        }
        return hits.sorted()
    }
}

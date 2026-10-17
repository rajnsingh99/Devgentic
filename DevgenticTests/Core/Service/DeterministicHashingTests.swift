// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DeterministicHashingTests.swift
//  devgenticTests
//
//  The app runs with SWIFT_DETERMINISTIC_HASHING=1 so MLX chat-template prompts render the same
//  bytes for the same request (see DeterministicHashing.swift). These pin the two launch paths
//  that set it and the self-check that reports whether a launch got it.
//
//  ⚠️ The Test action deliberately sets the variable to "0" — the test host launches through
//  LaunchServices and would otherwise inherit LSEnvironment — so this process normally sees random
//  per-instance order. The self-check test holds in either configuration.
//

import XCTest
@testable import devgentic

final class DeterministicHashingTests: XCTestCase {

    private var environmentSaysOn: Bool {
        ProcessInfo.processInfo.environment[DeterministicHashing.environmentKey] == "1"
    }

    // MARK: - The self-check

    func testSelfCheckMatchesThisProcess() {
        XCTAssertEqual(DeterministicHashing.isInEffect(), environmentSaysOn,
                       "the launch log would report the wrong state for this process")
    }

    func testSamplerSeesRandomOrderWhenTheVariableIsAbsent() throws {
        // Guards the sampler itself: one that reused a single instance, or dropped each
        // dictionary before building the next, would report "stable" in every process.
        try XCTSkipIf(environmentSaysOn, "only observable without the variable")
        XCTAssertFalse(DeterministicHashing.ordersAgree(DeterministicHashing.sampleIterationOrders()),
                       "8 live dictionaries with 32 equal keys iterated identically without deterministic hashing")
    }

    func testOrdersAgree() {
        XCTAssertTrue(DeterministicHashing.ordersAgree([["a", "b"], ["a", "b"]]))
        XCTAssertFalse(DeterministicHashing.ordersAgree([["a", "b"], ["b", "a"]]))
    }

    // MARK: - The wiring

    func testBuiltInfoPlistSetsItForLaunchServicesLaunches() {
        // The BUILT plist: Info.plist is merged with generated keys, so the source file alone
        // proves nothing (see the note at the top of Devgentic/Info.plist).
        let environment = Bundle.main.infoDictionary?["LSEnvironment"] as? [String: String]
        XCTAssertEqual(environment?[DeterministicHashing.environmentKey], "1",
                       "Finder / Dock / Sparkle launches would render a new <tools> order every MLX turn")
    }

    func testSchemeTurnsItOnForXcodeRunsAndOffForTests() throws {
        let scheme = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "Devgentic.xcodeproj/xcshareddata/xcschemes/devgentic.xcscheme"), encoding: .utf8)
        let launch = try XCTUnwrap(Self.section("LaunchAction", in: scheme))
        let test = try XCTUnwrap(Self.section("TestAction", in: scheme))

        func entry(_ value: String) -> String {
            #"key = "SWIFT_DETERMINISTIC_HASHING"\s+value = ""# + value + #""\s+isEnabled = "YES""#
        }
        XCTAssertNotNil(launch.range(of: entry("1"), options: .regularExpression),
                        "Xcode's Run ignores LSEnvironment; without the scheme entry it runs with random order")
        XCTAssertNotNil(test.range(of: entry("0"), options: .regularExpression),
                        "the test host would inherit LSEnvironment: tests stop seeing the library's own "
                        + "behaviour, which masks a dependency probe and hides order-dependent bugs")
    }

    func testLaunchReportsWhetherItTookEffect() throws {
        // The only signal that a launch missed both paths (e.g. the binary run from a terminal).
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent("Devgentic/AppDelegate.swift"), encoding: .utf8)
        let launch = try XCTUnwrap(source.range(of: "func applicationDidFinishLaunching"))
        let body = source[launch.upperBound...].prefix(4_000)
        XCTAssertTrue(body.contains("DeterministicHashing.logLaunchStatus()"),
                      "applicationDidFinishLaunching no longer logs whether deterministic hashing is on")
    }

    // MARK: - Helpers

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Service
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // devgenticTests
            .deletingLastPathComponent()   // repo root
    }

    private static func section(_ element: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(element)"),
              let end = xml.range(of: "</\(element)>", range: start.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[start.lowerBound..<end.upperBound])
    }
}

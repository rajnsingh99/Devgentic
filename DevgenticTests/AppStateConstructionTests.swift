// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AppStateConstructionTests.swift
//  DevgenticTests
//
//  Pins how `DevgenticApp.init()` builds its long-lived `@State` objects.
//
//  ⚠️ THE DEFECT CLASS, seen twice: reading `self._x.wrappedValue` inside the App's `init()`
//  returns the initial value of THAT evaluation of the struct, which is not necessarily the
//  instance SwiftUI keeps.
//  - CodeSessionManager: two live managers. The view model read the blank one, and the Code system
//    prompt was never applied.
//  - BackendProfileService (2026-10-03): its `@State` default ran twice at launch — a second full
//    profile fetch and Keychain read per keyed profile — and `onProfileDeleted` was wired through
//    `self._backendProfileService.wrappedValue`.
//  The safe shape is the one `mainVM` uses: build a LOCAL, wire it, install it with
//  `State(wrappedValue:)`. This is a source check because SwiftUI's App storage cannot be driven
//  from a unit test.
//

import XCTest

final class AppStateConstructionTests: XCTestCase {

    private static func appSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DevgenticTests
            .deletingLastPathComponent()   // repo root
        let url = root.appendingPathComponent("Devgentic/DevgenticApp.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("DevgenticApp.swift not reachable — running outside a checkout")
        }
        return text
    }

    /// The App's `init()` body with comment lines removed, so the prose describing the defect
    /// cannot be mistaken for the code.
    private static func initBody(in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "init() {" }) else {
            return nil
        }
        var depth = 0
        var started = false
        var body: [String] = []
        for line in lines[start...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            depth += line.filter { $0 == "{" }.count
            depth -= line.filter { $0 == "}" }.count
            if depth > 0 { started = true }
            body.append(line)
            if started && depth == 0 { break }
        }
        return body.joined(separator: "\n")
    }

    func testInitNeverReadsAStateWrappedValue() throws {
        let body = try XCTUnwrap(Self.initBody(in: try Self.appSource()), "could not find DevgenticApp.init()")
        let reads = body.ranges(of: /self\._[A-Za-z0-9]+\.wrappedValue/).map { String(body[$0]) }
        XCTAssertTrue(reads.isEmpty,
                      "init() must build a local and install it with State(wrappedValue:) — got: \(reads)")
    }

    /// The wiring half: the service is installed from the local, and is not ALSO a property
    /// default (which would build a second instance on every evaluation of the struct).
    func testTheProfileServiceIsBuiltOnceAndInstalledFromALocal() throws {
        let source = try Self.appSource()
        let body = try XCTUnwrap(Self.initBody(in: source))
        XCTAssertTrue(body.contains("self._backendProfileService = State(wrappedValue:"),
                      "the service must be installed from the instance init() wired")
        XCTAssertFalse(source.contains("var backendProfileService = BackendProfileService()"),
                       "a @State default would be evaluated again for every App struct evaluation")
    }
}

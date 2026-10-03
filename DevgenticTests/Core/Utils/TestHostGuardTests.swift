// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TestHostGuardTests.swift
//  devgenticTests
//
//  The XCTest host IS the real app: `DevgenticApp.init` and `applicationDidFinishLaunching` run in
//  full on every `test-without-building` invocation, whatever the tests themselves do. Invariant 57
//  closed the ChatOps half; this file covers the rest of the launch path.
//
//  ⚠️⚠️ THIS SUITE IS UNUSUAL: IT RUNS INSIDE THE CONDITION IT DESCRIBES. `TestHost.isRunning` is
//  true here by definition, which makes `permits(...)` directly observable — and makes the
//  "unguarded" assertions below the strongest evidence available, because they are evaluated in
//  exactly the process the guards exist to protect.
//

import XCTest
@testable import devgentic

final class TestHostGuardTests: XCTestCase {

    // MARK: - The detector

    /// ⚠️ Evaluated in an XCTest host, so this must be true — and if it is ever false, every guard in
    /// the app is inert and this is the only test that would say so.
    func testTheDetectorFiresInsideATestHost() {
        XCTAssertTrue(TestHost.isRunning,
                      "the whole guard family depends on this; false here means nothing is protected")
    }

    /// ⚠️ COMPUTED, NOT A `static let`. A lazy `let` is initialized on first read, and that read
    /// could be ordered before the test bundle loads — after which it would stay false forever.
    func testTheDetectorIsNotCachedAtFirstRead() throws {
        let source = try readSource("Devgentic/Core/Utils/TestHost.swift")
        XCTAssertFalse(source.contains("static let isRunning"),
                       "a lazy `static let` can be initialized before the test bundle loads and then "
                       + "report false for the life of the process")
        XCTAssertTrue(source.contains("static var isRunning"))
    }

    /// `permits` refuses here, because here IS a test host.
    func testPermitsRefusesInsideATestHost() {
        XCTAssertFalse(TestHost.permits("do something outward", logger: DGLogger(category: "TestHostGuardTests")),
                       "a side-effecting launch step must not run in a test host")
    }

    // MARK: - The literal does not spread

    /// ⚠️ THE DRIFT GUARD, and the reason the helper exists at all. `NSClassFromString("XCTestCase")`
    /// was already retyped at three sites before it was extracted. A magic string spreading is how 29
    /// hardcoded log subsystems accumulated — and here a site that spells it slightly differently
    /// does not merely log oddly, it silently stops guarding.
    ///
    /// ⚠️ Comment-blind: the prose in `TestHost.swift` names the literal deliberately.
    func testNoSourceFileRetypesTheTestHostLiteral() throws {
        var offenders: [String] = []
        for url in swiftFiles(under: "Devgentic") {
            guard url.lastPathComponent != "TestHost.swift" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if stripComments(text).contains("NSClassFromString(\"XCTestCase\")") {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "these files retype the test-host literal instead of calling TestHost: \(offenders)")
    }

    // MARK: - The launch path is actually guarded

    /// ⚠️ THE WIRING, ONE ROW PER REAL-WORLD COST. Each of these ran unguarded on every test run, and
    /// each is a side effect with no test value: there is no useful "test version" of stealing a
    /// system-wide hotkey, opening the microphone, or spending money on an LLM turn.
    func testEveryOutwardLaunchEffectConsultsTheGuard() throws {
        let required: [(file: String, symbol: String, why: String)] = [
            ("Devgentic/Core/Service/Scheduler/SchedulerService.swift", "evaluateAndFireDueTasks",
             "fires overdue tasks — each one a REAL agent turn against the user's real API key"),
            ("Devgentic/Core/Service/Scheduler/SchedulerService.swift", "rescheduleAll",
             "arms timers that outlive the test which provoked them"),
            ("Devgentic/AppDelegate.swift", "applyHotkeyConfig",
             "registers ⌥Space system-wide, stealing it from the developer's own running app"),
            ("Devgentic/AppDelegate.swift", "applyOrbHotkeyConfig",
             "registers ⌥J system-wide — and ⌥J opens the microphone"),
            ("Devgentic/AppDelegate.swift", "setupStatusItem",
             "puts a live menu-bar item in the developer's menu bar"),
            ("Devgentic/Interfaces/Main/Views/Tooling/Mcp/MCPConnectionCoordinator.swift", "connectEnabledServersAtLaunch",
             "spawns child processes inheriting the full environment and reads the real login Keychain"),
            ("Devgentic/Observaliblity/CrashDiagnosticsCollector.swift", "purgeDiagnostics",
             "deletes the developer's real crash payloads"),
            ("Devgentic/Interfaces/Main/Views/Sidebar/Explorer/FileSystemMonitor.swift", "start",
             "opens an FSEventStream on the developer's real folder"),
        ]

        for entry in required {
            let body = try functionBody(named: entry.symbol, in: entry.file)
            XCTAssertTrue(body.contains("TestHost.permits"),
                          "\(entry.symbol) is unguarded — in a test host it \(entry.why)")
        }
    }

    /// ⚠️ The composer used to ASK for the microphone from `init` — a guard row here once covered it.
    /// The fix removed the prompt rather than guarding it: the composer is built at app scope, so the
    /// request raised the macOS microphone dialog on every first launch, before any voice use. The
    /// invariant is now "the init-path status sync never requests", with the request on the mic tap.
    func testBuildingTheComposerNeverRequestsTheMicrophone() throws {
        let file = "Devgentic/Interfaces/Shared/ChatInput/ChatInputViewModel.swift"
        let sync = try functionBody(named: "syncMicPermissionStatus", in: file)
        XCTAssertFalse(sync.contains("requestRecordPermission"),
                       "the init-path sync prompts again — the mic dialog is back on first launch")
        XCTAssertTrue(sync.contains("recordPermission"), "the reader returned a stub — it is not seeing the real body")

        // The request must still exist somewhere a user acts, or voice input could never be granted.
        // (A file scan, not `functionBody`: the file also declares a protocol `startStreaming(`.)
        let source = stripComments(try readSource(file))
        XCTAssertTrue(source.contains("requestRecordPermission"),
                      "nothing requests the microphone any more — an undetermined status can never become granted")
    }

    /// ⚠️ NON-VACUITY. Every assertion above is a substring scan, so a wrong path or a renamed symbol
    /// reads as "clean". This proves the reader can actually reach a body and see a guard absent.
    func testTheSourceScanCanTellGuardedFromUnguarded() throws {
        let guarded = try functionBody(named: "evaluateAndFireDueTasks",
                                       in: "Devgentic/Core/Service/Scheduler/SchedulerService.swift")
        XCTAssertTrue(guarded.contains("TestHost.permits"))
        XCTAssertGreaterThan(guarded.count, 120, "the reader returned a stub — it is not seeing real bodies")

        // A function that is deliberately NOT guarded: reading tasks has no outward effect.
        let unguarded = try functionBody(named: "loadAllTasks",
                                         in: "Devgentic/Core/Service/Scheduler/SchedulerService.swift")
        XCTAssertFalse(unguarded.contains("TestHost.permits"),
                       "loadAllTasks only READS; guarding it would hide the store from tests that "
                       + "legitimately exercise persistence — the redirect handles that case")
    }

    // MARK: - Redirection, where refusal would be wrong

    /// ⚠️⚠️ THE VECTOR STORE IS REDIRECTED, NOT REFUSED, AND THAT ASYMMETRY IS DELIBERATE. RAG tests
    /// legitimately open a store; what must never happen is a test host opening the USER'S. That one
    /// is an LMDB database holding an index with no reindex-from-transcripts path — it can only be
    /// moved back, never rebuilt — so a second process taking its lock during an ordinary
    /// `test-without-building` run is risk with no upside. This mirrors `TraceStore`, and closes the
    /// single gap the 2026-09-11 survey named against that convention.
    func testTheVectorStoreNeverResolvesToTheUsersRealStoreInATestHost() throws {
        let path = try VectorStoreService.storeDirectoryURL().path
        XCTAssertTrue(path.contains("testhost"),
                      "a test host resolved the REAL vector store at \(path)")
        XCTAssertFalse(path.contains("Application Support"),
                       "the real store lives under Application Support and must never be opened here")
    }

    /// Two stores in one process share a path, matching production topology — and differ between
    /// processes, so a parallel run cannot collide.
    func testTheRedirectedVectorStorePathIsStablePerProcess() throws {
        let a = try VectorStoreService.storeDirectoryURL().path
        let b = try VectorStoreService.storeDirectoryURL().path
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.contains("\(ProcessInfo.processInfo.processIdentifier)"))
    }

    // MARK: - Source access

    private func readSource(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<12 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw XCTSkip("Could not locate \(relativePath) from \(#filePath)")
    }

    private func swiftFiles(under relativeDir: String) -> [URL] {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<12 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent(relativeDir)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            var out: [URL] = []
            let e = FileManager.default.enumerator(at: candidate, includingPropertiesForKeys: nil)
            while let url = e?.nextObject() as? URL {
                if url.pathExtension == "swift" { out.append(url) }
            }
            return out
        }
        return []
    }

    private func functionBody(named name: String, in file: String) throws -> String {
        let source = stripComments(try readSource(file))
        guard let start = source.range(of: "func \(name)(") else {
            XCTFail("\(file) no longer declares func \(name)( — this test is blind")
            return ""
        }
        guard let open = source[start.upperBound...].firstIndex(of: "{") else { return "" }
        var depth = 0
        var i = open
        while i < source.endIndex {
            if source[i] == "{" { depth += 1 }
            if source[i] == "}" { depth -= 1; if depth == 0 { return String(source[open...i]) } }
            i = source.index(after: i)
        }
        return String(source[open...])
    }

    /// ⚠️ Every scan here goes through this. A comment-blind structural scan has produced a false
    /// verdict four times in this repository — and `TestHost.swift`'s own prose names the literal.
    private func stripComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let c = line.range(of: "//") else { return line }
                return line[line.startIndex..<c.lowerBound]
            }
            .joined(separator: "\n")
    }
}

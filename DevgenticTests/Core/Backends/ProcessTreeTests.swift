// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProcessTreeTests.swift
//  DevgenticTests
//
//  `zsh -c "xcodebuild …"` puts the compiler in a different process from the zsh. Signalling the
//  zsh alone left the build running, re-parented to launchd, while `command_stop` said "stopped".
//
//  ⚠️ These tests spawn real processes and signal them. Every one cleans up in `tearDown`, and a
//  leaked `sleep` would be visible as a slow suite rather than a silent cost.
//

import XCTest
@testable import devgentic

final class ProcessTreeTests: XCTestCase {

    private var spawned: [Process] = []

    override func tearDown() {
        for process in spawned where process.isRunning {
            ProcessTree.terminateTree(root: process.processIdentifier, grace: 0,
                                      isRootRunning: { process.isRunning })
        }
        spawned.removeAll()
        super.tearDown()
    }

    /// Runs `command` under zsh and returns (root process, the pid it recorded via `$!`).
    /// The grandchild writes its own pid so the test can ask the kernel about it directly rather
    /// than inferring liveness from the parent.
    private func spawnWithGrandchild() throws -> (root: Process, grandchild: pid_t) {
        let pidFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proctree-\(UUID().uuidString).pid")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "sleep 60 & echo $! > \(pidFile.path); wait"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        spawned.append(process)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                try? FileManager.default.removeItem(at: pidFile)
                return (process, pid)
            }
            usleep(20_000)
        }
        throw XCTSkip("the shell did not report its background pid in time")
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    private func waitUntilGone(_ pid: pid_t, within seconds: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isAlive(pid) { return true }
            usleep(20_000)
        }
        return !isAlive(pid)
    }

    // MARK: - Enumeration

    func testDescendantsFindsAGrandchild() throws {
        let (root, grandchild) = try spawnWithGrandchild()
        let found = ProcessTree.descendants(of: root.processIdentifier)

        XCTAssertTrue(found.contains(grandchild),
                      "the `sleep` under the shell was not found — a tree kill would leave it running")
    }

    func testDescendantsOfALeafIsEmpty() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        spawned.append(process)

        XCTAssertTrue(ProcessTree.descendants(of: process.processIdentifier).isEmpty)
    }

    /// ⚠️ 0 is the caller's own process group and 1 is launchd. Neither is ever a target, and
    /// `kill_process` has already paid for the version of this lesson where the guard was absent.
    func testNonPositiveAndInitPidsAreRefusedOutright() {
        XCTAssertTrue(ProcessTree.descendants(of: 0).isEmpty)
        XCTAssertTrue(ProcessTree.descendants(of: 1).isEmpty)
        XCTAssertTrue(ProcessTree.descendants(of: -1).isEmpty)

        // No signal is sent for these, so nothing can be asserted about a target — reaching the
        // `kill` at all would be the defect. Returning 0 is the observable proof it did not.
        XCTAssertEqual(ProcessTree.terminateTree(root: 0, grace: 0, isRootRunning: { true }), 0)
        XCTAssertEqual(ProcessTree.terminateTree(root: 1, grace: 0, isRootRunning: { true }), 0)
    }

    func testTheTestHostIsNotItsOwnDescendant() {
        XCTAssertFalse(ProcessTree.descendants(of: getpid()).contains(getpid()),
                       "a self-referential ppid would make a tree kill terminate the app")
    }

    // MARK: - The actual kill

    /// THE POINT OF THE FILE. Before `ProcessTree`, the shell died here and the `sleep` survived.
    func testTerminatingTheTreeKillsTheGrandchildNotJustTheShell() throws {
        let (root, grandchild) = try spawnWithGrandchild()
        XCTAssertTrue(isAlive(grandchild), "precondition: the grandchild is running")

        ProcessTree.terminateTree(root: root.processIdentifier, grace: 0,
                                  isRootRunning: { root.isRunning })

        XCTAssertTrue(waitUntilGone(grandchild),
                      "the sub-process outlived the kill — this is the defect where `command_stop` "
                      + "reported success while the build kept running")
        XCTAssertTrue(waitUntilGone(root.processIdentifier))
    }

    /// The two-phase quit API: one snapshot+TERM for every task, one shared grace, then KILL.
    func testTwoPhaseTerminationCoversDescendantsOfEveryRoot() throws {
        let first = try spawnWithGrandchild()
        let second = try spawnWithGrandchild()

        let signalled = ProcessTree.requestTermination(
            roots: [first.root.processIdentifier, second.root.processIdentifier])

        XCTAssertTrue(signalled.contains(first.grandchild))
        XCTAssertTrue(signalled.contains(second.grandchild))

        ProcessTree.forceTermination(signalled)

        XCTAssertTrue(waitUntilGone(first.grandchild))
        XCTAssertTrue(waitUntilGone(second.grandchild))
    }

    /// ⚠️ Phase 2 works from phase 1's LIST, never a fresh walk. By then the roots are dying and
    /// their children are re-parented to launchd, so a second walk finds nothing — which is the
    /// same reason `terminateTree` snapshots before it signals.
    func testPhaseTwoDoesNotDependOnTheTreeStillBeingIntact() throws {
        let (root, grandchild) = try spawnWithGrandchild()

        let signalled = ProcessTree.requestTermination(roots: [root.processIdentifier])
        XCTAssertTrue(waitUntilGone(root.processIdentifier), "the shell should die on SIGTERM")

        // The chain is gone now: the grandchild has been re-parented.
        XCTAssertFalse(ProcessTree.descendants(of: root.processIdentifier).contains(grandchild),
                       "precondition: a fresh walk can no longer find it")

        ProcessTree.forceTermination(signalled)
        XCTAssertTrue(waitUntilGone(grandchild),
                      "phase 2 re-walked instead of using phase 1's list, so the orphan survived")
    }

    func testRequestTerminationIgnoresNonPositiveRoots() {
        XCTAssertTrue(ProcessTree.requestTermination(roots: [0, 1, -1]).isEmpty)
    }

    // MARK: - The ordering invariant

    /// ⚠️⚠️ A STRUCTURAL GUARD, and why it is structural is the point.
    ///
    /// The snapshot must happen BEFORE any signal: kill the root first and its children are
    /// re-parented to launchd, losing the ppid chain that identifies them as ours. But inverting
    /// the order was MUTATION-TESTED AND SURVIVED every functional test in this file — SIGTERM
    /// does not kill a zsh instantly, so the walk still finds the child in the milliseconds
    /// before it dies. The defect is a RACE: real, and invisible to a test that runs once.
    ///
    /// Making it manifest would need either a flaky repeat-until-it-happens loop or a seam that
    /// exists only to be observed. Asserting the order in the source is neither, and it fails
    /// deterministically on exactly the edit that reintroduces the bug — the trade
    /// `ToolRegistryDriftTests` already makes for invariants the type system cannot hold.
    func testTheTreeIsSnapshottedBeforeAnythingIsSignalled() throws {
        let source = try Self.readSource()
        let body = try XCTUnwrap(Self.functionBody(named: "terminateTree", in: source),
                                 "could not find terminateTree — this guard is checking nothing")

        // ⚠️ Tracks the CAPTURE CALL, whatever it is currently named. This read
        // `descendants(of: root)` until the call was renamed to `liveTargets(…)` for the
        // remembered-descendant work, and then failed on a refactor that preserved the invariant
        // perfectly — a guard that pins a spelling instead of an ordering. `XCTUnwrap` keeps it
        // non-vacuous: if neither name is present it fails loudly rather than checking nothing.
        let snapshot = try XCTUnwrap(
            body.range(of: "liveTargets(") ?? body.range(of: "descendants(of: root)"),
            "terminateTree no longer captures the tree at all")
        let firstSignal = try XCTUnwrap(
            [body.range(of: "signal("), body.range(of: "kill(")].compactMap { $0 }.map(\.lowerBound).min(),
            "terminateTree no longer signals anything")

        XCTAssertLessThan(snapshot.lowerBound, firstSignal,
            "terminateTree signals before it snapshots the tree. Killing the root re-parents its "
            + "children to launchd, so the ppid chain that identifies them is gone by the time "
            + "the walk runs and they survive as orphans. This does NOT fail the behavioural "
            + "tests above — the root takes milliseconds to die, so the walk usually still "
            + "succeeds — which is exactly why the order is pinned here instead.")
    }

    /// Phase 2 must not re-walk: by then the roots are dying and the chain is already dissolved.
    /// `testPhaseTwoDoesNotDependOnTheTreeStillBeingIntact` covers this behaviourally; this
    /// catches it at the point of edit.
    func testForceTerminationDoesNotRewalkTheTree() throws {
        let source = try Self.readSource()
        let body = try XCTUnwrap(Self.functionBody(named: "forceTermination", in: source))
        XCTAssertFalse(body.contains("descendants(of:"),
                       "forceTermination re-walks the tree; the roots are already dead by then, "
                       + "so it would find nothing and the orphans would survive")
    }

    // MARK: - Source access

    private static func readSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Backends
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // DevgenticTests
            .deletingLastPathComponent()   // repo root
        let path = "Devgentic/Interfaces/Main/Views/Tooling/Local/utils/ProcessTree.swift"
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("ProcessTree.swift not reachable — running outside a checkout")
        }
        return text
    }

    /// `func <name>`'s body with comments stripped, so the prose explaining the ordering cannot
    /// be mistaken for the code that implements it.
    private static func functionBody(named name: String, in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("func \(name)(") }) else { return nil }

        var depth = 0
        var started = false
        var body: [String] = []
        for line in lines[start...] {
            depth += line.filter { $0 == "{" }.count
            depth -= line.filter { $0 == "}" }.count
            if depth > 0 { started = true }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.hasPrefix("//") { body.append(line) }
            if started && depth == 0 { break }
        }
        return body.joined(separator: "\n")
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitChangesStoreTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

// MARK: - Test doubles

/// Blocks callers at `pass()` until `open()`; `arrival()` waits until someone is blocked there.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var hasArrived = false
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            hasArrived = true
            let waiters = arrivalWaiters; arrivalWaiters = []
            if isOpen { lock.unlock(); c.resume() } else { blocked.append(c); lock.unlock() }
            waiters.forEach { $0.resume() }
        }
    }

    func arrival() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if hasArrived { lock.unlock(); c.resume() } else { arrivalWaiters.append(c); lock.unlock() }
        }
    }

    func open() {
        lock.lock(); isOpen = true
        let waiters = blocked; blocked = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }
}

/// A fake git keyed on the `-C` directory and subcommand.
private final class FakeGit: @unchecked Sendable {
    private let lock = NSLock()
    private var _invocations: [GitInvocation] = []
    /// `rev-parse` answers: directory → repository toplevel. Anything else is "not a git repository".
    var toplevel: [String: String] = ["/repo": "/repo"]
    var status = GitChangesSnapshotTests.statusFixture
    var unstaged = GitChangesSnapshotTests.unstagedFixture
    var staged = GitChangesSnapshotTests.stagedFixture
    var statusExitCode: Int32 = 0
    var statusComplete = true
    /// Status calls for these repos block on the gate.
    var statusGates: [String: Gate] = [:]
    /// `cat-file blob <object>` answers, keyed by object (`HEAD:path`, `:0:path`). Missing ⇒ git's
    /// "does not exist" failure.
    var blobs: [String: Data] = [:]
    var blobComplete = true
    /// `cat-file -s` answers that differ from the stored blob's real size — to model a blob too large
    /// to register as data. Absent ⇒ the size of `blobs[object]`.
    var blobSizes: [String: Int] = [:]

    var invocations: [GitInvocation] { lock.lock(); defer { lock.unlock() }; return _invocations }
    func count(_ subcommand: String) -> Int { invocations.filter { $0.arguments.contains(subcommand) }.count }

    lazy var runner: GitCommandRunner = { [unowned self] invocation in
        try await self.run(invocation)
    }

    private func run(_ invocation: GitInvocation) async throws -> GitRunOutput {
        lock.lock(); _invocations.append(invocation); lock.unlock()
        let args = invocation.arguments
        let dir = args.count > 1 ? args[1] : ""

        if args.contains("rev-parse") {
            guard let root = toplevel[dir] else {
                return GitRunOutput(standardOutput: Data(), standardError: "fatal: not a git repository (or any of the parent directories): .git\n",
                                    exitCode: 128, isComplete: true)
            }
            return ok("\(root)\n\(root)/.git\n")
        }
        if args.contains("status") {
            if let gate = statusGates[dir] { await gate.pass() }
            return GitRunOutput(standardOutput: status, standardError: statusExitCode == 0 ? "" : "fatal: index file corrupt",
                                exitCode: statusExitCode, isComplete: statusComplete)
        }
        if args.contains("diff") {
            return ok(args.contains("--cached") ? staged : unstaged)
        }
        if args.contains("cat-file"), args.contains("-s"), let object = args.last {
            guard let size = blobSizes[object] ?? blobs[object]?.count else {
                return GitRunOutput(standardOutput: Data(), standardError: "fatal: path '\(object)' does not exist",
                                    exitCode: 128, isComplete: true)
            }
            return ok("\(size)\n")
        }
        if args.contains("cat-file"), let object = args.last {
            guard let data = blobs[object] else {
                return GitRunOutput(standardOutput: Data(), standardError: "fatal: path '\(object)' does not exist",
                                    exitCode: 128, isComplete: true)
            }
            return GitRunOutput(standardOutput: data, standardError: "", exitCode: 0, isComplete: blobComplete)
        }
        XCTFail("unexpected git invocation \(args)")
        return ok("")
    }

    private func ok(_ text: String) -> GitRunOutput { ok(Data(text.utf8)) }
    private func ok(_ data: Data) -> GitRunOutput {
        GitRunOutput(standardOutput: data, standardError: "", exitCode: 0, isComplete: true)
    }
}

// MARK: - Tests

@MainActor
final class GitChangesStoreTests: XCTestCase {

    private var git: FakeGit!

    override func setUp() {
        super.setUp()
        git = FakeGit()
    }

    private func makeStore(gitAvailable: Bool = true,
                           debounce: Duration = .zero,
                           fileExists: @escaping @Sendable (String) -> Bool = { _ in false },
                           worktree: [String: GitSideRead] = [:]) -> GitChangesStore {
        GitChangesStore(dependencies: .init(
            runner: git.runner,
            isGitAvailable: { gitAvailable },
            measureUntracked: { _ in .lines(2) },
            fileExists: fileExists,
            debounce: debounce,
            readWorktree: { url in worktree[url.path] ?? .failed("no such file in test worktree: \(url.path)") }
        ))
    }

    private func load(_ store: GitChangesStore, _ path: String = "/repo") async {
        store.setProject(URL(fileURLWithPath: path))
        await store.waitUntilIdle()
    }

    // MARK: Happy path

    func testLoadsAMergedSnapshot() async {
        let store = makeStore(fileExists: { $0 == "/repo/.git/MERGE_HEAD" })
        await load(store)

        guard let snapshot = store.snapshot else { return XCTFail("expected loaded, got \(store.phase)") }
        XCTAssertEqual(snapshot.repoRoot, "/repo")
        XCTAssertEqual(snapshot.branch.head, "main")
        XCTAssertEqual(snapshot.files.count, 9)
        XCTAssertEqual(snapshot.files.first?.path, "conflict.txt")
        XCTAssertEqual(snapshot.totals(), GitLineTotals(added: 14, deleted: 2))
        XCTAssertEqual(snapshot.inProgressOperation, .merge, "git dir comes from rev-parse, not an assumed `.git`")
        XCTAssertFalse(snapshot.isTruncated)
        XCTAssertFalse(store.isRefreshing)
    }

    /// ⚠️ WIRING: the factory's guarantees only hold if the store actually goes through it. Every
    /// invocation the store makes must carry the hardening, the suppression on diffs, and
    /// `GIT_OPTIONAL_LOCKS=0`. Fails if any call site builds its own argv.
    func testEveryInvocationTheStoreMakesIsHardened() async {
        let store = makeStore()
        await load(store)

        let invocations = git.invocations
        XCTAssertEqual(invocations.count, 4, "rev-parse, status, two numstats")
        let hardening = GitCommandBuilder.hardening
        for invocation in invocations {
            let args = invocation.arguments
            XCTAssertEqual(args.first, "-C", "\(args)")
            XCTAssertEqual(Array(args.dropFirst(2).prefix(hardening.count)), hardening, "\(args)")
            XCTAssertEqual(invocation.environment["GIT_OPTIONAL_LOCKS"], "0", "\(args)")
            XCTAssertEqual(invocation.environment["TERM"], "dumb", "\(args)")
            if args.contains("diff") {
                for flag in GitCommandBuilder.diffProgramSuppression {
                    XCTAssertTrue(args.contains(flag), "\(flag) missing from \(args)")
                }
            }
        }
        // Exactly the factory's invocations. Status and the numstats run concurrently, so compare
        // as a set — their order is not a contract.
        let expected = [
            GitUICommand.locate(directory: "/repo"),
            GitUICommand.status(repoRoot: "/repo"),
            GitUICommand.numstat(repoRoot: "/repo", staged: false),
            GitUICommand.numstat(repoRoot: "/repo", staged: true),
        ]
        XCTAssertEqual(invocations.first, expected.first, "rev-parse must run first — every later path depends on it")
        XCTAssertEqual(Set(invocations.map { $0.arguments + ["|"] + $0.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } }),
                       Set(expected.map { $0.arguments + ["|"] + $0.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } }))
    }

    /// Paths are relative to the REPO root, so a subfolder project must run status at the root.
    func testSubfolderProjectRunsAtTheRepoRoot() async {
        git.toplevel["/repo/newdir"] = "/repo"   // what real rev-parse answers from a subfolder
        let store = makeStore()
        await load(store, "/repo/newdir")

        XCTAssertEqual(git.invocations.first, GitUICommand.locate(directory: "/repo/newdir"))
        XCTAssertTrue(git.invocations.contains(GitUICommand.status(repoRoot: "/repo")))
        XCTAssertFalse(git.invocations.contains(GitUICommand.status(repoRoot: "/repo/newdir")))
        XCTAssertEqual(store.snapshot?.repoRoot, "/repo")
        XCTAssertEqual(store.snapshot?.files.filter { !$0.isOutsideProject }.map(\.path), ["newdir/untracked one.txt"])
    }

    // MARK: Explainer phases

    func testNoProjectRunsNothing() async {
        let store = makeStore()
        store.setProject(nil)
        store.requestRefresh(reason: "test")
        await store.waitUntilIdle()
        XCTAssertEqual(store.phase, .noProject)
        XCTAssertEqual(git.invocations, [])
    }

    /// Without the Command Line Tools every git call pops the installer — so git is never called.
    func testGitUnavailableNeverInvokesGit() async {
        let store = makeStore(gitAvailable: false)
        await load(store)
        XCTAssertEqual(store.phase, .gitUnavailable)
        XCTAssertEqual(git.invocations, [])
    }

    func testNotARepositoryCarriesGitsOwnMessageAndStops() async {
        let store = makeStore()
        await load(store, "/elsewhere")
        guard case .notARepository(let detail) = store.phase else { return XCTFail("got \(store.phase)") }
        XCTAssertTrue(detail.contains("not a git repository"))
        XCTAssertEqual(git.invocations.count, 1, "nothing after a failed rev-parse")
    }

    /// A failed status is a failure, never a partial list built from the numstats alone.
    func testFailedStatusIsAFailureNotAPartialList() async {
        git.statusExitCode = 128
        let store = makeStore()
        await load(store)
        guard case .failed(let message) = store.phase else { return XCTFail("got \(store.phase)") }
        XCTAssertEqual(message, "fatal: index file corrupt")
    }

    func testIncompleteOutputIsMarkedTruncated() async {
        git.statusComplete = false
        let store = makeStore()
        await load(store)
        XCTAssertEqual(store.snapshot?.isTruncated, true)
    }

    func testMalformedOutputIsMarkedTruncated() async {
        git.status = GitChangesSnapshotTests.z("# branch.head main", "1 .M garbage", "? ok.txt")
        let store = makeStore()
        await load(store)
        XCTAssertEqual(store.snapshot?.isTruncated, true)
        XCTAssertEqual(store.snapshot?.files.map(\.path), ["ok.txt"])
    }

    // MARK: Coalescing

    func testSettingTheSameProjectAgainIsANoop() async {
        let store = makeStore()
        await load(store)
        store.setProject(URL(fileURLWithPath: "/repo"))
        await store.waitUntilIdle()
        XCTAssertEqual(git.count("rev-parse"), 1)
    }

    func testABurstOfRequestsIsOnePass() async throws {
        let store = makeStore(debounce: .milliseconds(50))
        await load(store)
        for i in 0..<5 { store.requestRefresh(reason: "burst \(i)") }
        try await Task.sleep(for: .milliseconds(300))
        await store.waitUntilIdle()
        XCTAssertEqual(git.count("rev-parse"), 2, "initial load + ONE coalesced pass")
    }

    /// Requests arriving while a pass is in flight collapse into exactly one trailing pass.
    func testRequestsDuringAPassBecomeOneTrailingPass() async throws {
        let gate = Gate()
        git.statusGates["/repo"] = gate
        let store = makeStore()
        store.setProject(URL(fileURLWithPath: "/repo"))
        await gate.arrival()                       // first pass is blocked inside `status`

        // SPACED, so each request survives its own debounce and reaches the in-flight check.
        // Back-to-back calls would be collapsed by the debounce alone and never test coalescing
        // (a mutant removing the in-flight check survived exactly that way).
        for i in 0..<3 {
            store.requestRefresh(reason: "during \(i)")
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(git.count("rev-parse"), 1, "no request may start a second pass while one is in flight")
        gate.open()
        await store.waitUntilIdle()

        XCTAssertEqual(git.count("rev-parse"), 2, "one pass + one trailing pass, not 1 + 3")
        XCTAssertNotNil(store.snapshot)
    }

    /// A pass that finishes after the project changed describes the OLD project and must never be
    /// shown — not even briefly before the trailing pass replaces it.
    func testAStaleProjectsResultIsNeverPublished() async {
        git.toplevel = ["/a": "/a", "/b": "/b"]
        let gateA = Gate(), gateB = Gate()
        git.statusGates = ["/a": gateA, "/b": gateB]
        let store = makeStore()

        store.setProject(URL(fileURLWithPath: "/a"))
        await gateA.arrival()
        store.setProject(URL(fileURLWithPath: "/b"))   // queued behind A's pass
        gateA.open()
        await gateB.arrival()                          // A's pass is done; B's is blocked

        XCTAssertNil(store.snapshot, "A's result was published after the switch to B: \(store.phase)")

        gateB.open()
        await store.waitUntilIdle()
        XCTAssertEqual(store.snapshot?.repoRoot, "/b")
    }

    // MARK: Per-file diff

    private func file(_ path: String, in store: GitChangesStore) -> GitFileChange {
        store.snapshot!.files.first { $0.path == path }!
    }

    /// Unstaged = index → worktree. Reads the index blob through the factory and the worktree from
    /// disk, then diffs.
    func testUnstagedDiffComparesIndexToWorktree() async {
        git.blobs[":0:modified.txt"] = Data("a\nb\nc\n".utf8)
        let store = makeStore(worktree: ["/repo/modified.txt": .content(Data("a\nB\nc\nd\n".utf8))])
        await load(store)

        guard case .lines(let rows) = await store.loadDiff(for: file("modified.txt", in: store), filter: .unstaged)
        else { return XCTFail("expected lines") }
        XCTAssertEqual(rows.filter { $0.type == .added }.map(\.line), ["B", "d"])
        XCTAssertEqual(rows.filter { $0.type == .deleted }.map(\.line), ["b"])
    }

    /// ⚠️ WIRING for the diff path: blob reads must go through the factory too.
    func testDiffReadsAreHardened() async {
        git.blobs["HEAD:old name.txt"] = Data("x\n".utf8)
        git.blobs[":0:new näme.txt"] = Data("x\n".utf8)
        let store = makeStore()
        await load(store)
        _ = await store.loadDiff(for: file("new näme.txt", in: store), filter: .staged)

        let blobReads = git.invocations.filter { $0.arguments.contains("cat-file") }
        XCTAssertEqual(Set(blobReads.map(\.arguments)), Set([
            GitUICommand.blobSize(repoRoot: "/repo", side: .head, path: "old name.txt").arguments,
            GitUICommand.blob(repoRoot: "/repo", side: .head, path: "old name.txt").arguments,
            GitUICommand.blobSize(repoRoot: "/repo", side: .index, path: "new näme.txt").arguments,
            GitUICommand.blob(repoRoot: "/repo", side: .index, path: "new näme.txt").arguments,
        ]), "a rename's HEAD side is read at the ORIGINAL path")
        for invocation in blobReads {
            XCTAssertEqual(invocation.environment["GIT_OPTIONAL_LOCKS"], "0")
            XCTAssertEqual(Array(invocation.arguments.dropFirst(2).prefix(GitCommandBuilder.hardening.count)),
                           GitCommandBuilder.hardening)
        }
    }

    func testUntrackedDiffReadsNoBlob() async {
        let store = makeStore(worktree: ["/repo/tab\there.txt": .content(Data("tab\n".utf8))])
        await load(store)
        guard case .lines(let rows) = await store.loadDiff(for: file("tab\there.txt", in: store), filter: .all)
        else { return XCTFail("expected lines") }
        XCTAssertEqual(rows.map(\.type), [.added])
        XCTAssertFalse(git.invocations.contains { $0.arguments.contains("cat-file") })
    }

    func testBinarySideIsBinary() async {
        git.blobs[":0:blob.bin"] = Data([0x00, 0x01, 0x02])
        let store = makeStore(worktree: ["/repo/blob.bin": .content(Data([0x00, 0x03]))])
        await load(store)
        guard case .binary = await store.loadDiff(for: file("blob.bin", in: store), filter: .unstaged)
        else { return XCTFail("expected binary") }
    }

    /// An unexpected read failure is an ERROR with git's message — never "the whole file was added".
    func testAFailedBlobReadIsAFailureNotAnEmptySide() async {
        let store = makeStore(worktree: ["/repo/modified.txt": .content(Data("a\n".utf8))])
        await load(store)   // no :0:modified.txt blob registered
        guard case .failed(let reason) = await store.loadDiff(for: file("modified.txt", in: store), filter: .unstaged)
        else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("does not exist"))
    }

    /// A blob cut off by the capture cap is never diffed as if whole.
    func testAnIncompleteBlobIsTooLarge() async {
        git.blobs[":0:modified.txt"] = Data("a\n".utf8)
        git.blobComplete = false
        let store = makeStore(worktree: ["/repo/modified.txt": .content(Data("a\n".utf8))])
        await load(store)
        guard case .tooLarge = await store.loadDiff(for: file("modified.txt", in: store), filter: .unstaged)
        else { return XCTFail("expected tooLarge") }
    }

    /// The point of `cat-file -s`: a blob over the limit is refused WITHOUT fetching it.
    func testALargeBlobIsRefusedWithoutFetchingIt() async {
        git.blobSizes[":0:modified.txt"] = UntrackedFileInfo.byteLimit + 1
        let store = makeStore(worktree: ["/repo/modified.txt": .content(Data("a\n".utf8))])
        await load(store)
        guard case .tooLarge = await store.loadDiff(for: file("modified.txt", in: store), filter: .unstaged)
        else { return XCTFail("expected tooLarge") }
        XCTAssertFalse(git.invocations.contains {
            $0.arguments.suffix(2) == ["blob", ":0:modified.txt"]
        }, "the large blob was transferred anyway")
    }

    /// Exactly at the limit is still diffed — the limit is inclusive, matching the worktree read.
    func testABlobAtTheLimitIsFetched() async {
        git.blobs[":0:modified.txt"] = Data(repeating: 0x61, count: UntrackedFileInfo.byteLimit)
        let store = makeStore(worktree: ["/repo/modified.txt": .content(Data("a\n".utf8))])
        await load(store)
        guard case .lines = await store.loadDiff(for: file("modified.txt", in: store), filter: .unstaged)
        else { return XCTFail("expected lines") }
    }

    /// A size git won't report (missing object) fails with git's message — and nothing is fetched.
    func testAFailedSizeQueryIsAFailureAndFetchesNothing() async {
        let store = makeStore(worktree: ["/repo/modified.txt": .content(Data("a\n".utf8))])
        await load(store)
        guard case .failed(let reason) = await store.loadDiff(for: file("modified.txt", in: store), filter: .unstaged)
        else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("does not exist"))
        XCTAssertFalse(git.invocations.contains { $0.arguments.contains("cat-file") && $0.arguments.contains("blob") })
    }

    func testALargeWorktreeFileIsTooLarge() async {
        git.blobs[":0:modified.txt"] = Data("a\n".utf8)
        let store = makeStore(worktree: ["/repo/modified.txt": .tooLarge])
        await load(store)
        guard case .tooLarge = await store.loadDiff(for: file("modified.txt", in: store), filter: .unstaged)
        else { return XCTFail("expected tooLarge") }
    }

    /// Open diffs key their reload on this — it must move on every published pass, even when the
    /// snapshot is identical (an edit that keeps the line counts).
    func testEveryPassBumpsTheRevision() async {
        let store = makeStore()
        await load(store)
        let first = store.snapshotRevision
        await store.refreshNow()
        XCTAssertGreaterThan(store.snapshotRevision, first)
    }

    // MARK: Observation scope

    /// Whether reading `read` registers an observation that fires during `action`.
    private func notifies(_ store: GitChangesStore, reading read: @escaping () -> Void,
                          during action: () async -> Void) async -> Bool {
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking { read() } onChange: { flag.fired = true }
        await action()
        return flag.fired
    }

    /// A pass runs after EVERY successful tool during an agent run. An identical result must not
    /// notify `phase` readers — `@Observable` notifies on every write, equal or not.
    func testAnIdenticalPassDoesNotRepublishThePhase() async {
        let store = makeStore()
        await load(store)
        let fired = await notifies(store, reading: { _ = store.phase }) { await store.refreshNow() }
        XCTAssertFalse(fired, "an unchanged snapshot re-notified every phase reader")
    }

    func testAChangedPassDoesRepublishThePhase() async {
        let store = makeStore()
        await load(store)
        git.unstaged = Data("9\t9\tmodified.txt\u{0}".utf8)
        let fired = await notifies(store, reading: { _ = store.phase }) { await store.refreshNow() }
        XCTAssertTrue(fired)
    }

    /// `MainApplicationView` reads ONLY this flag. A count change must not reach it; the
    /// loaded / not-loaded transition must.
    func testTheLoadedFlagChangesOnlyOnTheTransition() async {
        let store = makeStore()
        XCTAssertFalse(store.hasLoadedRepository)
        await load(store)
        XCTAssertTrue(store.hasLoadedRepository)

        git.unstaged = Data("9\t9\tmodified.txt\u{0}".utf8)
        let firedOnCountChange = await notifies(store, reading: { _ = store.hasLoadedRepository }) {
            await store.refreshNow()
        }
        XCTAssertFalse(firedOnCountChange, "a count change re-rendered the main window")

        store.setProject(nil)
        XCTAssertFalse(store.hasLoadedRepository)
    }

    /// Open diffs still reload on every pass — the dedupe must not reach the revision.
    func testTheRevisionStillMovesOnAnIdenticalPass() async {
        let store = makeStore()
        await load(store)
        let before = store.snapshotRevision
        await store.refreshNow()
        XCTAssertGreaterThan(store.snapshotRevision, before)
    }

    func testClosingTheProjectClearsThePhase() async {
        let store = makeStore()
        await load(store)
        store.setProject(nil)
        XCTAssertEqual(store.phase, .noProject)
    }
}

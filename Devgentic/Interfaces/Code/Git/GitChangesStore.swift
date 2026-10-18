// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitChangesStore.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "GitUI")

/// Owns the Git Changes panel's snapshot for the open Code project: runs the read-only command matrix off the main
/// actor, coalesces refresh requests and publishes one phase.
@Observable @MainActor
final class GitChangesStore {

    /// What the panel / pill render. Every non-`loaded` case is an explainer, never a silent blank.
    enum Phase: Equatable {
        /// No Code project is open.
        case noProject
        /// The Command Line Tools are missing — git is never invoked (see `GitUICommand.isGitAvailable`).
        case gitUnavailable
        /// `rev-parse` refused the folder. `detail` is git's own stderr, shown as-is: classifying it
        /// by sniffing the text would be a guess.
        case notARepository(detail: String)
        case loaded(GitChangesSnapshot)
        case failed(message: String)
    }

    struct Dependencies: Sendable {
        var runner: GitCommandRunner
        var isGitAvailable: @Sendable () -> Bool
        var measureUntracked: @Sendable (URL) -> UntrackedFileInfo
        var fileExists: @Sendable (String) -> Bool
        /// Quiet period before a requested refresh runs; a burst of requests inside it becomes one.
        var debounce: Duration
        /// Reads a worktree file for the diff view.
        var readWorktree: @Sendable (URL) -> GitSideRead = GitSideRead.readWorktree

        static let live = Dependencies(
            runner: GitUICommand.liveRunner,
            isGitAvailable: { GitUICommand.isGitAvailable },
            measureUntracked: UntrackedFileInfo.measure,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            debounce: .milliseconds(500)
        )
    }

    /// The panel's phase. A pass runs after every successful tool, and an identical result notifies no one, since
    /// Observation suppresses an equal `Equatable` write. `Phase` and everything it holds must stay `Equatable` and free
    /// of per-pass values like timestamps.
    private(set) var phase: Phase = .noProject {
        didSet { hasLoadedRepository = snapshot != nil }
    }
    /// Whether a repository is loaded: the one fact `MainApplicationView` needs. A separate flag so the large body
    /// observes only the loaded/not-loaded transition; a count change re-renders the pill, not the window.
    private(set) var hasLoadedRepository = false
    private(set) var isRefreshing = false
    private(set) var projectPath: URL?
    /// Bumped on every published snapshot. An expanded row keys its diff load on this, so a refresh
    /// reloads open diffs even when a file's line COUNTS did not change (an edit that swaps one line
    /// for another).
    private(set) var snapshotRevision = 0

    var snapshot: GitChangesSnapshot? {
        if case .loaded(let snapshot) = phase { return snapshot }
        return nil
    }

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var cycleTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherPass = false
    /// Bumped on every project change; a pass that finishes under an older value is discarded.
    @ObservationIgnored private var generation = 0

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    // MARK: - Inputs

    /// Follows `CodeSessionManager.projectPath`. A change refreshes immediately (no debounce): the
    /// panel is showing the OLD project's rows until it lands.
    func setProject(_ url: URL?) {
        guard url?.standardizedFileURL != projectPath?.standardizedFileURL else { return }
        projectPath = url
        generation += 1
        debounceTask?.cancel()
        if url == nil {
            phase = .noProject
            return
        }
        startOrQueuePass(reason: "project changed")
    }

    /// Debounced refresh — run events, saves, app activation. A burst becomes one pass.
    func requestRefresh(reason: String) {
        guard projectPath != nil else { return }
        debounceTask?.cancel()
        let delay = dependencies.debounce
        debounceTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            self?.startOrQueuePass(reason: reason)
        }
    }

    /// Immediate refresh (manual Refresh button). Returns when the snapshot reflects a pass that
    /// STARTED after this call.
    func refreshNow(reason: String = "manual") async {
        debounceTask?.cancel()
        startOrQueuePass(reason: reason)
        await cycleTask?.value
    }

    /// Waits for the current cycle (including its trailing pass) WITHOUT requesting one — unlike
    /// `refreshNow`, which would queue an extra pass behind a running one.
    func waitUntilIdle() async {
        await cycleTask?.value
    }

    // MARK: - Coalescing

    /// One pass in flight at a time. A request during a pass sets `needsAnotherPass` and the cycle
    /// runs exactly one trailing pass — latest state wins, and N requests never become N passes.
    private func startOrQueuePass(reason: String) {
        if cycleTask != nil {
            needsAnotherPass = true
            return
        }
        cycleTask = Task { [weak self] in
            await self?.runCycle(firstReason: reason)
        }
    }

    private func runCycle(firstReason: String) async {
        var reason = firstReason
        repeat {
            needsAnotherPass = false
            await performPass(reason: reason)
            reason = "coalesced request"
        } while needsAnotherPass
        cycleTask = nil
    }

    private func performPass(reason: String) async {
        guard let project = projectPath else {
            phase = .noProject
            return
        }
        let passGeneration = generation
        let correlation = "\(project.lastPathComponent)#\(passGeneration)"
        isRefreshing = true
        defer { isRefreshing = false }

        let deps = dependencies
        let started = ContinuousClock.now
        let outcome = await Task.detached(priority: .utility) {
            await Self.computePhase(project: project, dependencies: deps, correlation: correlation)
        }.value

        guard passGeneration == generation else {
            logger.debug("[GitUI] \(correlation) pass finished after the project changed — result DISCARDED (it describes the previous project).")
            return
        }
        phase = outcome
        // Bumped EVERY pass, even when the snapshot is identical: an expanded diff must reload after
        // an edit that kept the line counts. Read only by expanded `GitFileDiffView`s.
        snapshotRevision += 1
        if case .loaded(let snapshot) = outcome {
            logger.debug("[GitUI] \(correlation) refreshed (\(reason)): \(snapshot.files.count) files in \(ContinuousClock.now - started)")
        }
    }

    // MARK: - Per-file diff

    /// Loads one row's diff for `filter` against the CURRENT snapshot. Lazy: called when a row is
    /// expanded, never for the whole list.
    func loadDiff(for file: GitFileChange, filter: GitChangesFilter) async -> GitFileDiff {
        guard let snapshot else {
            return .failed(String(localized: "No changes loaded."))
        }
        let deps = dependencies
        let root = snapshot.repoRoot
        let sides = GitDiffSide.sides(for: file, filter: filter, isUnborn: snapshot.branch.isUnborn)
        let path = file.path
        return await Task.detached(priority: .userInitiated) {
            await Self.computeDiff(sides: sides, repoRoot: root, dependencies: deps, path: path)
        }.value
    }

    nonisolated private static func computeDiff(sides: (original: GitDiffSide, modified: GitDiffSide),
                                                repoRoot: String, dependencies deps: Dependencies,
                                                path: String) async -> GitFileDiff {
        async let original = read(sides.original, repoRoot: repoRoot, dependencies: deps)
        async let modified = read(sides.modified, repoRoot: repoRoot, dependencies: deps)
        let (a, b) = await (original, modified)

        let dataA: Data, dataB: Data
        switch (a, b) {
        case (.failed(let reason), _), (_, .failed(let reason)):
            logger.warning("[GitUI] diff of '\(path)' failed: \(reason.prefix(200)). CONSEQUENCE: the row shows the error instead of a diff.")
            return .failed(reason)
        case (.tooLarge, _), (_, .tooLarge):
            return .tooLarge
        case (.content(let x), .content(let y)):
            dataA = x; dataB = y
        }

        let sniff = UntrackedFileInfo.binarySniffLength
        if dataA.prefix(sniff).contains(0) || dataB.prefix(sniff).contains(0) {
            return .binary
        }
        return .lines(DiffUtility.generateDiff(original: String(decoding: dataA, as: UTF8.self),
                                               modified: String(decoding: dataB, as: UTF8.self)))
    }

    nonisolated private static func read(_ side: GitDiffSide, repoRoot: String,
                                         dependencies deps: Dependencies) async -> GitSideRead {
        let blobSide: GitUICommand.BlobSide
        let path: String
        switch side {
        case .empty:
            return .content(Data())
        case .worktree(let p):
            return deps.readWorktree(URL(fileURLWithPath: repoRoot).appendingPathComponent(p))
        case .head(let p):
            blobSide = .head; path = p
        case .index(let p):
            blobSide = .index; path = p
        }
        do {
            // Size first: refusing a large blob must not cost its transfer.
            let sizeRun = try await deps.runner(GitUICommand.blobSize(repoRoot: repoRoot, side: blobSide, path: path))
            guard sizeRun.succeeded else { return .failed(failureDetail(sizeRun)) }
            let sizeText = String(decoding: sizeRun.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let size = Int(sizeText) else {
                logger.error("[GitUI] cat-file -s for '\(path)' printed '\(sizeText.prefix(40))', not a byte count. CONSEQUENCE: the row shows an error instead of a diff.")
                return .failed(String(localized: "git reported an unreadable size for this file."))
            }
            if size > UntrackedFileInfo.byteLimit { return .tooLarge }

            let run = try await deps.runner(GitUICommand.blob(repoRoot: repoRoot, side: blobSide, path: path))
            guard run.succeeded else { return .failed(failureDetail(run)) }
            // Still checked after the fetch: the INDEX can change between the two calls (a HEAD blob
            // cannot), and an elided / cut-off blob must never be diffed as if whole.
            if !run.isComplete || run.standardOutput.count > UntrackedFileInfo.byteLimit { return .tooLarge }
            return .content(run.standardOutput)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    nonisolated private static func failureDetail(_ run: GitRunOutput) -> String {
        let detail = run.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? String(localized: "git cat-file exited \(run.exitCode).") : detail
    }

    // MARK: - The command matrix (off-main)

    nonisolated private static func computePhase(project: URL, dependencies deps: Dependencies,
                                                 correlation: String) async -> Phase {
        guard deps.isGitAvailable() else { return .gitUnavailable }

        do {
            // 1. Where is the repository? Paths in every later output are relative to ITS root.
            let located = try await deps.runner(GitUICommand.locate(directory: project.path))
            guard located.succeeded else {
                let detail = located.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                logger.notice("[GitUI] \(correlation) rev-parse exited \(located.exitCode): \(detail.prefix(200)). CONSEQUENCE: panel shows the not-a-repository explainer.")
                return .notARepository(detail: detail)
            }
            let lines = String(decoding: located.standardOutput, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard lines.count == 2 else {
                logger.error("[GitUI] \(correlation) rev-parse printed \(lines.count) lines, expected toplevel + git dir. CONSEQUENCE: panel shows a failure; no git state is displayed.")
                return .failed(message: String(localized: "Couldn't locate the repository for this folder."))
            }
            let repoRoot = lines[0], gitDir = lines[1]

            // 2. Status and both numstats are independent — run them together.
            async let statusRun = deps.runner(GitUICommand.status(repoRoot: repoRoot))
            async let unstagedRun = deps.runner(GitUICommand.numstat(repoRoot: repoRoot, staged: false))
            async let stagedRun = deps.runner(GitUICommand.numstat(repoRoot: repoRoot, staged: true))
            let (statusOut, unstagedOut, stagedOut) = try await (statusRun, unstagedRun, stagedRun)

            for (name, run) in [("status", statusOut), ("diff --numstat", unstagedOut), ("diff --cached --numstat", stagedOut)]
            where !run.succeeded {
                let detail = run.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                logger.error("[GitUI] \(correlation) git \(name) exited \(run.exitCode): \(detail.prefix(200)). CONSEQUENCE: panel shows a failure instead of a partial list.")
                return .failed(message: detail.isEmpty
                               ? String(localized: "git \(name) failed (exit \(run.exitCode)).")
                               : detail)
            }

            let status = GitPorcelainParser.parse(statusOut.standardOutput)
            let unstaged = GitNumstatParser.parse(unstagedOut.standardOutput)
            let staged = GitNumstatParser.parse(stagedOut.standardOutput)

            let malformed = status.malformedRecordCount + unstaged.malformedRecordCount + staged.malformedRecordCount
            let incomplete = !statusOut.isComplete || !unstagedOut.isComplete || !stagedOut.isComplete
            if malformed > 0 || incomplete {
                logger.warning("[GitUI] \(correlation) git output incomplete=\(incomplete) malformedRecords=\(malformed). CONSEQUENCE: the list may be missing files; the panel marks it truncated.")
            }

            // 3. Untracked sizes — numstat does not cover them. Capped, and only for listed rows.
            var untrackedInfo: [String: UntrackedFileInfo] = [:]
            for path in GitChangesSnapshot.untrackedPathsToMeasure(status) {
                untrackedInfo[path] = deps.measureUntracked(URL(fileURLWithPath: repoRoot).appendingPathComponent(path))
            }

            return .loaded(GitChangesSnapshot.build(
                repoRoot: repoRoot,
                status: status,
                unstaged: unstaged.countsByPath(),
                staged: staged.countsByPath(),
                untrackedInfo: untrackedInfo,
                projectPrefix: GitChangesSnapshot.projectPrefix(projectPath: project, repoRoot: repoRoot),
                inProgressOperation: GitInProgressOperation.detect(gitDir: gitDir, exists: deps.fileExists),
                isTruncated: malformed > 0 || incomplete
            ))
        } catch {
            logger.error("[GitUI] \(correlation) could not run git: \(error.localizedDescription). CONSEQUENCE: panel shows a failure; no git state is displayed.")
            return .failed(message: error.localizedDescription)
        }
    }
}

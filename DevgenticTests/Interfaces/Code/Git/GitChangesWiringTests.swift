// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitChangesWiringTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class GitChangesWiringTests: XCTestCase {

    private let project = URL(fileURLWithPath: "/repo")

    // MARK: - Project follow

    func testFollowsTheProjectOnlyInCodeMode() {
        XCTAssertEqual(GitChangesWiring.project(interfaceMode: .code, projectPath: project, isTestHost: false), project)
        XCTAssertNil(GitChangesWiring.project(interfaceMode: .chat, projectPath: project, isTestHost: false))
        XCTAssertNil(GitChangesWiring.project(interfaceMode: .workflow, projectPath: project, isTestHost: false))
    }

    /// The test host IS the real app; following a restored project would run git against the
    /// developer's own repository during a test run.
    func testFollowsNothingUnderATestHost() {
        XCTAssertNil(GitChangesWiring.project(interfaceMode: .code, projectPath: project, isTestHost: true))
    }

    func testNoProjectIsNoProject() {
        XCTAssertNil(GitChangesWiring.project(interfaceMode: .code, projectPath: nil, isTestHost: false))
    }

    // MARK: - Mount gate

    /// The flag lives on the SHARED view model; Chat/Workflow must never mount the panel even if
    /// the flag is somehow left true.
    func testThePanelMountsOnlyInCodeMode() {
        XCTAssertTrue(GitChangesWiring.shouldMountPanel(interfaceMode: .code, isPresented: true))
        XCTAssertFalse(GitChangesWiring.shouldMountPanel(interfaceMode: .code, isPresented: false))
        XCTAssertFalse(GitChangesWiring.shouldMountPanel(interfaceMode: .chat, isPresented: true))
        XCTAssertFalse(GitChangesWiring.shouldMountPanel(interfaceMode: .workflow, isPresented: true))
    }

    // MARK: - Pill rule

    func testPillShowsForALoadedRepositoryWithNoPanelOpen() {
        XCTAssertTrue(GitChangesFloatingButton.shouldShow(hasLoadedRepository: true, anyPanelOpen: false))
        XCTAssertFalse(GitChangesFloatingButton.shouldShow(hasLoadedRepository: true, anyPanelOpen: true))
        XCTAssertFalse(GitChangesFloatingButton.shouldShow(hasLoadedRepository: false, anyPanelOpen: false),
                       "not-a-repo / unavailable are the PANEL's answers, not a pill on every folder")
    }

    // MARK: - Pill branch label

    func testShortBranchNamesAreUntouched() {
        XCTAssertEqual(GitChangesFloatingButton.compactBranchName("main"), "main")
        let exact = String(repeating: "a", count: GitChangesFloatingButton.branchCharacterLimit)
        XCTAssertEqual(GitChangesFloatingButton.compactBranchName(exact), exact)
    }

    /// Long names are middle-truncated to EXACTLY the limit, keeping both meaningful ends.
    func testLongBranchNamesKeepBothEnds() {
        let name = "feature/git-changes-panel-pill-width"
        let compact = GitChangesFloatingButton.compactBranchName(name)
        XCTAssertEqual(compact.count, GitChangesFloatingButton.branchCharacterLimit)
        XCTAssertTrue(compact.hasPrefix("feature/"))
        XCTAssertTrue(compact.hasSuffix("width"))
        XCTAssertTrue(compact.contains("…"))
    }

    /// The pill used `.frame(maxWidth:)` on the branch, which takes the whole offered width — the
    /// pill rendered several times wider than the Code Viewer pill. Pin that it stays gone.
    func testThePillDoesNotStretchToAFlexibleFrame() throws {
        let source = try sourceFile("Devgentic/Interfaces/Code/Git/GitChangesFloatingButton.swift")
        let code = source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("maxWidth:"), "a flexible frame in the pill stretches it across the stack")
    }

    // MARK: - Triggers

    /// The ONE write path every user save goes through must announce itself — that is how a ⌘S /
    /// Apply / Save As reaches the panel. A real write to a temp file, not a source scan.
    func testASuccessfulSavePostsWorkspaceActivity() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GitWire-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "old".write(to: url, atomically: true, encoding: .utf8)

        let posted = expectation(forNotification: WorkspaceActivity.didChange, object: nil) { note in
            (note.userInfo?[WorkspaceActivity.reasonKey] as? String)?.contains(url.lastPathComponent) == true
        }
        try await ChatHistoryViewModel.atomicallyWrite("new", to: url)
        await fulfillment(of: [posted], timeout: 2)
    }

    /// A FAILED save changed nothing and must not claim otherwise.
    func testAFailedSavePostsNothing() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GitWire-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "on disk".write(to: url, atomically: true, encoding: .utf8)

        let posted = expectation(forNotification: WorkspaceActivity.didChange, object: nil) { note in
            (note.userInfo?[WorkspaceActivity.reasonKey] as? String)?.contains(url.lastPathComponent) == true
        }
        posted.isInverted = true
        do {
            // Drift guard: the baseline does not match the disk, so the write is refused.
            try await ChatHistoryViewModel.atomicallyWrite("new", to: url, expectingBaseline: "something else")
            XCTFail("expected the drift guard to refuse")
        } catch {}
        await fulfillment(of: [posted], timeout: 0.5)
    }

    /// The run loop's posts can't be driven without a live agent run, so this pins them in the
    /// source — the same technique `BackgroundTasksEntryPointTests` uses for view wiring.
    func testTheRunLoopPostsOnToolSuccessAndRunEnd() throws {
        let source = try sourceFile("Devgentic/Core/Utils/ActiveStreamManager.swift")
        let lines = source.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }

        guard let success = lines.firstIndex(where: { $0.contains("case .toolSucceeded(") }) else {
            return XCTFail("toolSucceeded case not found — this guard is checking nothing")
        }
        XCTAssertTrue(lines[success..<min(success + 6, lines.count)].contains { $0.contains("WorkspaceActivity.post(") },
                      "a successful tool no longer tells the Git panel to refresh")

        guard let finalize = lines.firstIndex(where: { $0.contains("private func finalizeMessage(") }) else {
            return XCTFail("finalizeMessage not found — this guard is checking nothing")
        }
        XCTAssertTrue(lines[finalize..<min(finalize + 6, lines.count)].contains { $0.contains("WorkspaceActivity.post(") },
                      "a finished run no longer tells the Git panel to refresh")
    }

    /// The modifier is what turns every hint into a store request. Pinned because it is the link
    /// between the posts above and `GitChangesStore.requestRefresh`.
    func testTheWiringObservesEveryTrigger() throws {
        let source = try sourceFile("Devgentic/Interfaces/Code/Git/GitChangesWiring.swift")
        XCTAssertTrue(source.contains("publisher(for: WorkspaceActivity.didChange)"))
        XCTAssertTrue(source.contains("publisher(for: NSApplication.didBecomeActiveNotification)"))
        XCTAssertEqual(source.components(separatedBy: "store.requestRefresh(").count - 1, 2)
        XCTAssertTrue(source.contains("chatHistoryViewModel.hideGitChanges()"), "panel must close on leaving Code mode")

        let main = try sourceFile("Devgentic/Interfaces/Main/Views/MainApplicationView.swift")
        XCTAssertTrue(main.contains(".modifier(GitChangesWiringModifier("), "nothing applies the wiring")
        XCTAssertTrue(main.contains("projectPath: codeSessionManager.projectPath"))
        // The main body must observe the transition flag, never the snapshot's contents.
        let code = main.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        XCTAssertFalse(code.contains("gitChangesStore.snapshot"), "MainApplicationView re-renders on every refresh")
        XCTAssertTrue(code.contains("hasLoadedRepository: gitChangesStore.hasLoadedRepository"))
    }

    private func sourceFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return source
    }
}

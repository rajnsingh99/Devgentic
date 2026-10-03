// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingDownloadPollTests.swift
//  DevgenticTests
//
//  Timeout inventory D-24: the onboarding download poll never ended on failure or cancel — the
//  record left the active map in the same turn, so the terminal arms could not fire and the poll
//  spun every 250 ms with a stale stage. D-25's launch-instant guard is pinned here too.
//

import XCTest
@testable import devgentic

final class OnboardingDownloadPollTests: XCTestCase {

    private func verdict(_ status: DownloadRecordStatus?, progress: Double = 0.4, error: String? = nil,
                         installed: Bool = false, idle: TimeInterval = 0) -> OnboardingViewModel.PollVerdict {
        OnboardingViewModel.pollVerdict(status: status, progress: progress, errorMessage: error,
                                        installed: installed, secondsWithoutRecord: idle)
    }

    func testEveryTerminalStatusEndsThePoll() {
        XCTAssertEqual(verdict(.completed), .completed)
        XCTAssertEqual(verdict(.failed, error: "disk full"), .failed("disk full"))
        XCTAssertEqual(verdict(.cancelled), .cancelled)
        guard case .failed = verdict(.interrupted) else { return XCTFail("an interrupted download must end the poll") }
    }

    func testActiveStatusesKeepPolling() {
        for status in [DownloadRecordStatus.queued, .downloading, .paused] {
            XCTAssertEqual(verdict(status), .keepPolling, "\(status)")
        }
        XCTAssertEqual(verdict(.downloading, progress: 1.0), .completed)
    }

    /// A start that never registers a record fails after the grace instead of spinning forever.
    func testNoRecordFailsAfterTheGraceUnlessInstalled() {
        XCTAssertEqual(verdict(nil, idle: 5), .keepPolling)
        guard case .failed = verdict(nil, idle: OnboardingViewModel.recordAppearanceGrace + 1) else {
            return XCTFail("a download that never started must end the poll")
        }
        XCTAssertEqual(verdict(nil, installed: true, idle: 999), .completed)
    }

    /// Wiring: the loop falls back to the STORED record once the active one is gone, and decides
    /// through `pollVerdict`. Mutation: read only `activeRecord` again.
    func testThePollReadsTheStoredRecordAfterItLeavesTheActiveMap() throws {
        let vm = try source("Devgentic/Interfaces/Onboarding/OnboardingViewModel.swift")
        XCTAssertTrue(vm.contains("active ?? self.activeDownloadRecordID.flatMap { DownloadHistoryStore.shared.fetch(id: $0) }"),
                      "the poll can no longer see a failed or cancelled download")
        XCTAssertTrue(vm.contains("switch Self.pollVerdict("), "the poll no longer decides through pollVerdict")
    }

    /// D-25 wiring: the launch passes the instant captured before the launch work to both reconciles.
    func testTheLaunchReconcilesOnlyRowsFromBeforeThisLaunch() throws {
        let app = try source("Devgentic/DevgenticApp.swift")
        XCTAssertTrue(app.contains("DownloadHistoryStore.shared.reconcileOrphans(startedBefore: launchInstant)"))
        XCTAssertEqual(app.components(separatedBy: "WorkflowRunHistoryStore.shared.reconcileOrphans(startedBefore: launchInstant)").count - 1, 2)
        guard let captured = app.range(of: "let launchInstant = Date()"),
              let launchWork = app.range(of: "SkillStore.shared.configureContainer(container)") else { return XCTFail("launch sequence moved") }
        XCTAssertLessThan(captured.lowerBound, launchWork.lowerBound, "the instant must be captured BEFORE the launch work")
        let store = try source("Devgentic/Core/Persistence/SwiftData/DownloadHistoryStore.swift")
        XCTAssertTrue(store.contains("active.filter { $0.startedAt < cutoff }"), "the download reconcile ignores the launch instant")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text
    }
}

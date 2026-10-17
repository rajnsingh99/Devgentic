// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  Phase 5: the global ceiling — the outermost COMPUTE limit on any run, opened at admission.
//
//  ⚠️ Waits are bounded and outcomes are read from boxes: a sentinel that never fires must fail a
//  test, not hang the runner.
//

import XCTest
@testable import devgentic

final class GlobalCeilingTests: XCTestCase {

    // MARK: - The setting

    func testTheStoredSettingMeansWhatItSays() {
        XCTAssertEqual(LocalInferenceCoordinator.ceiling(stored: nil), LocalInferenceCoordinator.defaultGlobalCeiling,
                       "never set → the default")
        XCTAssertNil(LocalInferenceCoordinator.ceiling(stored: 0), "Off")
        XCTAssertEqual(LocalInferenceCoordinator.ceiling(stored: 7200), 7200)
        XCTAssertNil(LocalInferenceCoordinator.ceiling(stored: -5), "a broken value is not set, never an instant timeout")
        XCTAssertNil(LocalInferenceCoordinator.ceiling(stored: .infinity))
    }

    /// ⚠️ The default must sit above the largest preset PLUS the nesting reserve — otherwise every
    /// Code run's own 60 min limit would be silently shortened to fit inside the ceiling.
    func testTheDefaultNeverShortensTheCodePreset() {
        XCTAssertGreaterThan(LocalInferenceCoordinator.defaultGlobalCeiling,
                             CodeSessionManager.presetExecutionTimeout + ExecutionBudget.reserve)
    }

    func testTheStopMessageNamesTheSettingAndWhatWasNotCounted() {
        XCTAssertEqual(ActiveStreamManager.globalCeilingMessage(limit: 90 * 60),
                       "Run stopped: it reached the \(ToolExecutionMediator.describe(90 * 60)) maximum run time set in Settings → General. Time spent waiting for your approval or for the local model was not counted.")
    }

    // MARK: - Compute, not wall clock

    /// The composition the ceiling depends on: a local-model wait inside the run's owner chain
    /// pauses the ceiling's clock exactly as a HITL park does.
    func testWaitingForTheLocalModelDoesNotCountAgainstTheCeiling() async throws {
        let service = ExecutionSuspensionService.shared
        let scope = UUID()
        await service.registerScope(scope, conversationID: UUID(), attended: true)

        final class Box: @unchecked Sendable { var firedAt: Date? }
        let box = Box()
        let started = Date()
        let sentinel = Task {
            do {
                try await ComputeTimeoutSentinel.sleepUntilComputeExceeded(
                    limit: 0.3, scope: scope, logTag: "TEST", subject: "ceiling", consequence: "test")
            } catch is AgentExecutionError {
                box.firedAt = Date()
            } catch {}
        }

        // In line for the local model for 0.6 s — twice the limit.
        let wait = UUID()
        await ParkScope.$chain.withValue([scope]) { await service.beginQueueWait(wait) }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(box.firedAt, "the ceiling fired while the run was only waiting in line")
        await service.endQueueWait(wait)

        // Working again: now it must fire, about 0.3 s of compute later.
        let deadline = Date().addingTimeInterval(3)
        while box.firedAt == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        sentinel.cancel()
        let fired = try XCTUnwrap(box.firedAt, "the ceiling never fired once the run was computing")
        XCTAssertGreaterThan(fired.timeIntervalSince(started), 0.8, "the 0.6 s wait was credited")
        await service.unregisterScope(scope)
    }
}

/// ⚠️ WIRING. A cut call fails no unit test above. Source-scanned over the joined, comment-stripped
/// body of `ActiveStreamManager`.
final class GlobalCeilingWiringTests: XCTestCase {

    private func source() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Devgentic").path) else {
            throw XCTSkip("sources not reachable — running outside a checkout")
        }
        return try String(contentsOf: repoRoot.appendingPathComponent("Devgentic/Core/Utils/ActiveStreamManager.swift"), encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Opened AFTER the local lock is taken (queue waits never count), around the run's work, as
    /// both the outermost budget frame and a member of the owner chain.
    func testTheCeilingWrapsTheRunFromAdmission() throws {
        let code = try source()
        let pattern = #"switch localAcquire \{[\s\S]{0,1600}?let ceiling = LocalInferenceCoordinator\.globalCeiling[\s\S]{0,1600}?await ParkScope\.withScope\(ceilingScope, conversationID: conversationID\) \{\s*await ExecutionBudget\.\$frames\.withValue\(ExecutionBudget\.frames \+ \(ceilingFrame\.map \{ \[\$0\] \} \?\? \[\]\)\) \{\s*let capabilityRouter = CapabilityCardRouter"#
        XCTAssertNotNil(code.range(of: pattern, options: .regularExpression))
        XCTAssertNotNil(code.range(of: #"Task \{ @MainActor \[weak self\] in\s*await self\?\.enforceGlobalCeiling\(limit, scope: ceilingScope, on: agentMessage\)"#,
                                   options: .regularExpression), "the sentinel must run for every run with a ceiling")
        XCTAssertNotNil(code.range(of: #"ceilingTask\?\.cancel\(\)\s*self\.removeTask\(for: agentMessage\.id\)\s*onComplete\(\)"#,
                                   options: .regularExpression), "the sentinel must stop when the run ends")
    }

    /// Stamped TIMED OUT before the cancel (finalize would otherwise write "Cancelled by user"), only
    /// for a run still live, and the run's own parks are drained.
    func testExpiryStampsTimedOutThenCancels() throws {
        let code = try source()
        let pattern = #"catch is AgentExecutionError \{\s*guard activeStreams\[agentMessage\.id\] != nil else \{[^}]*?return\s*\}\s*agentMessage\.terminalOutcome = \.timedOut\s*agentMessage\.terminalReason = Self\.globalCeilingMessage\(limit: limit\)\s*cancelStream\(for: agentMessage\.id\)\s*let parks = await ExecutionSuspensionService\.shared\.cancel\(scope: scope\)"#
        XCTAssertNotNil(code.range(of: pattern, options: .regularExpression))
    }
}

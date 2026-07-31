//
//  LoopHITLForwardingTests.swift
//  DevgenticTests
//
//  A loop node consumes its body's event stream and re-emits what the outer run should see. Its
//  `default: break` arm suppressed "inner workflow orchestration events" — and that caught the
//  three HITL requests too.
//
//  Each of those carries an `operationID` that the inner execution is ALREADY suspended on,
//  waiting for `ExecutionSuspensionService` to resume it. Suppress the event and no banner is
//  shown, so nobody can answer, so the suspension never resolves: the workflow hangs with no
//  error, no timeout and nothing in the timeline. A Gate node inside a loop body did this
//  silently, and Action-node confirmations (added the same day) widened the reachable surface.
//
//  This is a source-level guard rather than an execution test because reproducing the hang means
//  running a real workflow and waiting for a deadlock that, by definition, never ends.
//

import XCTest
@testable import devgentic

final class LoopHITLForwardingTests: XCTestCase {

    /// The three events that suspend an execution. Any of them dropped by a stream-forwarding
    /// switch is a hang, not a missing log line.
    private static let suspendingEvents = ["requestConfirmation", "requestGate", "requestClarification"]

    /// The loop body's forwarding switch must handle all three explicitly. If one falls through
    /// to `default`, it is swallowed.
    func testLoopBodyForwardsEverySuspendingEvent() throws {
        let source = try Self.readWorkflowExecutor()

        // The loop body's switch is the one that binds `bodyOutcome` — anchor on that so this
        // test cannot silently start reading some other switch after a refactor.
        guard let bodyRange = source.range(of: "for try await event in bodyStream") else {
            return XCTFail("could not find the loop body's event loop — this test is now checking nothing")
        }
        let bodySwitch = String(source[bodyRange.lowerBound...].prefix(6000))
        XCTAssertTrue(bodySwitch.contains("bodyOutcome"), "anchored on the wrong block")

        for event in Self.suspendingEvents {
            XCTAssertTrue(bodySwitch.contains("case .\(event)"), """
                the loop body does not forward `.\(event)`. It carries an operationID the inner \
                run is suspended on — dropping it hangs the workflow forever with no error.
                """)
        }
    }

    /// Forwarding must preserve the `operationID` verbatim. A regenerated id resumes nothing:
    /// the inner execution waits on the original, so the workflow hangs exactly as if the event
    /// had been dropped — but with a banner on screen, which is worse because it looks answered.
    func testForwardedEventsPreserveTheOperationID() throws {
        let source = try Self.readWorkflowExecutor()
        guard let bodyRange = source.range(of: "for try await event in bodyStream") else {
            return XCTFail("could not find the loop body's event loop")
        }
        let bodySwitch = String(source[bodyRange.lowerBound...].prefix(6000))

        XCTAssertFalse(bodySwitch.contains("operationID: UUID()"),
                       "a forwarded HITL event minted a new operationID — the inner run is "
                       + "suspended on the original and will never resume")
        XCTAssertTrue(bodySwitch.contains("operationID: operationID"),
                      "forwarded events must pass the operationID straight through")
    }

    private static func readWorkflowExecutor() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WorkflowGen
            .deletingLastPathComponent()   // Backends
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // DevgenticTests
            .deletingLastPathComponent()   // repo root
        let url = repoRoot.appendingPathComponent("Devgentic/Core/Backends/WorkflowGen/WorkflowExecutor.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("WorkflowExecutor.swift not reachable — running outside a checkout")
        }
        XCTAssertTrue(text.contains("func execute"), "read a file that is not WorkflowExecutor")
        return text
    }
}

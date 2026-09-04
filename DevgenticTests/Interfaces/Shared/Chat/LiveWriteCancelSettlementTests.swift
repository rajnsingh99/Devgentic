//
//  LiveWriteCancelSettlementTests.swift
//  DevgenticTests
//
//  [CF-9] A live agent-write tab is opened from `.toolCall` and settled only by an
//  `AgentLiveWriteEvent.completed`, which `ActiveStreamManager` posts from `.toolSucceeded` /
//  `.toolFailed`. Stop pressed while a write is parked throws `CancellationError` without
//  yielding `.toolFailed`, so neither post happens and the tab keeps `liveState == .active`
//  forever — orange "Agent is writing this file" banner, pulsing pill, and a proposal that never
//  reached disk never marked rejected.
//
//  The fix reuses the dangling-row close that already runs on every finalize path: it now REPORTS
//  which rows it settled, and the caller posts the missing completion for each one that was a
//  live write. These tests pin the reporting contract and the payload derived from it — the
//  `NotificationCenter` post itself lives inside `finalizeMessage`, which needs a live stream and
//  is not drivable here (see `testUnobservable_postSiteRequiresLiveStream`).
//
//  [CF-44] Also covers the closer's use from the two paths a force-quit leaves behind.
//

import XCTest
@testable import devgentic

@MainActor
final class LiveWriteCancelSettlementTests: XCTestCase {

    // MARK: - Fixtures

    private func writeParams(path: String, content: String = "let x = 1") -> String {
        let object: [String: Any] = ["path": path, "content": content]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private func executingRow(name: String, params: String) -> TimelineEvent {
        .toolExecution(ToolExecutionData(id: UUID(), name: name, params: params,
                                         output: nil, isSuccess: nil, isExecuting: true))
    }

    private func completedRow(name: String, params: String) -> TimelineEvent {
        .toolExecution(ToolExecutionData(id: UUID(), name: name, params: params,
                                         output: "ok", isSuccess: true, isExecuting: false))
    }

    private func agentMessage() -> ChatMessage {
        ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""))
    }

    // MARK: - CF-9 · the closer reports what it settled

    /// The whole fix rests on `closeReporting` naming the abandoned calls. Before it, the closer
    /// returned only a COUNT, so the caller could not tell a stranded `write_file` from a
    /// stranded `execute_shell` and had no params to build a payload from.
    func testCloseReportingNamesEveryRowItSettled() {
        let message = agentMessage()
        let params = writeParams(path: "/tmp/Main.swift")
        message.timelineEvents = [
            executingRow(name: "write_file", params: params),
            completedRow(name: "fs_read", params: "{}"),
            executingRow(name: "execute_shell", params: "{\"command\":\"ls\"}")
        ]

        let closed = message.closeDanglingToolRowsReporting(outcome: .cancelled)

        XCTAssertEqual(closed.count, 2, "Both executing rows must be reported; the completed one must not.")
        XCTAssertEqual(closed.map(\.name).sorted(), ["execute_shell", "write_file"])
        XCTAssertEqual(closed.first(where: { $0.name == "write_file" })?.params, params,
                       "The params must survive verbatim — the completion payload is derived from them.")
    }

    /// A clean run has no executing rows, so the fix must be a no-op there. This is the control
    /// that keeps the new post from firing on every successful message.
    func testCleanRunReportsNothing() {
        let message = agentMessage()
        message.timelineEvents = [completedRow(name: "write_file", params: writeParams(path: "/tmp/A.swift"))]

        XCTAssertTrue(message.closeDanglingToolRowsReporting(outcome: .completed).isEmpty)
    }

    /// The reported rows are what `finalizeMessage` feeds to `AgentLiveWriteEvent.completed`.
    /// This is the end-to-end shape of the fix minus the notification hop: an abandoned
    /// `write_file` must yield a payload addressed to the tab's identity (its resolved path).
    func testAbandonedWriteYieldsAFailedCompletionPayload() {
        let message = agentMessage()
        let conversationID = UUID()
        message.timelineEvents = [executingRow(name: "write_file", params: writeParams(path: "/tmp/Main.swift"))]

        let closed = message.closeDanglingToolRowsReporting(outcome: .cancelled)
        let payloads = closed.compactMap {
            AgentLiveWriteEvent.completed(toolName: $0.name, params: $0.params,
                                          isSuccess: false, preWriteContent: nil,
                                          conversationID: conversationID)
        }

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads.first?.fileName, "Main.swift")
        XCTAssertEqual(payloads.first?.conversationID, conversationID)
        XCTAssertEqual(payloads.first?.isSuccess, false,
                       "The write did not land — a stranded tab must settle as rejected, not as written.")
    }

    /// A stranded row for a tool that never opened a live tab must produce NO payload, or the
    /// view model would look up a tab that does not exist on every cancelled shell command.
    /// `AgentLiveWriteEvent.completed` already encodes that rule; this pins that the fix routes
    /// through it rather than assuming every closed row is a write.
    func testNonWriteRowsProduceNoCompletion() {
        let message = agentMessage()
        message.timelineEvents = [
            executingRow(name: "execute_shell", params: "{\"command\":\"ls\"}"),
            executingRow(name: "fs_read", params: "{\"path\":\"/tmp/A.swift\"}")
        ]

        let payloads = message.closeDanglingToolRowsReporting(outcome: .cancelled).compactMap {
            AgentLiveWriteEvent.completed(toolName: $0.name, params: $0.params,
                                          isSuccess: false, preWriteContent: nil,
                                          conversationID: UUID())
        }

        XCTAssertTrue(payloads.isEmpty)
    }

    /// Nested rows are the common shape (capability cards are on for most agent runs), and the
    /// closer already walks them. If the report dropped nested rows, a write abandoned inside a
    /// plan step would still strand its tab — the CH25 defect one level down.
    func testNestedAbandonedWriteIsAlsoReported() {
        let message = agentMessage()
        let params = writeParams(path: "/tmp/Nested.swift")
        var plan = PlanRunData(phase: .executing, steps: [
            PlanStepData(id: "step_1", title: "Write it", status: .running)
        ])
        plan.steps[0].events = [executingRow(name: "write_file", params: params)]
        message.timelineEvents = [.planExecution(plan)]

        let closed = message.closeDanglingToolRowsReporting(outcome: .cancelled)

        XCTAssertEqual(closed.count, 1, "A write abandoned inside a plan step must be reported too.")
        XCTAssertEqual(closed.first?.params, params)
    }

    // MARK: - CF-44 · unresumable finalize closes its rows

    /// `finalizeUnresumable` is the last word on a run — no resume follows it — so a row left
    /// executing there can never be settled by anything else.
    func testClosingOnAnUnresumableRunSettlesTheRow() {
        let message = agentMessage()
        message.timelineEvents = [executingRow(name: "fs_read", params: "{}")]

        let closed = message.closeDanglingToolRows(outcome: .cancelled)

        XCTAssertEqual(closed, 1)
        guard case .toolExecution(let data) = message.timelineEvents[0] else {
            return XCTFail("Expected a tool row")
        }
        XCTAssertFalse(data.isExecuting, "A settled row must not keep animating a spinner.")
        XCTAssertNotNil(data.output, "A settled row must say what happened to it.")
    }

    // MARK: - Declared gaps

    /// The `NotificationCenter.post` in `ActiveStreamManager.finalizeMessage` is not reachable
    /// from a unit test: `finalizeMessage` is private to a live stream task and needs a backend,
    /// a trace recorder and a persistence service. What IS testable — which rows get reported,
    /// and what payload each yields — is pinned above; the remaining hop is one `post` call per
    /// reported row. Verify on device: start an agent write, press Stop while the approval
    /// banner is up, and confirm the tab's orange banner turns to "the write was not applied".
    func testUnobservable_postSiteRequiresLiveStream() throws {
        throw XCTSkip("Declared gap: the post site inside finalizeMessage needs a live stream; see the comment.")
    }
}

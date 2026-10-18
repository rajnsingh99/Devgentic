// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowBatch5Tests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class WorkflowBatch5Tests: XCTestCase {

    private var mockProvider: MockWorkflowStreamProvider!
    private var traceContext: TraceContext!
    private var innerBuilders: [InnerWorkflowBuilder] = []
    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        mockProvider = MockWorkflowStreamProvider()
        traceContext = TestTraceContext.make()
        innerBuilders = []
        tempFiles = []
    }

    override func tearDown() {
        for builder in innerBuilders { builder.cleanup() }
        innerBuilders = []
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStream(
        _ scenario: WorkflowTestScenario,
        userInput: String = "Test input",
        attachmentContext: String? = nil
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        WorkflowExecutor(workflowProfileID: UUID()).executeWorkflow(
            userInput: userInput,
            conversationID: UUID(),
            attachmentContext: attachmentContext,
            traceContext: traceContext,
            onTraceUpdate: { _ in },
            layout: scenario.layout,
            profileMap: scenario.profileMap,
            streamProvider: mockProvider
        )
    }

    /// Collects the whole run. Any HITL request is a test failure unless `answerGate` handles it.
    ///
    /// ⚠️ A gate is answered only once its suspension is REGISTERED: a resume that arrives first is
    /// dropped, and the run then parks forever. So this polls the service rather than sleeping.
    private func collect(
        _ stream: AsyncThrowingStream<AgentStreamEvent, Error>,
        answerGate: String?? = .none
    ) async throws -> [AgentStreamEvent] {
        var events: [AgentStreamEvent] = []
        for try await event in stream {
            events.append(event)
            if case .requestGate(_, _, let operationID, _, _, _, _, _) = event, case .some(let choice) = answerGate {
                for _ in 0..<200 where !(await ExecutionSuspensionService.shared.hasPendingSuspensions()) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                await ExecutionSuspensionService.shared.resumeGate(for: operationID, chosenOption: choice, resolvedBy: .localUI)
            }
        }
        return events
    }

    private func runFinishedFlags(_ events: [AgentStreamEvent]) -> [Bool] {
        events.compactMap {
            if case .workflowRunFinished(let had) = $0 { return had }
            return nil
        }
    }

    private func ran(_ profileID: UUID?) -> Bool {
        guard let profileID else { return false }
        return mockProvider.invocations.contains { $0.profileID == profileID }
    }

    // MARK: - CR-46: a nested workflow's absorbed failure reaches the parent

    /// Child: Flaky fails → its error port → Handler answers. The child's run "completes" (a
    /// successful terminal exists) and reports `hadGenuineFailure: true`. Before the fix the parent
    /// suppressed that signal unread: the sub-workflow node went green and the parent's verdict
    /// was `false`, so the persisted record said the run was clean.
    func testCR46_SubWorkflowThatAbsorbedAFailure_CompletesWithWarnings_AndParentVerdictCountsIt() async throws {
        let inner = InnerWorkflowBuilder()
        let flaky = inner.addBotNode(name: "Flaky Step")
        let handler = inner.addBotNode(name: "Recovery")
        inner.connect(from: flaky, to: handler, portLabel: WorkflowEdge.errorPortLabel)
        inner.save()
        innerBuilders.append(inner)

        let scenario = WorkflowTestScenario()
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }
        let sub = scenario.addSubWorkflowNode(name: "Nested", workflowProfileID: inner.workflowProfileID)
        let consumer = scenario.addBotNode(name: "Consumer")
        scenario.connect(from: sub, to: consumer)

        mockProvider.scriptError(for: inner.profileID(for: flaky)!, error: NSError(domain: "cr46", code: 7))
        mockProvider.scriptStream(for: inner.profileID(for: handler)!, events: [.content("recovered answer")])
        mockProvider.scriptStream(for: scenario.profileID(for: consumer)!, events: [.content("final")])

        let events = try await collect(makeStream(scenario))

        XCTAssertEqual(WorkflowStreamCollector.nodeCompletedWithWarnings(from: events), [sub],
                       "the sub-workflow node must complete WITH WARNINGS, not green")
        XCTAssertFalse(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == sub },
                       "the child's answer is real, so the node still completes rather than fails")
        XCTAssertTrue(ran(scenario.profileID(for: consumer)), "its output still flows downstream")

        let warning = events.compactMap { event -> String? in
            if case .warning(.midRunError, let message, _, let source) = event, source == sub { return message }
            return nil
        }.first
        XCTAssertTrue(warning?.contains("Flaky Step") == true,
                      "the node's timeline must name the inner node that failed; got \(String(describing: warning))")

        XCTAssertEqual(runFinishedFlags(events), [true],
                       "the PARENT's verdict must count the absorbed failure (one verdict: the child's own stays suppressed)")
        XCTAssertEqual(WorkflowStreamCollector.terminalOutcomes(from: events).last?.outcome, .completed,
                       "the chat bubble's outcome is unchanged: the run did answer")
    }

    /// The negative twin: a clean child leaves everything clean. Without it, a fix that marked
    /// EVERY sub-workflow as warned would pass the test above.
    func testCR46_CleanSubWorkflow_StaysCleanEverywhere() async throws {
        let inner = InnerWorkflowBuilder()
        let body = inner.addBotNode(name: "Body")
        inner.save()
        innerBuilders.append(inner)

        let scenario = WorkflowTestScenario()
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }
        let sub = scenario.addSubWorkflowNode(name: "Nested", workflowProfileID: inner.workflowProfileID)

        mockProvider.scriptStream(for: inner.profileID(for: body)!, events: [.content("fine")])

        let events = try await collect(makeStream(scenario))

        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedEvents(from: events).contains { $0.nodeID == sub })
        XCTAssertTrue(WorkflowStreamCollector.nodeCompletedWithWarnings(from: events).isEmpty)
        XCTAssertEqual(runFinishedFlags(events), [false])
    }

    func testCR46_AbsorbedChildFailures_KeysOffTheChildVerdict() {
        let id = UUID()
        XCTAssertEqual(WorkflowExecutor.absorbedChildFailures(hadGenuineFailure: false, failedInnerNodes: [id: "A: boom"], subWorkflowName: "S"), [],
                       "no genuine failure in the child's own verdict means clean, whatever events preceded it")
        XCTAssertEqual(WorkflowExecutor.absorbedChildFailures(hadGenuineFailure: true, failedInnerNodes: [id: "A: boom"], subWorkflowName: "S"), ["A: boom"])
        XCTAssertEqual(WorkflowExecutor.absorbedChildFailures(hadGenuineFailure: true, failedInnerNodes: [:], subWorkflowName: "S"),
                       ["a node nested inside 'S' failed"],
                       "a failure one level deeper (its events suppressed by the child) is still reported")
    }

    // MARK: - CR-47: dismissing a Gate is not an expiry

    private func gateScenario(timeout: TimeInterval?) -> (WorkflowTestScenario, gate: UUID, approve: UUID, handler: UUID) {
        let scenario = WorkflowTestScenario()
        let source = scenario.addBotNode(name: "Source")
        let gate = scenario.addGateNode(name: "Sign-off", timeout: timeout)
        let approve = scenario.addBotNode(name: "Approved Path")
        let handler = scenario.addBotNode(name: "Error Handler")
        scenario.connect(from: source, to: gate)
        scenario.connect(from: gate, to: approve, portLabel: "Approve")
        scenario.connect(from: gate, to: handler, portLabel: WorkflowEdge.errorPortLabel)
        mockProvider.scriptStream(for: scenario.profileID(for: source)!, events: [.content("draft")])
        mockProvider.scriptStream(for: scenario.profileID(for: approve)!, events: [.content("should not run")])
        mockProvider.scriptStream(for: scenario.profileID(for: handler)!, events: [.content("should not run")])
        return (scenario, gate, approve, handler)
    }

    /// The reported shape: a Gate with NO timeout, dismissed (resolved with no option). It failed
    /// as `.gateExpired(limit: 0)` and ran the error handler for a choice the user declined.
    func testCR47_DismissedGateWithoutTimeout_IsCancelled_AndTheErrorPortDoesNotFire() async throws {
        let (scenario, gate, approve, handler) = gateScenario(timeout: nil)

        let events = try await collect(makeStream(scenario), answerGate: .some(nil))

        XCTAssertTrue(WorkflowStreamCollector.nodeCancelledEvents(from: events).contains { $0.nodeID == gate },
                      "a dismissed gate settles as cancelled")
        XCTAssertFalse(WorkflowStreamCollector.nodeFailedEvents(from: events).contains { $0.nodeID == gate },
                       "a dismissal is not a failure (it was reported as 'expired within 0 seconds')")
        XCTAssertFalse(ran(scenario.profileID(for: handler)), "the error handler must not run for a dismissal")
        XCTAssertFalse(ran(scenario.profileID(for: approve)), "and no option branch runs either")
    }

    /// Dismissed BEFORE a configured timeout: still a dismissal. This is what pins that the
    /// expiry is decided by the TIMER having fired, not by a timeout being configured.
    func testCR47_DismissedGateWithTimeout_IsStillADismissal() async throws {
        let (scenario, gate, _, handler) = gateScenario(timeout: 30)

        let events = try await collect(makeStream(scenario), answerGate: .some(nil))

        XCTAssertTrue(WorkflowStreamCollector.nodeCancelledEvents(from: events).contains { $0.nodeID == gate })
        XCTAssertFalse(ran(scenario.profileID(for: handler)))
    }

    /// The other half: an unanswered gate whose timer fires still EXPIRES onto the error port.
    func testCR47_GateWhoseTimerFires_StillExpiresOntoTheErrorPort() async throws {
        let (scenario, gate, approve, handler) = gateScenario(timeout: 0.3)

        let events = try await collect(makeStream(scenario))   // nobody answers

        let failure = WorkflowStreamCollector.nodeFailedEvents(from: events).first { $0.nodeID == gate }
        XCTAssertNotNil(failure, "an expired gate fails")
        XCTAssertTrue(ran(scenario.profileID(for: handler)), "and its error port runs the handler")
        XCTAssertFalse(ran(scenario.profileID(for: approve)))
    }

    func testCR47_UnansweredGateSettlement() {
        if case .failed(.gateExpired(let limit)) = WorkflowExecutor.unansweredGateSettlement(expired: true, limit: 5).status {
            XCTAssertEqual(limit, 5)
        } else {
            XCTFail("timer fired with a limit → expired")
        }
        if case .canceled = WorkflowExecutor.unansweredGateSettlement(expired: false, limit: 5).status {} else {
            XCTFail("no timer fire → dismissed")
        }
        if case .canceled = WorkflowExecutor.unansweredGateSettlement(expired: false, limit: nil).status {} else {
            XCTFail("no timeout at all → dismissed, never 'expired within 0 seconds'")
        }
    }

    // MARK: - CR-48: Router whole-value comparisons

    private func sentimentRouter(_ scenario: WorkflowTestScenario, op: ConditionOp = .equals, value: String = "positive") -> (router: UUID, hit: UUID, other: UUID) {
        let router = scenario.addConditionNode(
            name: "Sentiment",
            rules: [ConditionRule(label: "Hit", field: .upstreamOutput, op: op, value: value)],
            fallbackLabel: "Other")
        let hit = scenario.addBotNode(name: "Hit Path")
        let other = scenario.addBotNode(name: "Other Path")
        scenario.connect(from: router, to: hit, portLabel: "Hit")
        scenario.connect(from: router, to: other, portLabel: "Other")
        mockProvider.scriptStream(for: scenario.profileID(for: hit)!, events: [.content("hit")])
        mockProvider.scriptStream(for: scenario.profileID(for: other)!, events: [.content("other")])
        return (router, hit, other)
    }

    /// Models end their answer with a newline. `"positive\n"` never equalled "positive".
    func testCR48_EqualsMatchesAModelAnswerWithATrailingNewline() async throws {
        let scenario = WorkflowTestScenario()
        let classifier = scenario.addBotNode(name: "Classifier")
        let (router, hit, other) = sentimentRouter(scenario)
        scenario.connect(from: classifier, to: router)
        mockProvider.scriptStream(for: scenario.profileID(for: classifier)!, events: [.content("positive\n")])

        _ = try await collect(makeStream(scenario))

        XCTAssertTrue(ran(scenario.profileID(for: hit)), "\"positive\\n\" equals \"positive\"")
        XCTAssertFalse(ran(scenario.profileID(for: other)))
    }

    /// At an ENTRY Router the run's attachments were folded into the compared text, so `equals`
    /// could never match there.
    func testCR48_EntryRouterEqualsIgnoresTheFoldedAttachments() async throws {
        let scenario = WorkflowTestScenario()
        let (_, hit, other) = sentimentRouter(scenario, value: "approve")

        _ = try await collect(makeStream(scenario, userInput: "approve",
                                         attachmentContext: "<file name=\"notes.txt\">some attached text</file>"))

        XCTAssertTrue(ran(scenario.profileID(for: hit)), "the message alone is compared")
        XCTAssertFalse(ran(scenario.profileID(for: other)))
    }

    /// ...while `contains` still SEARCHES the attachments, which is why they are folded at all.
    func testCR48_EntryRouterContainsStillSearchesTheAttachments() async throws {
        let scenario = WorkflowTestScenario()
        let (_, hit, other) = sentimentRouter(scenario, op: .contains, value: "INVOICE-42")

        _ = try await collect(makeStream(scenario, userInput: "please file this",
                                         attachmentContext: "<file name=\"a.txt\">INVOICE-42 total 10</file>"))

        XCTAssertTrue(ran(scenario.profileID(for: hit)))
        XCTAssertFalse(ran(scenario.profileID(for: other)))
    }

    func testCR48_IsEmptyMatchesAWhitespaceOnlyAnswer() async throws {
        let scenario = WorkflowTestScenario()
        let producer = scenario.addBotNode(name: "Producer")
        let (router, hit, other) = sentimentRouter(scenario, op: .isEmpty, value: "")
        scenario.connect(from: producer, to: router)
        mockProvider.scriptStream(for: scenario.profileID(for: producer)!, events: [.content("  \n")])

        _ = try await collect(makeStream(scenario))

        XCTAssertTrue(ran(scenario.profileID(for: hit)))
        XCTAssertFalse(ran(scenario.profileID(for: other)))
    }

    // MARK: - CR-49: a document is inlined at its first reader only

    private static let marker = "CR49-UNIQUE-DOCUMENT-BODY"

    private func makeDocument() throws -> MediaArtifact {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cr49-\(UUID().uuidString).txt")
        try "Quarterly report. \(Self.marker). End.".write(to: url, atomically: true, encoding: .utf8)
        tempFiles.append(url)
        return MediaArtifact(kind: .document, reference: .diskPath(url), mimeType: "text/plain", label: "report.txt")
    }

    private func context(for profileID: UUID?) -> WorkflowExecutionContext? {
        mockProvider.workflowInvocations.first { $0.profileID == profileID }?.context
    }

    /// Producer → A → B → C. Only A inlines the text; B and C still see the document in their
    /// manifest (so a tool-using node can open it) but are not billed for it again.
    func testCR49_ChainInlinesTheDocumentAtTheFirstReaderOnly() async throws {
        let scenario = WorkflowTestScenario()
        let producer = scenario.addBotNode(name: "Producer")
        let a = scenario.addBotNode(name: "Reader A")
        let b = scenario.addBotNode(name: "Reader B")
        let c = scenario.addBotNode(name: "Reader C")
        scenario.connect(from: producer, to: a)
        scenario.connect(from: a, to: b)
        scenario.connect(from: b, to: c)
        let document = try makeDocument()
        mockProvider.scriptStream(for: scenario.profileID(for: producer)!, events: [.content("wrote it"), .artifactProduced(document)])
        for node in [a, b, c] {
            mockProvider.scriptStream(for: scenario.profileID(for: node)!, events: [.content("summary")])
        }

        _ = try await collect(makeStream(scenario))

        XCTAssertTrue(context(for: scenario.profileID(for: a))?.upstreamArtifactText.contains(Self.marker) == true,
                      "the first reader gets the full text")
        for (name, node) in [("B", b), ("C", c)] {
            let ctx = context(for: scenario.profileID(for: node))
            XCTAssertEqual(ctx?.upstreamArtifactText, "", "Reader \(name) must not be billed for the document again")
            XCTAssertEqual(ctx?.upstreamArtifacts.map(\.id), [document.id], "Reader \(name) still sees it in the manifest")
        }
    }

    /// The escape hatch: wired straight from the producer, a later node reads it again, even though
    /// its other upstream already did ("every carrier read it", not "any").
    func testCR49_ANodeWiredDirectlyToTheProducerStillReadsIt() async throws {
        let scenario = WorkflowTestScenario()
        let producer = scenario.addBotNode(name: "Producer")
        let a = scenario.addBotNode(name: "Reader A")
        let b = scenario.addBotNode(name: "Reader B")
        scenario.connect(from: producer, to: a)
        scenario.connect(from: a, to: b)
        scenario.connect(from: producer, to: b)
        let document = try makeDocument()
        mockProvider.scriptStream(for: scenario.profileID(for: producer)!, events: [.content("wrote it"), .artifactProduced(document)])
        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("summary")])
        mockProvider.scriptStream(for: scenario.profileID(for: b)!, events: [.content("checked")])

        _ = try await collect(makeStream(scenario))

        XCTAssertTrue(context(for: scenario.profileID(for: b))?.upstreamArtifactText.contains(Self.marker) == true)
    }

    /// A structural node between the producer and the first reader reads nothing, so the reader
    /// after it is still the FIRST reader.
    func testCR49_AStructuralHopDoesNotCountAsReading() async throws {
        let scenario = WorkflowTestScenario()
        let producer = scenario.addBotNode(name: "Producer")
        let code = scenario.addCodeNode(name: "Reshape")
        let a = scenario.addBotNode(name: "Reader A")
        scenario.connect(from: producer, to: code)
        scenario.connect(from: code, to: a)
        let document = try makeDocument()
        mockProvider.scriptStream(for: scenario.profileID(for: producer)!, events: [.content("wrote it"), .artifactProduced(document)])
        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("summary")])

        _ = try await collect(makeStream(scenario))

        XCTAssertTrue(context(for: scenario.profileID(for: a))?.upstreamArtifactText.contains(Self.marker) == true)
    }

    func testCR49_DocumentsAlreadyRead_RequiresEveryCarrierToHaveReadIt() {
        let doc = MediaArtifact(kind: .document, reference: .ephemeralData(Data()), mimeType: "text/plain")
        let image = MediaArtifact(kind: .image, reference: .ephemeralData(Data()), mimeType: "image/png")
        func envelope(_ artifacts: [MediaArtifact], read: Set<UUID>) -> NodeResultEnvelope {
            NodeResultEnvelope(taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(), profileName: "n",
                               profileType: .bot, status: .completed, output: "", artifacts: artifacts,
                               metadata: .simple(start: Date(), end: Date(), output: ""), readDocumentIDs: read)
        }
        XCTAssertEqual(WorkflowExecutor.documentsAlreadyRead(upstream: [envelope([doc], read: [doc.id])]), [doc.id])
        XCTAssertEqual(WorkflowExecutor.documentsAlreadyRead(upstream: [envelope([doc], read: [doc.id]), envelope([doc], read: [])]), [],
                       "one carrier that has not read it means a path on which nobody did")
        XCTAssertEqual(WorkflowExecutor.documentsAlreadyRead(upstream: [envelope([image], read: [image.id])]), [],
                       "only documents are ever inlined, so only documents count")
    }
}

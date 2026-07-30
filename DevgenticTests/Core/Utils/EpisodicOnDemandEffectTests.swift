//
//  EpisodicOnDemandEffectTests.swift
//  DevgenticTests
//
//  Phase 3 of the episodic `<effect>` track: the pointer strategy had no route to effect
//  information AT ALL. Its skeleton omitted `<effect>` (by design) and
//  `ConversationHistoryTool` — the on-demand half the design promises — returned only tool
//  name, params, status and error. So `.pointer`, which Code mode hardcodes, could not
//  answer "undo that" by any path.
//
//  Also covers the append-without-a-snapshot asymmetry: `resolve` returns nil there, right
//  for a timeline chip and wrong for memory, where silence reads as "nothing happened".
//

import XCTest
@testable import devgentic

final class EpisodicOnDemandEffectTests: XCTestCase {

    private let convID = UUID()
    private let t0 = Date(timeIntervalSince1970: 3_000_000)

    // MARK: - Fixtures

    private func measured(_ fileName: String) -> ActionEffect {
        ActionEffect(path: "/Users/me/\(fileName)", linesAdded: 14, linesRemoved: 5,
                     diff: "+    public abstract double calculateArea();\n-    public double area();",
                     isTruncated: false)
    }

    private func write(_ fileName: String, effect: ActionEffect?) -> ToolExecutionData {
        var data = ToolExecutionData(
            id: UUID(), name: "write_file",
            params: #"{"path":"/Users/me/\#(fileName)"}"#,
            output: "Successfully wrote", isSuccess: true, isExecuting: false
        )
        data.effect = effect
        return data
    }

    private func history(files: [String]) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for (index, name) in files.enumerated() {
            messages.append(ChatMessage(id: UUID(), conversationId: convID,
                                        timestamp: t0.addingTimeInterval(TimeInterval(index * 2)),
                                        sender: .user, content: .plainText("Edit \(name)")))
            let agent = ChatMessage(id: UUID(), conversationId: convID,
                                    timestamp: t0.addingTimeInterval(TimeInterval(index * 2 + 1)),
                                    sender: .agent, content: .plainText("Done."))
            agent.timelineEvents = [.toolExecution(write(name, effect: measured(name)))]
            messages.append(agent)
        }
        return messages
    }

    /// `Arguments` exposes only a decoder init, so build it the way the tool really receives
    /// it — through JSON. Exercises the dynamic-key decoding too.
    private func args(_ index: Int) throws -> ConversationHistoryTool.Arguments {
        try JSONDecoder().decode(ConversationHistoryTool.Arguments.self,
                                 from: Data("{\"index\":\(index)}".utf8))
    }

    // MARK: - The pointer skeleton knows a file changed

    /// Counts, no body. Without this the pointer strategy — which Code mode hardcodes — has
    /// no memory whatsoever of its own edits.
    func testPointerSkeletonCarriesCountsWithoutTheBody() {
        let xml = EpisodicHistoryFormatter.buildPointerHistoryString(from: history(files: ["Shape.java"]))

        XCTAssertTrue(xml.contains("<effect file=\"Shape.java\""), "the skeleton must record the change")
        XCTAssertTrue(xml.contains("added=\"14\""))
        XCTAssertTrue(xml.contains("removed=\"5\""))
        XCTAssertTrue(xml.contains("diff=\"on_demand\""))
        XCTAssertFalse(xml.contains("calculateArea"), "the body stays out of the skeleton:\n\(xml)")
    }

    /// A bodyless effect is self-closing — an empty open/close pair wastes ~26 chars on
    /// every action, and every pointer effect is bodyless.
    func testBodylessEffectIsSelfClosing() {
        let xml = EpisodicHistoryFormatter.buildPointerHistoryString(from: history(files: ["Shape.java"]))
        XCTAssertTrue(xml.contains("diff=\"on_demand\"/>"), "expected self-closing:\n\(xml)")
        XCTAssertFalse(xml.contains("</effect>"))
    }

    /// `on_demand` and `elided` both mean "no body", but only one is retrievable by the
    /// model. Conflating them would either promise a fetch that does not exist or hide one
    /// that does.
    func testOnDemandIsDistinctFromElided() {
        let pointer = EpisodicHistoryFormatter.renderEffect(measured("A.java"), diff: .onDemand)
        let elided = EpisodicHistoryFormatter.renderEffect(measured("A.java"), diff: .elided)

        XCTAssertTrue(pointer.contains("diff=\"on_demand\""))
        XCTAssertFalse(pointer.contains("diff=\"elided\""))
        XCTAssertTrue(elided.contains("diff=\"elided\""))
        XCTAssertFalse(elided.contains("diff=\"on_demand\""))
    }

    /// The skeleton names the call that returns the body, in the same turn.
    func testPointerTurnPairsTheEffectWithItsRetrievalCall() {
        let xml = EpisodicHistoryFormatter.buildPointerHistoryString(from: history(files: ["Shape.java"]))
        XCTAssertTrue(xml.contains("get_conversation_history(0)"))
        XCTAssertTrue(xml.contains("diff=\"on_demand\""))
    }

    /// An unmeasured write has nothing to fetch, so the pointer strategy must not promise
    /// one — it stays `baseline="none"`.
    func testUnmeasuredWriteIsNeverMarkedOnDemand() {
        let unmeasured = ActionEffect(path: "/Users/me/Big.java", linesAdded: 9_000,
                                      linesRemoved: 0, diff: nil, isTruncated: false)
        let xml = EpisodicHistoryFormatter.renderEffect(unmeasured, diff: .onDemand)

        XCTAssertTrue(xml.contains("baseline=\"none\""))
        XCTAssertFalse(xml.contains("diff=\"on_demand\""),
                       "there is no diff to fetch:\n\(xml)")
    }

    /// Hybrid's pointer segment behaves as pointer, its inline segment as recent.
    func testHybridPointerSegmentUsesOnDemandAndInlineUsesTheBody() {
        let xml = EpisodicHistoryFormatter.buildHybridHistoryString(
            from: history(files: ["Old.java", "New.java"]), inlineCount: 1
        )
        XCTAssertTrue(xml.contains("diff=\"on_demand\""), "the aged-out turn points at the tool")
        XCTAssertTrue(xml.contains("calculateArea"), "the inline turn still carries its body")
    }

    // MARK: - The tool delivers what the skeleton promised

    func testConversationHistoryToolReturnsTheDiff() async throws {
        let tool = ConversationHistoryTool(chatHistory: history(files: ["Shape.java"]))
        let output = try await tool.call(arguments: args(0))

        XCTAssertTrue(output.contains("changed Shape.java +14 −5"), "counts:\n\(output)")
        XCTAssertTrue(output.contains("+    public abstract double calculateArea();"),
                      "the diff body is the whole point of the call:\n\(output)")
    }

    /// An unmeasured write must say so here too, or the model reads a silent tool result as
    /// "that turn changed nothing".
    func testToolReportsAnUnmeasuredWrite() async throws {
        let agent = ChatMessage(id: UUID(), conversationId: convID, timestamp: t0.addingTimeInterval(1),
                                sender: .agent, content: .plainText("Done."))
        agent.timelineEvents = [.toolExecution(write("Big.java", effect: ActionEffect(
            path: "/Users/me/Big.java", linesAdded: 9_000, linesRemoved: 0, diff: nil, isTruncated: false
        )))]
        let tool = ConversationHistoryTool(chatHistory: [
            ChatMessage(id: UUID(), conversationId: convID, timestamp: t0, sender: .user,
                        content: .plainText("Overwrite it")),
            agent
        ])

        let output = try await tool.call(arguments: args(0))
        XCTAssertTrue(output.contains("no pre-write snapshot"), "\(output)")
    }

    /// Reads change nothing, so they must not grow a "changed" line.
    func testToolOmitsChangeLineForNonMutatingTools() async throws {
        let agent = ChatMessage(id: UUID(), conversationId: convID, timestamp: t0.addingTimeInterval(1),
                                sender: .agent, content: .plainText("Read it."))
        agent.timelineEvents = [.toolExecution(ToolExecutionData(
            id: UUID(), name: "read_file", params: #"{"path":"/Users/me/A.java"}"#,
            output: "contents", isSuccess: true, isExecuting: false
        ))]
        let tool = ConversationHistoryTool(chatHistory: [
            ChatMessage(id: UUID(), conversationId: convID, timestamp: t0, sender: .user,
                        content: .plainText("Read A.java")),
            agent
        ])

        let output = try await tool.call(arguments: args(0))
        XCTAssertTrue(output.contains("read_file"))
        XCTAssertFalse(output.contains("changed "))
    }

    // MARK: - Append without a snapshot (the second silent absence)

    private func appendRow(preWrite: String?) -> ToolExecutionData {
        var data = ToolExecutionData(
            id: UUID(), name: "write_file",
            params: #"{"append":true,"content":"\nRaj Singh","path":"/Users/me/Log.txt"}"#,
            output: "ok", isSuccess: true, isExecuting: false
        )
        data.preWriteContent = preWrite
        return data
    }

    /// The gap: `resolve` returns nil for an append with no snapshot, so `ActionEffect.from`
    /// exited at its FIRST guard and emitted nothing — not even `baseline="none"`. Appending
    /// to a file over the 512 KB snapshot cap is exactly the realistic case.
    func testAppendWithoutSnapshotStillRecordsAnEffect() throws {
        let effect = try XCTUnwrap(
            ActionEffect.from(toolExecution: appendRow(preWrite: nil)),
            "an append that happened must not vanish from memory"
        )
        XCTAssertEqual(effect.fileName, "Log.txt")
        XCTAssertNil(effect.diff)
        XCTAssertGreaterThan(effect.linesAdded, 0)
    }

    /// Conservative on purpose: the XML has no append marker, so the model cannot tell this
    /// from an overwrite and would read `removed="0"` as measured.
    func testAppendWithoutSnapshotIsFlaggedUnmeasured() throws {
        let effect = try XCTUnwrap(ActionEffect.from(toolExecution: appendRow(preWrite: nil)))
        XCTAssertTrue(EpisodicHistoryFormatter.renderEffect(effect).contains("baseline=\"none\""))
    }

    /// The timeline chip keeps the OPPOSITE default — no affordance beats one that opens the
    /// fragment as though it were the file. Memory and the viewer diverge deliberately.
    func testTimelineChipStillRefusesTheSameRow() {
        XCTAssertNil(TimelineFileViewerAction.resolve(data: appendRow(preWrite: nil)),
                     "the viewer's default must not change")
        XCTAssertNotNil(TimelineFileViewerAction.resolve(data: appendRow(preWrite: nil),
                                                         missingBaseline: .recordFragment))
    }

    /// With a snapshot, nothing changes: the append is reconstructed and diffed properly.
    func testAppendWithSnapshotIsUnaffected() throws {
        let effect = try XCTUnwrap(ActionEffect.from(toolExecution: appendRow(preWrite: "line1\nline2\n")))
        XCTAssertNotNil(effect.diff, "a real baseline still produces a real diff")
        XCTAssertEqual(effect.linesRemoved, 0, "an append removes nothing")
    }
}

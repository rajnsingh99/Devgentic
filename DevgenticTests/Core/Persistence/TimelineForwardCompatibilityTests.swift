//
//  TimelineForwardCompatibilityTests.swift
//  DevgenticTests
//
//  Created on 04/08/26.
//
//  Guards the `.unknown` catch-all that makes `TimelineEvent` survive a shape it cannot model.
//
//  THE PROBLEM: `TimelineEvent`'s synthesized codec threw on any element it could not decode, and
//  because that throw propagates out of the ARRAY decode, ONE unreadable event destroyed the whole
//  run's timeline. The empty result was then written back over the blob, making the loss permanent.
//
//  ⚠️ ASSERT ON PARSED JSON, NEVER ON BYTES OR STRINGS. `JSONEncoder`'s key order comes from a
//  `Dictionary` and varies between process runs for the SAME value, so `XCTAssertEqual(blobA, blobB)`
//  and golden-string assertions are flaky by construction. `JSONSerialization`'s writer is separately
//  lossy on doubles. Compare objects.
//
//  ⚠️ AND NEVER assert `encode(decode(x)) == x` over a WHOLE fixture: `ToolExecutionData`'s encoder
//  is deliberately asymmetric — it omits `preWriteContent`/`postWriteContent` (~1 MB/write of
//  session-scoped data). The always-valid form is per-element and scoped to `.unknown` elements,
//  which is what the preservation tests below do.
//

import XCTest
@testable import devgentic

final class TimelineForwardCompatibilityTests: XCTestCase {

    // MARK: - Helpers

    private func parsed(_ data: Data) throws -> NSObject {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? NSObject
        )
    }

    private func assertSameJSON(
        _ lhs: Data, _ rhs: Data, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertTrue(
            try parsed(lhs).isEqual(try parsed(rhs)),
            """
            \(message)
              A: \(String(decoding: lhs, as: UTF8.self))
              B: \(String(decoding: rhs, as: UTF8.self))
            """,
            file: file, line: line
        )
    }

    /// Stands in for "a case some future build added". Any name absent from the shipping enum
    /// exercises the identical decoder path, so no second build is needed.
    private static let futureCaseName = "checkpointFromAFutureBuild"
    private static let futurePayload: [String: Any] = [
        "id": "6E5B7A44-1C2D-4E3F-9A8B-0C1D2E3F4A5B",
        "seq": 42,
        "ratio": 0.5,
        "note": "keep me",
        "nested": ["deep": [1, 2, 3]],
    ]
    private static var futureElement: [String: Any] { [futureCaseName: futurePayload] }

    private func oneOfEveryKnownCase() -> [TimelineEvent] {
        [
            .thought(id: UUID(), text: "t"),
            .reasoning(id: UUID(), text: "r"),
            .mediaGeneration(id: UUID(), toolName: "flux", artifact: nil, isComplete: true),
        ]
    }

    // MARK: - Self-maintaining guard

    /// ⚠️ Without this, the day someone adds a real ninth case that happens to share the fixture's
    /// name, every test below keeps passing while testing nothing.
    func testFixtureCaseNameIsNotARealCase() throws {
        let blob = try JSONEncoder().encode(oneOfEveryKnownCase())
        let elements = try XCTUnwrap(
            JSONSerialization.jsonObject(with: blob) as? [[String: Any]]
        )
        let knownNames = Set(elements.flatMap(\.keys))
        XCTAssertFalse(
            knownNames.contains(Self.futureCaseName),
            "\(Self.futureCaseName) became a REAL case — pick a new fixture name or these tests are vacuous."
        )
    }

    // MARK: - The core guarantee

    /// One unreadable element must not collapse the array — the whole point.
    func testFutureCaseDecodesToUnknownWithoutLosingItsNeighbours() throws {
        let fixture: [Any] = [
            ["thought": ["id": UUID().uuidString, "text": "before"]],
            Self.futureElement,
            ["thought": ["id": UUID().uuidString, "text": "after"]],
        ]
        let blob = try JSONSerialization.data(withJSONObject: fixture)

        let events = try JSONDecoder().decode([TimelineEvent].self, from: blob)

        XCTAssertEqual(events.count, 3, "The future element collapsed the array — this is the bug.")
        guard case .unknown(_, let name, _) = events[1] else {
            return XCTFail("Element 1 should be .unknown, got \(events[1])")
        }
        XCTAssertEqual(name, Self.futureCaseName)
        if case .thought(_, let text) = events[0] { XCTAssertEqual(text, "before") } else { XCTFail("[0]") }
        if case .thought(_, let text) = events[2] { XCTAssertEqual(text, "after") } else { XCTFail("[2]") }
    }

    /// Preservation: what goes in comes back out, semantically identical.
    func testUnknownElementReEmitsTheSameJSONValue() throws {
        let blob = try JSONSerialization.data(withJSONObject: [Self.futureElement])
        let events = try JSONDecoder().decode([TimelineEvent].self, from: blob)
        let reencoded = try JSONEncoder().encode(events)

        try assertSameJSON(blob, reencoded,
                           "An unrecognised event was not preserved verbatim across a round trip.")
    }

    /// ⚠️ The precision case. Integers must not silently degrade through `Double` — this is why the
    /// carrier is a dedicated type with `.int`/`.uint` arms rather than the shared `JSONValue`,
    /// whose only numeric arm is `Double`.
    func testUnknownPayloadPreservesLargeIntegersExactly() throws {
        let big: [String: Any] = [
            Self.futureCaseName: [
                "id": "6E5B7A44-1C2D-4E3F-9A8B-0C1D2E3F4A5B",
                "beyondDoublePrecision": 9_007_199_254_740_993,   // 2^53 + 1
                "int64Max": 9_223_372_036_854_775_807,
                "small": 1500,
                "negative": -42,
            ]
        ]
        let blob = try JSONSerialization.data(withJSONObject: [big])
        let events = try JSONDecoder().decode([TimelineEvent].self, from: blob)
        let reencoded = try JSONEncoder().encode(events)

        let out = try XCTUnwrap(
            (try parsed(reencoded) as? [[String: Any]])?.first?[Self.futureCaseName] as? [String: Any]
        )
        XCTAssertEqual(out["beyondDoublePrecision"] as? Int, 9_007_199_254_740_993,
                       "2^53+1 degraded — the carrier fell back to Double.")
        XCTAssertEqual(out["int64Max"] as? Int, 9_223_372_036_854_775_807)
        XCTAssertEqual(out["small"] as? Int, 1500)
        XCTAssertEqual(out["negative"] as? Int, -42)
    }

    /// ⚠️ THE DECISIVE DESIGN POINT. The fallback is TOTAL — it catches ANY decode failure, not just
    /// an unrecognised case NAME. A recognisable case whose payload changed shape (a new required
    /// field, a new nested enum rawValue) is the far more likely real-world break, and a
    /// name-keyed-only fallback would still lose the entire array for those.
    func testRecognisedCaseWithAnUnreadablePayloadAlsoBecomesUnknown() throws {
        let fixture: [Any] = [
            ["thought": ["id": UUID().uuidString, "text": "kept"]],
            // A real case name, but `id` is not a UUID — the known decoder throws on it.
            ["thought": ["id": "not-a-uuid", "text": "future shape"]],
        ]
        let blob = try JSONSerialization.data(withJSONObject: fixture)

        let events = try JSONDecoder().decode([TimelineEvent].self, from: blob)

        XCTAssertEqual(events.count, 2, "A payload-shape failure collapsed the array.")
        guard case .unknown(_, let name, _) = events[1] else {
            return XCTFail("A recognisable case with an unreadable payload must become .unknown, got \(events[1])")
        }
        XCTAssertEqual(name, "thought", "The case name should still be recovered.")
    }

    /// Nested is free: the catch-all lives inside `TimelineEvent.init(from:)`, so it applies at every
    /// depth. Most of a real run's events live inside plan steps, so this is the case that matters.
    ///
    /// The fixture is built by ENCODING A REAL CARD and splicing the future element into its nested
    /// events — hand-writing the JSON silently omitted `PlanRunData.phase`/`startedAt`, which made
    /// the card itself fail to decode and the test assert the wrong thing.
    func testUnknownNestedInsideAPlanCardIsPreserved() throws {
        let realCard = TimelineEvent.planExecution(
            PlanRunData(steps: [
                PlanStepData(id: "s1", title: "Research",
                             events: [.thought(id: UUID(), text: "inner")])
            ])
        )
        var tree = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode([realCard]))
                as? [[String: Any]]
        )
        // Splice a future event into the step's nested `events` array.
        var card = try XCTUnwrap(tree[0]["planExecution"] as? [String: Any])
        var run = try XCTUnwrap(card["_0"] as? [String: Any])
        var steps = try XCTUnwrap(run["steps"] as? [[String: Any]])
        var events = try XCTUnwrap(steps[0]["events"] as? [[String: Any]])
        events.append(Self.futureElement)
        steps[0]["events"] = events
        run["steps"] = steps
        card["_0"] = run
        tree[0]["planExecution"] = card
        let blob = try JSONSerialization.data(withJSONObject: tree)

        let decoded = try JSONDecoder().decode([TimelineEvent].self, from: blob)
        XCTAssertEqual(decoded.count, 1)

        guard case .planExecution(let run2) = decoded[0] else {
            return XCTFail("The card itself should still decode, got \(decoded[0])")
        }
        let nested = try XCTUnwrap(run2.steps.first?.events)
        XCTAssertEqual(nested.count, 2, "The unrecognised nested event collapsed its whole step.")
        XCTAssertTrue(nested[1].isUnknown)

        try assertSameJSON(blob, try JSONEncoder().encode(decoded),
                           "A nested unrecognised event was not preserved across a round trip.")
    }

    /// The other nesting outcome, and it is CORRECT: if the CARD's own shape changes (a new required
    /// field on `PlanRunData`), the card cannot decode and is preserved wholesale as `.unknown`.
    /// Nothing is lost on disk, but the card does not render — which is exactly why an unknown makes
    /// the run ineligible for resume (`timelineIsDegraded`): its whole nested sub-timeline, including
    /// completed tool calls, is invisible to the reconstructor.
    func testACardWhoseOwnShapeChangedBecomesWhollyUnknownButIsPreserved() throws {
        // A plan card missing `phase` and `startedAt` — i.e. written by a build with a different shape.
        let fixture: [Any] = [["planExecution": ["_0": [
            "id": UUID().uuidString,
            "steps": [],
        ]]]]
        let blob = try JSONSerialization.data(withJSONObject: fixture)

        let decoded = try JSONDecoder().decode([TimelineEvent].self, from: blob)
        XCTAssertEqual(decoded.count, 1)
        guard case .unknown(_, let name, _) = decoded[0] else {
            return XCTFail("Expected the card to be preserved as .unknown, got \(decoded[0])")
        }
        XCTAssertEqual(name, "planExecution")
        try assertSameJSON(blob, try JSONEncoder().encode(decoded),
                           "An unreadable card must still round-trip verbatim.")
    }

    // MARK: - Identity

    /// SwiftUI's `ForEach` keys off `id`, so a fresh UUID per decode would churn the list on every
    /// reload. It must be derived from the value.
    func testUnknownIdentityIsStableAcrossDecodes() throws {
        let blob = try JSONSerialization.data(withJSONObject: [Self.futureElement])
        let first = try JSONDecoder().decode([TimelineEvent].self, from: blob)
        let second = try JSONDecoder().decode([TimelineEvent].self, from: blob)
        XCTAssertEqual(first[0].id, second[0].id)
    }

    /// A payload carrying an `id` should adopt it, so identity survives even if the encoding changes.
    func testUnknownAdoptsAPayloadIdWhenPresent() throws {
        let blob = try JSONSerialization.data(withJSONObject: [Self.futureElement])
        let events = try JSONDecoder().decode([TimelineEvent].self, from: blob)
        XCTAssertEqual(events[0].id, UUID(uuidString: "6E5B7A44-1C2D-4E3F-9A8B-0C1D2E3F4A5B"))
    }

    /// Different payloads must not collide.
    func testDistinctUnknownPayloadsGetDistinctIdentities() throws {
        let a: [String: Any] = ["futureA": ["value": 1]]
        let b: [String: Any] = ["futureB": ["value": 2]]
        let blob = try JSONSerialization.data(withJSONObject: [a, b])
        let events = try JSONDecoder().decode([TimelineEvent].self, from: blob)
        XCTAssertNotEqual(events[0].id, events[1].id)
    }

    // MARK: - Eviction tier

    /// ⚠️ Under the old two-tier rule an `.unknown` was neither narrative nor a recognisable card, so
    /// it was the FIRST non-narrative victim at the cap — meaning a capability card written by a
    /// newer build was preferentially deleted, the exact opposite of the card-protection intent.
    func testUnknownIsEvictedLastNotFirst() {
        var events: [TimelineEvent] = [
            .unknown(id: UUID(), caseName: "futureCard", payload: .object(["a": .int(1)])),
            .toolExecution(ToolExecutionData(id: UUID(), name: "bash", params: "{}",
                                             output: "ok", isSuccess: true, isExecuting: false)),
        ]
        // Push past the cap with ordinary tool events, no narrative available to evict.
        while events.count <= ChatMessage.maxTimelineEvents {
            events.append(.toolExecution(ToolExecutionData(id: UUID(), name: "bash", params: "{}",
                                                           output: "ok", isSuccess: true, isExecuting: false)))
        }
        ChatMessage.evictOverflow(&events, context: "test")

        XCTAssertTrue(events.contains(where: \.isUnknown),
                      "The unrecognised event was evicted before ordinary tool events.")
    }

    /// …but it must still be evictable, or a timeline made entirely of unknowns would breach the cap.
    func testAnAllUnknownTimelineStillEvicts() {
        var events: [TimelineEvent] = (0...ChatMessage.maxTimelineEvents).map {
            .unknown(id: UUID(), caseName: "future", payload: .object(["i": .int(Int64($0))]))
        }
        let before = events.count
        ChatMessage.evictOverflow(&events, context: "test")
        XCTAssertEqual(events.count, before - 1, "An all-unknown timeline never evicts — the cap is breached.")
    }

    // MARK: - Resume gate

    /// Resume rebuilds the model's view of what already ran. An `.unknown` hiding a completed tool
    /// call is invisible to the reconstructor, so the model would re-run a side-effectful tool.
    func testTimelineWithAnUnknownIsDegradedForResume() {
        let message = ChatMessage(conversationId: UUID(), sender: .agent, content: .plainText("x"))
        XCTAssertFalse(message.timelineIsDegraded)

        message.timelineEvents = [.thought(id: UUID(), text: "fine")]
        XCTAssertFalse(message.timelineIsDegraded)

        message.timelineEvents.append(
            .unknown(id: UUID(), caseName: "future", payload: .object([:]))
        )
        XCTAssertTrue(message.timelineIsDegraded,
                      "An unreadable event must disqualify the run from resuming.")
    }

    /// A total decode failure is degraded too, even with nothing in the array.
    func testTotalDecodeFailureIsDegradedForResume() {
        let message = ChatMessage(conversationId: UUID(), sender: .agent, content: .plainText("x"))
        message.timelineDecodeFailed = true
        XCTAssertTrue(message.timelineIsDegraded)
    }

    // MARK: - No regression for known cases

    /// The eight original cases must keep their EXACT on-disk shape — the whole reason the codec
    /// mirrors a synthesized enum instead of hand-writing `CodingKeys`.
    func testKnownCasesRoundTripUnchanged() throws {
        let events: [TimelineEvent] = [
            .thought(id: UUID(), text: "a thought"),
            .reasoning(id: UUID(), text: "some prose"),
            .mediaGeneration(id: UUID(), toolName: "flux", artifact: nil, isComplete: true),
            .capabilityMilestone(id: UUID(), kind: .planGenerated, detail: "detail"),
        ]
        let blob = try JSONEncoder().encode(events)
        let decoded = try JSONDecoder().decode([TimelineEvent].self, from: blob)

        XCTAssertEqual(decoded, events)
        XCTAssertFalse(decoded.contains(where: \.isUnknown),
                       "A known case decoded as .unknown — the wire format changed.")
        try assertSameJSON(blob, try JSONEncoder().encode(decoded), "Known cases did not round-trip.")
    }

    /// The single-unlabelled-payload cases use `_0`; a regression there would silently reroute every
    /// tool event through `.unknown`.
    func testUnlabelledPayloadCaseStillUsesUnderscoreZero() throws {
        let event = TimelineEvent.toolExecution(
            ToolExecutionData(id: UUID(), name: "bash", params: "{}", output: "ok",
                              isSuccess: true, isExecuting: false)
        )
        let blob = try JSONEncoder().encode([event])
        let object = try XCTUnwrap((try parsed(blob) as? [[String: Any]])?.first)
        let payload = try XCTUnwrap(object["toolExecution"] as? [String: Any])
        XCTAssertNotNil(payload["_0"], "Wire format changed: expected the synthesized `_0` key.")

        let decoded = try JSONDecoder().decode([TimelineEvent].self, from: blob)
        XCTAssertFalse(decoded[0].isUnknown)
    }
}

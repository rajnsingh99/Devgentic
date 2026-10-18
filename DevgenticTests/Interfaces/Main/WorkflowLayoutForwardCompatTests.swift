// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowLayoutForwardCompatTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class WorkflowLayoutForwardCompatTests: XCTestCase {

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    // MARK: - The five enums decode unknowns and re-encode them verbatim

    func testUnknownConditionOpSurvivesTheRoundTrip() throws {
        let op = ConditionOp(rawValue: "fuzzyMatch")!
        XCTAssertEqual(op, .other("fuzzyMatch"))
        XCTAssertEqual(try roundTrip(op).rawValue, "fuzzyMatch",
                       "the unknown operator must re-encode VERBATIM — a default-mapping would destroy it")
    }

    func testUnknownConditionFieldSurvivesTheRoundTrip() throws {
        XCTAssertEqual(try roundTrip(ConditionField(rawValue: "nodeMetadata")!).rawValue, "nodeMetadata")
    }

    func testUnknownStickyColorSurvivesAndDrawsTheDefault() throws {
        let color = StickyNoteColor(rawValue: "teal")!
        XCTAssertEqual(try roundTrip(color).rawValue, "teal")
        XCTAssertEqual(color.swiftUIColor, StickyNoteColor.yellow.swiftUIColor,
                       "an unknown tint draws as the default — cosmetics must never brick a graph")
    }

    /// Pickers iterate `allCases`; offering "other" would let a user SELECT the unknown state.
    func testAllCasesExcludeTheCatchAll() {
        XCTAssertFalse(ConditionOp.allCases.contains(where: { if case .other = $0 { return true }; return false }))
        XCTAssertFalse(ConditionField.allCases.contains(where: { if case .other = $0 { return true }; return false }))
        XCTAssertFalse(StickyNoteColor.allCases.contains(where: { if case .other = $0 { return true }; return false }))
    }

    // MARK: - The defect scenario end to end (WF-PE3's headline)

    /// A whole LAYOUT containing a rule with a newer-build operator must decode, keep working,
    /// and give the newer build back exactly the OPERATOR it wrote (see the WF-TS5 note in the
    /// header for what is NOT preserved).
    func testLayoutWithNewerBuildOperatorRoundTripsLosslessly() throws {
        // Simulate the newer build's blob: a valid layout whose JSON carries an unknown op.
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Bug", field: .upstreamOutput, op: .contains, value: "bug"),
            ConditionRule(label: "Rest", field: .upstreamOutput, op: .isNotEmpty, value: "")
        ]
        let node = WorkflowNode(kind: .condition(config), position: .zero, displayName: "Router")
        let layout = WorkflowLayout(nodes: [node], edges: [], annotations: [])
        var json = String(data: try JSONEncoder().encode(layout), encoding: .utf8)!
        json = json.replacingOccurrences(of: "\"contains\"", with: "\"semanticMatch\"")

        // The rollback build decodes it — no throw, nothing lost.
        let decoded = try JSONDecoder().decode(WorkflowLayout.self, from: json.data(using: .utf8)!)
        guard case .condition(let decodedConfig) = decoded.nodes[0].kind else {
            return XCTFail("node kind lost")
        }
        XCTAssertEqual(decodedConfig.rules[0].op, .other("semanticMatch"))

        // …and a re-save on the rollback build hands the newer build its operator back.
        let resaved = try JSONDecoder().decode(WorkflowLayout.self, from: JSONEncoder().encode(decoded))
        guard case .condition(let resavedConfig) = resaved.nodes[0].kind else {
            return XCTFail("node kind lost on re-save")
        }
        XCTAssertEqual(resavedConfig.rules[0].op.rawValue, "semanticMatch",
                       "the older build must not launder the newer build's operator out of the blob")
    }

    /// The validator turns the inert rule into a visible, actionable error — the engine will never
    /// match it, and silence here would be a Router that quietly stopped routing.
    func testValidatorFlagsANewerBuildOperatorAsAnError() {
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "A", field: .upstreamOutput, op: .other("semanticMatch"), value: "x"),
            ConditionRule(label: "B", field: .upstreamOutput, op: .isEmpty, value: "")
        ]
        let node = WorkflowNode(kind: .condition(config), position: .zero, displayName: "Router")
        let sink = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Sink")
        let layout = WorkflowLayout(
            nodes: [node, sink],
            edges: [WorkflowEdge(sourceNodeID: node.id, targetNodeID: sink.id, sourcePortLabel: "A")],
            annotations: []
        )

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])

        XCTAssertTrue(issues.contains { $0.severity == .error && $0.message.contains("newer version") },
                      "an un-evaluable rule must be a design-time error naming the remedy — got: \(issues.map(\.message))")
    }

    // MARK: - WF-PE4: the kind-decode diagnostic

    /// An unknown kind decodes as a PRESERVED `.unsupported` placeholder — never a guessed runnable
    /// kind — and the throw survives only for genuine corruption
    /// (`testMissingKindStillFailsTheDecode`).
    func testUnknownKindOnAModernNodeBecomesAPlaceholderNotAGuess() throws {
        let json = """
        {"id":"\(UUID().uuidString)","kind":{"teleport":{}},"positionX":0,"positionY":0,"displayName":"Future Node"}
        """
        let node = try JSONDecoder().decode(WorkflowNode.self, from: json.data(using: .utf8)!)
        guard case .unsupported = node.kind else {
            return XCTFail("an unknown kind must become a preserved placeholder — silently guessing a runnable kind would run the wrong graph; got \(node.kind)")
        }
        XCTAssertEqual(node.displayName, "Future Node")
    }

    /// The retired `profileID` + `profileType` node shape (no `kind`) is NOT decoded: a missing
    /// `kind` is corruption, so the unreadable-layout machinery owns it.
    func testTheRetiredProfileNodeShapeIsRejected() {
        let json = """
        {"id":"\(UUID().uuidString)","profileID":"\(UUID().uuidString)","profileType":"Bot","positionX":10,"positionY":20,"displayName":"Old Bot"}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(WorkflowNode.self, from: json.data(using: .utf8)!))
    }

    /// A profile node encodes its `kind` only — no duplicate top-level `profileID`/`profileType`.
    func testAProfileNodeEncodesItsKindOnly() throws {
        let node = WorkflowNode(profileID: UUID(), position: .zero, displayName: "Bot", profileType: .bot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any])
        XCTAssertNotNil(object["kind"])
        XCTAssertNil(object["profileID"])
        XCTAssertNil(object["profileType"])
    }

    // MARK: - WF-TS5: the limit of this guarantee

    /// ⚠️ THIS TEST PINS A LIMITATION, NOT A GUARANTEE — and it is here so the file's own header
    /// cannot drift back into over-claiming. The catch-alls above preserve unknown enum VALUES;
    /// nothing preserves unknown KEYS. `WorkflowNode`, `WorkflowNodeConfig`, `ConditionNodeConfig`,
    /// `WorkflowEdge`, `StickyNote` and `WorkflowLayout` all encode a FIXED `CodingKeys` set, so a
    /// field added by a newer build is invisible to decode and absent from the re-encode.
    ///
    /// What actually protects the user is `WorkflowLayoutSD.layoutBlobVersion` + the write refusal
    /// (WF-PE2), pinned by
    /// `BlobWriteRefusalTests.testNewerVersionBlobKeepsAFutureFieldTheDecoderCannotSee`. That
    /// refusal is keyed on the STAMP, so ANY schema addition — including a purely additive optional
    /// field — MUST bump `layoutBlobVersion` or this drop happens for real.
    ///
    /// ⚠️ If you add an unknown-key sidecar to these Codables, DELETE this test and correct the
    /// header — its failure is good news, not a regression.
    func testUnknownKeysAreNotPreserved_soTheVersionStampIsTheOnlyProtection() throws {
        var node = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Worker")
        node.nodeConfig = WorkflowNodeConfig(maxNodeRetries: 2)
        let encoded = try JSONEncoder().encode(WorkflowLayout(nodes: [node], edges: [], annotations: []))
        let fromTheFuture = String(data: encoded, encoding: .utf8)!
            .replacingOccurrences(of: "\"maxNodeRetries\":",
                                  with: "\"concurrencyLimit\":4,\"maxNodeRetries\":")

        let decoded = try JSONDecoder().decode(WorkflowLayout.self, from: Data(fromTheFuture.utf8))
        XCTAssertEqual(decoded.nodes[0].nodeConfig?.maxNodeRetries, 2,
                       "an unknown key must not break the decode — that is why the loss is silent")

        let reEncoded = String(data: try JSONEncoder().encode(decoded), encoding: .utf8)!
        XCTAssertFalse(reEncoded.contains("concurrencyLimit"),
                       "If this now PASSES a sidecar through, the guarantee has genuinely widened: "
                       + "delete this test and update the file header.")
    }

    // MARK: - [WF-PE4] Unknown node KINDS decode as preserved placeholders

    /// A layout JSON with one node whose `kind` case name this build has never heard of.
    private func layoutJSON(kind: String) -> Data {
        Data("""
        {"nodes": [
            {"id": "11111111-1111-1111-1111-111111111111", "kind": {"profile": {"profileID": "AAAAAAAA-0000-0000-0000-000000000000", "profileType": "Bot"}},
             "positionX": 0, "positionY": 0, "displayName": "Bot A"},
            {"id": "22222222-2222-2222-2222-222222222222", "kind": \(kind),
             "positionX": 100, "positionY": 0, "displayName": "Future Node"},
            {"id": "33333333-3333-3333-3333-333333333333", "kind": {"profile": {"profileID": "BBBBBBBB-0000-0000-0000-000000000000", "profileType": "Bot"}},
             "positionX": 200, "positionY": 0, "displayName": "Bot C"}
        ],
        "edges": [
            {"id": "44444444-4444-4444-4444-444444444444", "sourceNodeID": "11111111-1111-1111-1111-111111111111", "targetNodeID": "22222222-2222-2222-2222-222222222222"},
            {"id": "55555555-5555-5555-5555-555555555555", "sourceNodeID": "22222222-2222-2222-2222-222222222222", "targetNodeID": "33333333-3333-3333-3333-333333333333"}
        ]}
        """.utf8)
    }

    /// The headline: ONE unknown case name no longer costs the whole graph. Before this, the
    /// element throw failed the `[WorkflowNode]` array, which made the layout unreadable (empty
    /// canvas + overlay), unrunnable, AND permanently unsaveable (the `WorkflowLayoutSD` setter
    /// refuses every write while unreadable) — total loss, destructive repair the only exit.
    func testUnknownNodeKindDecodesAsPlaceholderAndTheGraphSurvives() throws {
        let decoded = try JSONDecoder().decode(WorkflowLayout.self,
                                               from: layoutJSON(kind: #"{"futureKind": {"answer": 42}}"#))

        XCTAssertEqual(decoded.nodes.count, 3, "the two known nodes and both edges must survive")
        XCTAssertEqual(decoded.edges.count, 2)
        XCTAssertEqual(decoded.unsupportedNodes.map(\.displayName), ["Future Node"])
        if case .unsupported = decoded.nodes[1].kind {} else {
            XCTFail("the unknown kind must become a preserved placeholder, got \(decoded.nodes[1].kind)")
        }
    }

    /// The preservation half — the load-bearing one, per this file's header rule: a re-save must
    /// write the ORIGINAL kind JSON back, so the build that understands the node reads it again
    /// untouched, and the literal case name `unsupported` never reaches a blob.
    func testUnknownNodeKindRoundTripsItsOriginalJSON() throws {
        let decoded = try JSONDecoder().decode(WorkflowLayout.self,
                                               from: layoutJSON(kind: #"{"futureKind": {"answer": 42}}"#))
        let reEncoded = try JSONEncoder().encode(decoded)

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: reEncoded) as? [String: Any])
        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        let futureNode = try XCTUnwrap(nodes.first { $0["displayName"] as? String == "Future Node" })
        let kind = try XCTUnwrap(futureNode["kind"] as? [String: Any])
        XCTAssertNil(kind["unsupported"], "the placeholder wrapper must never be persisted")
        let payload = try XCTUnwrap(kind["futureKind"] as? [String: Any])
        XCTAssertEqual(payload["answer"] as? Double, 42,
                       "the original kind JSON must round-trip VERBATIM — a lossy placeholder is the defect class this file forbids")

        // And the round-trip is stable: decoding the re-encoded blob yields the same placeholder.
        let again = try JSONDecoder().decode(WorkflowLayout.self, from: reEncoded)
        XCTAssertEqual(again.unsupportedNodes.count, 1)
    }

    /// The retired Loop node — the one shipped instance of this class. Its layouts used to land on
    /// the unreadable-layout total-loss path; now they open with a placeholder (run still blocked,
    /// loop semantics NOT resurrected — the 2026-08-15 no-decode-shim decision stands).
    func testRetiredLoopNodeDecodesAsPlaceholderNotLostLayout() throws {
        let decoded = try JSONDecoder().decode(WorkflowLayout.self,
                                               from: layoutJSON(kind: #"{"loop": {"_0": {"maxIterations": 3}}}"#))
        XCTAssertEqual(decoded.nodes.count, 3)
        XCTAssertEqual(decoded.unsupportedNodes.count, 1)
    }

    /// The corruption boundary: a node with NO kind is not version skew, and must still fail the
    /// decode so the unreadable-layout machinery owns it.
    func testMissingKindStillFailsTheDecode() {
        let json = Data("""
        {"nodes": [{"id": "11111111-1111-1111-1111-111111111111", "positionX": 0, "positionY": 0, "displayName": "No Kind"}], "edges": []}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(WorkflowLayout.self, from: json),
                             "a missing kind is corruption, not a preservable unknown")
    }

    // MARK: - [WF-SE6] unattendedAutoApprove round-trips (and its absence decodes as nil)

    /// The SECURITY field must survive its own round-trip, and a config without the key must
    /// decode nil (= off).
    func testUnattendedAutoApproveRoundTripsAndDefaultsNil() throws {
        var config = WorkflowNodeConfig()
        config.unattendedAutoApprove = true
        let decoded = try roundTrip(config)
        XCTAssertEqual(decoded.unattendedAutoApprove, true)

        let partial = Data("""
        {"maxNodeRetries": 2}
        """.utf8)
        let decodedPartial = try JSONDecoder().decode(WorkflowNodeConfig.self, from: partial)
        XCTAssertNil(decodedPartial.unattendedAutoApprove, "an absent key decodes with the setting OFF, never guessed")
        XCTAssertEqual(decodedPartial.maxNodeRetries, 2)
    }

    /// The run gate: an unsupported node raises a BLOCKING validation error, so the user learns
    /// at design time — the executor's choke point enforces the same refusal at run time.
    func testUnsupportedNodeRaisesABlockingValidationError() throws {
        let decoded = try JSONDecoder().decode(WorkflowLayout.self,
                                               from: layoutJSON(kind: #"{"futureKind": {}}"#))
        let issues = WorkflowValidator.validate(layout: decoded, profileMap: [:])
        let blocking = issues.filter { $0.severity == .error && $0.nodeName == "Future Node" }
        XCTAssertFalse(blocking.isEmpty,
                       "an unsupported node must BLOCK the run — this build cannot execute or honestly skip it")
    }

    // MARK: - [Found on adversarial audit] Corruption of a KNOWN kind must not masquerade as version skew

    /// The unknown-kind placeholder exists for a case name this build has NEVER HEARD OF. It must
    /// NOT also catch a case name this build fully understands whose PAYLOAD failed to decode —
    /// that is real corruption, and reclassifying it as "saved by a different version, update
    /// Devgentic" is actively misleading (updating changes nothing; the corrupted bytes round-trip
    /// forever disguised as an ordinary forward-compat placeholder). `{"action": {}}` is a KNOWN
    /// discriminator ("action") with a payload missing `ActionNodeConfig.argumentBindings` — a
    /// non-optional field with only a Swift-level default, which — per this file's own header
    /// rule about synthesized Codable ignoring property defaults for missing keys — synthesized
    /// Decodable throws `keyNotFound` on, not `.unsupported`.
    func testKnownKindWithCorruptedPayload_FailsTheWholeDecodeNotAPlaceholder() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(WorkflowLayout.self, from: layoutJSON(kind: #"{"action": {}}"#)),
            "a KNOWN kind's corrupted payload is real corruption — it must hit the unreadable-layout machinery, not decode as a silently-preserved placeholder"
        )
    }

    /// …and the sibling contract: a genuinely UNRECOGNIZED discriminator still becomes the
    /// placeholder (this is the actual forward-compat case the mechanism exists for) — pinned
    /// again here, right beside the corruption test, so the two contracts are read together.
    func testUnrecognizedDiscriminator_StillBecomesAPlaceholder() throws {
        let decoded = try JSONDecoder().decode(WorkflowLayout.self,
                                               from: layoutJSON(kind: #"{"someKindFromANewerBuild": {"field": 1}}"#))
        XCTAssertEqual(decoded.unsupportedNodes.count, 1)
    }
}

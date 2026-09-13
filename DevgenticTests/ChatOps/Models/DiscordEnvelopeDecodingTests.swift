// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  DiscordEnvelopeDecodingTests.swift
//  devgenticTests
//
//  DC-5. `DiscordRawJSON` sniffed for a dictionary, then an array, then nil — and its final `else`
//  wrote the literal bytes `null` for everything remaining. Discord sends exactly one scalar payload:
//  op 9 INVALID_SESSION's `d` is a bare `true`/`false` saying whether the session may be RESUMED.
//  It was destroyed on arrival, so every invalid session degraded to a full re-IDENTIFY and the log
//  could only ever print "resumable: false" — the defect erased its own evidence.
//

import XCTest
@testable import devgentic

final class DiscordEnvelopeDecodingTests: XCTestCase {

    // MARK: - The scalar that was being destroyed

    /// ⚠️⚠️ THROUGH THE REAL ENVELOPE TYPE, not `DiscordRawJSON` in isolation — the bug lived in the
    /// seam between them, and a test of the part would have passed while the whole stayed broken.
    func testAResumableInvalidSessionSurvivesDecoding() throws {
        let payload = try envelope(#"{"op":9,"d":true,"s":null,"t":null}"#)
        let resumable = try XCTUnwrap(payload.d).decode(Bool.self)
        XCTAssertTrue(resumable,
                      "op-9 `d:true` means the session CAN be resumed; decoding it as false discards "
                      + "the session id and sequence and forces a full re-IDENTIFY, losing every "
                      + "event queued since the last sequence")
    }

    func testANonResumableInvalidSessionAlsoSurvives() throws {
        let payload = try envelope(#"{"op":9,"d":false,"s":null,"t":null}"#)
        XCTAssertFalse(try XCTUnwrap(payload.d).decode(Bool.self))
    }

    /// ⚠️ THE RISK THE DESIGN FLAGGED, PROVEN HERE RATHER THAN IN THE FIELD. The fix re-encodes
    /// through `AnyCodableValue`, which for a scalar means `JSONEncoder` must emit a TOP-LEVEL
    /// FRAGMENT. If this toolchain refused them, every op-9 envelope would be dropped outright —
    /// worse than the bug being fixed.
    func testTheEncoderCanRoundTripATopLevelFragment() throws {
        XCTAssertEqual(String(data: try JSONEncoder().encode(AnyCodableValue.bool(true)), encoding: .utf8), "true")
        XCTAssertEqual(String(data: try JSONEncoder().encode(AnyCodableValue.int(42)), encoding: .utf8), "42")
        XCTAssertEqual(String(data: try JSONEncoder().encode(AnyCodableValue.string("x")), encoding: .utf8), "\"x\"")
    }

    // MARK: - Totality  ⚠️ the point of the fix, not a bonus

    /// The old shape sniff destroyed anything it had not enumerated. This asserts the general
    /// property, so the NEXT unmodelled shape is caught rather than silently becoming `null`.
    func testEveryJSONShapeSurvivesTheEnvelope() throws {
        XCTAssertEqual(try envelope(#"{"op":0,"d":"hello"}"#).d.map { try? $0.decode(String.self) } ?? nil, "hello")
        XCTAssertEqual(try envelope(#"{"op":0,"d":42}"#).d.map { try? $0.decode(Int.self) } ?? nil, 42)
        XCTAssertEqual(try envelope(#"{"op":0,"d":[1,2,3]}"#).d.map { try? $0.decode([Int].self) } ?? nil, [1, 2, 3])

        // An object payload must be unchanged by the rewrite — this is the shape that already worked.
        struct Ready: Decodable { let session_id: String }
        let ready = try envelope(#"{"op":0,"d":{"session_id":"abc123"},"t":"READY"}"#)
        XCTAssertEqual(try XCTUnwrap(ready.d).decode(Ready.self).session_id, "abc123")
    }

    /// A genuine null stays a null — the fix must not turn "absent" into something else.
    func testAGenuineNullIsStillANull() throws {
        let payload = try envelope(#"{"op":11,"d":null}"#)
        if let d = payload.d {
            XCTAssertThrowsError(try d.decode(Bool.self),
                                 "a real null must not decode as a Bool — that would be the old bug inverted")
        }
    }

    // MARK: - Wiring

    /// ⚠️ The decode is worthless if the consumer still forces false. This pins that the resumable
    /// flag actually reaches the branch that decides whether to discard the session.
    func testTheInvalidSessionArmActsOnTheDecodedFlag() throws {
        let source = try ChatOpsSecurityTierMatrixTests
            .readSourceStrippingComments("Devgentic/ChatOps/Services/DiscordGatewayClient.swift")
        guard let arm = source.range(of: "case .invalidSession:") else {
            return XCTFail("the invalid-session arm has moved — this test is blind")
        }
        let body = String(source[arm.upperBound...].prefix(600))
        XCTAssertTrue(body.contains("resumable"),
                      "the arm must read the decoded flag, not assume it")
        XCTAssertTrue(body.contains("if !resumable") || body.contains("guard resumable"),
                      "the session id and sequence must be discarded ONLY when the session is "
                      + "genuinely not resumable")
    }

    private func envelope(_ json: String) throws -> DiscordGatewayPayload {
        try JSONDecoder().decode(DiscordGatewayPayload.self, from: Data(json.utf8))
    }
}

// MARK: - DC-8: the frames that actually go on the wire

final class DiscordGatewayFrameTests: XCTestCase {

    /// ⚠️⚠️ [DC-8] `DiscordResumePayload` HAD TWO REFERENCES IN THE WHOLE REPO, both inside a test
    /// that encoded it and decoded it back. `sendResume` hand-built a `[String: Any]` dictionary, so
    /// the struct under test was never what Discord received — the test could not fail for any reason
    /// the app cares about. Now the frame is typed, and this asserts the bytes.
    func testResumeFrameMatchesDiscordsShape() throws {
        let frame = DiscordGatewayFrame(
            op: DiscordGatewayOpcode.resume.rawValue,
            d: DiscordResumePayload(token: "tok", session_id: "sess", seq: 42)
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(frame)) as? [String: Any])

        XCTAssertEqual(json["op"] as? Int, DiscordGatewayOpcode.resume.rawValue)
        let d = try XCTUnwrap(json["d"] as? [String: Any])
        XCTAssertEqual(d["token"] as? String, "tok")
        XCTAssertEqual(d["session_id"] as? String, "sess",
                       "Discord's key is snake_case; a Swift-cased key makes the RESUME silently fail "
                       + "and the gateway falls back to a full re-IDENTIFY")
        XCTAssertEqual(d["seq"] as? Int, 42)
    }

    /// ⚠️ A HEARTBEAT BEFORE THE FIRST DISPATCH CARRIES A LITERAL `null`, and Discord requires that
    /// exact shape. The hand-built version reproduced it with `compactMapValues { $0 ?? NSNull() }`;
    /// an `Optional<Int>` encodes to it directly, so this pins that the conversion kept the meaning.
    func testAHeartbeatBeforeAnyDispatchSendsNullNotZero() throws {
        let frame = DiscordGatewayFrame(op: DiscordGatewayOpcode.heartbeat.rawValue, d: Int?.none)
        let text = try XCTUnwrap(String(data: try JSONEncoder().encode(frame), encoding: .utf8))
        XCTAssertTrue(text.contains("\"d\":null"),
                      "sending 0 instead of null tells Discord the last processed sequence was 0, "
                      + "not that there has not been one: \(text)")
    }

    func testAHeartbeatAfterADispatchCarriesTheSequence() throws {
        let frame = DiscordGatewayFrame(op: DiscordGatewayOpcode.heartbeat.rawValue, d: Int?.some(7))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(frame)) as? [String: Any])
        XCTAssertEqual(json["d"] as? Int, 7)
    }

    /// ⚠️ IDENTIFY IS DELIBERATELY STILL HAND-BUILT. Its `$os` / `$browser` / `$device` keys cannot be
    /// Swift property names, so a Codable struct would need a CodingKeys enum whose only job is to
    /// re-add three dollar signs — more moving parts on the one frame that must be byte-exact. This
    /// pins that the `$` keys survive, which is the thing that would actually break.
    func testIdentifyStillSendsDollarPrefixedConnectionProperties() throws {
        let source = try ChatOpsSecurityTierMatrixTests
            .readSourceStrippingComments("Devgentic/ChatOps/Services/DiscordGatewayClient.swift")
        for key in ["\"$os\"", "\"$browser\"", "\"$device\""] {
            XCTAssertTrue(source.contains(key),
                          "IDENTIFY lost \(key); Discord refuses the connection without the $ prefix")
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  BlobVersioningTests.swift
//  DevgenticTests
//
//  Created on 05/08/26.
//
//  Guards the blob version-discriminator mechanism (SWIFTDATA_GAP_REGISTER.md G19).
//
//  The thing being defended is subtle: a future migration must be able to ASK a blob what shape it
//  is, instead of trying shapes until one decodes. A guess that succeeds incorrectly is silent data
//  loss, and JSON decoding succeeds incorrectly all the time.
//
//  These tests care most about the two hazards the implementation is shaped around:
//    1. Stamping must not re-encode the payload (JSONSerialization's writer is lossy on doubles).
//    2. Stamping must be idempotent (`MessageContent.unknown` re-emits a preserved payload verbatim,
//       version key included).
//

import XCTest
@testable import devgentic

final class BlobVersioningTests: XCTestCase {

    // MARK: - Mechanism A: the inline key

    func testUnstampedBlobReportsNoVersion() {
        let legacy = Data(#"{"text":"written before versioning"}"#.utf8)
        XCTAssertNil(BlobVersioning.version(of: legacy),
                     "nil is the honest answer for a legacy blob — not 0, which is a real version.")
    }

    func testStampingThenReadingRoundTrips() {
        let stamped = BlobVersioning.stamped(Data(#"{"text":"hi"}"#.utf8), version: 3)
        XCTAssertEqual(BlobVersioning.version(of: stamped), 3)
        XCTAssertEqual(String(decoding: stamped, as: UTF8.self), #"{"schemaVersion":3,"text":"hi"}"#)
    }

    /// ⚠️ THE HAZARD THE IMPLEMENTATION IS BUILT AROUND. The obvious way to add a key —
    /// `JSONSerialization` in, mutate, out — does not round-trip every Double, so blobs carrying
    /// TimeIntervals and canvas coordinates would drift a little on EVERY save. Stamping splices
    /// bytes instead, so everything except the inserted key is untouched.
    func testStampingDoesNotPerturbFloatingPointPayloads() throws {
        struct Payload: Codable, Equatable {
            let timeout: Double
            let x: Double
            let ratio: Double
        }
        let original = Payload(timeout: 0.1 + 0.2, x: 1234.5678901234567, ratio: 1.0 / 3.0)
        let encoded = try JSONEncoder().encode(original)

        let stamped = BlobVersioning.stamped(encoded, version: 2)

        // Byte-exact apart from the injected key.
        let stampedText = String(decoding: stamped, as: UTF8.self)
        let originalText = String(decoding: encoded, as: UTF8.self)
        XCTAssertEqual(stampedText.replacingOccurrences(of: #""schemaVersion":2,"#, with: ""),
                       originalText, "Stamping rewrote bytes it had no business touching.")

        // And the value still decodes bit-identically.
        XCTAssertEqual(try JSONDecoder().decode(Payload.self, from: stamped), original)
    }

    /// ⚠️ THE SECOND HAZARD. `MessageContent.unknown` preserves an unrecognised payload VERBATIM and
    /// re-emits it on the next save — including a version key it did not write. Without idempotence
    /// that produces a duplicate `schemaVersion`, which is invalid-ish JSON whose behaviour depends
    /// on the parser.
    func testStampingIsIdempotentAndReplacesRatherThanDuplicates() {
        let once = BlobVersioning.stamped(Data(#"{"a":1}"#.utf8), version: 2)
        let twice = BlobVersioning.stamped(once, version: 2)
        XCTAssertEqual(once, twice, "Re-stamping at the same version must be a no-op.")

        let bumped = BlobVersioning.stamped(once, version: 5)
        XCTAssertEqual(BlobVersioning.version(of: bumped), 5)
        let occurrences = String(decoding: bumped, as: UTF8.self).components(separatedBy: "schemaVersion").count - 1
        XCTAssertEqual(occurrences, 1, "Bumping produced a DUPLICATE key instead of replacing it.")
    }

    /// An empty object has no members, so the injected pair must not be followed by a comma —
    /// `{"schemaVersion":1,}` is invalid JSON.
    func testStampingAnEmptyObjectStaysValidJSON() throws {
        let stamped = BlobVersioning.stamped(Data("{}".utf8), version: 1)
        XCTAssertEqual(String(decoding: stamped, as: UTF8.self), #"{"schemaVersion":1}"#)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: stamped))
        XCTAssertEqual(BlobVersioning.version(of: stamped), 1)
    }

    /// ⚠️ An ARRAY has nowhere to put a sibling key. Returning it unchanged is correct; quietly
    /// mangling it into an object would be far worse than leaving it unstamped.
    func testStampingAnArrayRootedBlobIsRefusedNotCorrupted() {
        let array = Data(#"[{"a":1},{"b":2}]"#.utf8)
        let stamped = BlobVersioning.stamped(array, version: 2)
        XCTAssertEqual(stamped, array, "Array roots must be returned untouched — use VersionedBlob.")
        XCTAssertNil(BlobVersioning.version(of: stamped))
    }

    /// Leading whitespace must not defeat the root-shape check.
    func testStampingToleratesLeadingWhitespace() {
        let padded = Data("  \n{\"a\":1}".utf8)
        XCTAssertEqual(BlobVersioning.version(of: BlobVersioning.stamped(padded, version: 4)), 4)
    }

    /// A stamped blob must stay readable by code that knows nothing about the key — that is the
    /// entire reason mechanism A is additive rather than a wrapper.
    func testStampedBlobStillDecodesIntoATypeThatHasNoVersionField() throws {
        struct Unaware: Codable, Equatable { let name: String; let count: Int }
        let original = Unaware(name: "unchanged", count: 7)
        let stamped = BlobVersioning.stamped(try JSONEncoder().encode(original), version: 9)
        XCTAssertEqual(try JSONDecoder().decode(Unaware.self, from: stamped), original)
    }

    // MARK: - Mechanism B: the envelope

    func testEnvelopeRoundTripsAndReportsItsVersion() throws {
        let data = try JSONEncoder().encode(VersionedBlob(schemaVersion: 2, payload: ["a", "b"]))
        let result = try XCTUnwrap(VersionedBlob<[String]>.decode(from: data))
        XCTAssertEqual(result.payload, ["a", "b"])
        XCTAssertEqual(result.version, 2)
    }

    /// ⚠️ The legacy fallback is load-bearing, not defensive. `nodeResultsData` has had an envelope
    /// in code for a while and the rows in the developer's real store are STILL bare arrays — a row
    /// is only rewritten when its run is touched. Dropping this path would erase them.
    func testEnvelopeFallsBackToABareLegacyPayload() throws {
        let legacy = Data(#"["a","b"]"#.utf8)
        let result = try XCTUnwrap(VersionedBlob<[String]>.decode(from: legacy))
        XCTAssertEqual(result.payload, ["a", "b"])
        XCTAssertNil(result.version, "A bare payload predates versioning — that must be reported, not faked.")
    }

    /// Genuinely undecodable bytes must return nil, NOT an empty payload. "Unreadable" and "empty"
    /// are different, and collapsing them is the exact mechanism behind G12/G16/G23.
    func testEnvelopeReturnsNilForGarbageRatherThanAnEmptyPayload() {
        XCTAssertNil(VersionedBlob<[String]>.decode(from: Data(#"{"unrelated":true}"#.utf8)))
        XCTAssertNil(VersionedBlob<[String]>.decode(from: Data([0xFF, 0xFE])))
    }

    /// The envelope must work for the user-keyed dictionary case it exists to serve — a workflow
    /// variable literally named "schemaVersion" must not be mistaken for the discriminator.
    func testEnvelopeSurvivesAUserVariableNamedLikeTheVersionKey() throws {
        let hostile = ["schemaVersion": "user typed this", "other": "value"]
        let data = try JSONEncoder().encode(VersionedBlob(schemaVersion: 1, payload: hostile))
        let result = try XCTUnwrap(VersionedBlob<[String: String]>.decode(from: data))
        XCTAssertEqual(result.version, 1, "The envelope's own version must win.")
        XCTAssertEqual(result.payload["schemaVersion"], "user typed this",
                       "The user's variable must survive intact — this is why variablesData cannot "
                       + "use the inline key.")
    }

    // MARK: - Applied to a real column: contentData

    /// New writes carry the version.
    func testContentDataIsStampedOnWrite() {
        let data = ChatMessageSD.encodeContent(.plainText("hello"), messageID: UUID())
        XCTAssertEqual(BlobVersioning.version(of: data), ChatMessageSD.contentBlobVersion)
    }

    /// ⚠️ THE COMPATIBILITY PROOF, and the reason mechanism A is additive rather than a wrapper.
    /// Every `contentData` blob already on disk is UNSTAMPED. If stamping had changed the shape,
    /// every existing message in every conversation would now decode as `.unknown` — a
    /// forward-compatibility feature turned into mass data degradation.
    func testAlreadyStoredUnstampedContentStillDecodesNormally() throws {
        // Exactly what an existing row holds: encoded before versioning existed.
        let legacy = try JSONEncoder().encode(MessageContent.plainText("written before versioning"))
        XCTAssertNil(BlobVersioning.version(of: legacy))

        let decoded = try JSONDecoder().decode(MessageContent.self, from: legacy)
        XCTAssertEqual(decoded, .plainText("written before versioning"))
        XCTAssertFalse(decoded.isUnrecognised,
                       "A legacy blob decoded as .unknown would mean stamping broke every stored message.")
    }

    /// And a stamped blob decodes to the same value — the version key is inert to the reader.
    func testStampedContentDecodesToTheSameValueAsUnstamped() throws {
        for content: MessageContent in [
            .plainText("plain"),
            .markdownText("# md"),
            .codeBlock(language: "swift", code: "let x = 1"),
            .error(title: "Decode Error", details: "details"),
        ] {
            let stamped = ChatMessageSD.encodeContent(content, messageID: UUID())
            XCTAssertEqual(try JSONDecoder().decode(MessageContent.self, from: stamped), content,
                           "\(content) did not survive stamping.")
        }
    }

    /// ⚠️ The idempotence case, in situ. `.unknown` preserves an unrecognised payload verbatim and
    /// re-emits it — so a blob stamped by a NEWER build, read as `.unknown` here, and saved again
    /// must not accumulate a second version key.
    func testReSavingAnUnknownContentDoesNotDuplicateTheVersionKey() throws {
        let fromNewerBuild = Data(#"{"schemaVersion":99,"type":"hologram","payload":{"a":1}}"#.utf8)
        let decoded = try JSONDecoder().decode(MessageContent.self, from: fromNewerBuild)
        XCTAssertTrue(decoded.isUnrecognised, "A type this build has never heard of must become .unknown.")

        let resaved = ChatMessageSD.encodeContent(decoded, messageID: UUID())
        let keyCount = String(decoding: resaved, as: UTF8.self)
            .components(separatedBy: "schemaVersion").count - 1
        XCTAssertEqual(keyCount, 1, "Re-saving preserved content produced a DUPLICATE version key.")
    }

    // MARK: - Rollout coverage: every blob column carries a version

    /// ⚠️ THE COVERAGE GUARD. A version scheme is only worth having if it is UNIVERSAL — one
    /// unversioned column is the one a future migration still has to guess about, and guessing is
    /// what this whole effort exists to remove. Fails loudly the moment a column is added without a
    /// version, or an existing one loses it.
    func testEveryBlobColumnCarriesAVersion() throws {
        var unversioned: [String] = []
        func check(_ column: String, _ data: Data?) {
            guard let data, !data.isEmpty else { return }
            if BlobVersioning.version(of: data) == nil { unversioned.append(column) }
        }

        // contentData / agentResponseData / tokenUsageData / timelineEventsData
        let message = ChatMessage(conversationId: UUID(), sender: .agent, content: .plainText("hi"))
        message.agentResponse = AgentResponse(variants: [
            ResponseMessageVariant(content: .plainText("v"), backendEntityId: nil)
        ])
        message.timelineEvents = [.thought(id: UUID(), text: "step")]
        message.tokenUsage = TokenUsage(inputTokens: 1, outputTokens: 2, isEstimated: false)
        let sd = ChatMessageSD.from(message)
        check("contentData", sd.contentData)
        check("agentResponseData", sd.agentResponseData)
        check("timelineEventsData", sd.timelineEventsData)
        check("tokenUsageData", sd.tokenUsageData)

        // layoutData
        let layoutRow = WorkflowLayoutSD(workflowProfileID: UUID(), layout: .empty)
        check("layoutData", layoutRow.layoutData)

        // nodeResultsData / variablesData
        let runRow = WorkflowRunRecordSD(record: WorkflowRunRecord(
            id: UUID(), conversationID: UUID(), workflowProfileID: UUID(),
            workflowName: "W", timestamp: Date(), userInput: "go",
            nodeResults: [], finalOutput: "done", variables: ["k": "v"],
            status: .completed, duration: 1, error: nil
        ))
        check("nodeResultsData", runRow.nodeResultsData)
        check("variablesData", runRow.variablesData)

        // attachedFileURLsJSON
        var task = ScheduledTask(
            id: UUID(), displayName: "T", mode: .autonomous, promptTemplate: "p",
            profileID: nil, attachedFileURLs: [URL(fileURLWithPath: "/tmp/a.txt")],
            cronExpression: nil, scheduledAt: nil, isEnabled: true, isPaused: false,
            status: .pending, lastRunAt: nil, nextRunAt: nil, runCount: 0,
            lastRunSummary: nil, linkedConversationID: nil,
            contextWindowMode: .continuous, createdAt: Date()
        )
        task.attachedFileURLs = [URL(fileURLWithPath: "/tmp/a.txt")]
        let taskRow = ScheduledTaskModel()
        taskRow.apply(from: task)
        check("attachedFileURLsJSON", taskRow.attachedFileURLsJSON?.data(using: .utf8))

        XCTAssertTrue(unversioned.isEmpty, """
            These blob columns are written WITHOUT a version discriminator: \
            \(unversioned.joined(separator: ", ")).
            A future migration cannot ask what shape they are and must guess — and a guess that \
            succeeds incorrectly is silent data loss. Stamp object roots with \
            `BlobVersioning.stamped`, wrap array/user-keyed roots in `VersionedBlob`.
            """)
    }

    /// Stamping must not change what any column DECODES to — the compatibility half of the coverage
    /// guard above. A version scheme that quietly alters payloads is worse than none.
    func testVersioningDidNotChangeWhatAnyColumnDecodesTo() throws {
        let message = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText("# hi"))
        message.timelineEvents = [.thought(id: UUID(), text: "step one")]
        message.tokenUsage = TokenUsage(inputTokens: 5, outputTokens: 6, isEstimated: false)
        let sd = ChatMessageSD.from(message)

        let back = sd.toChatMessage()
        XCTAssertEqual(back.content, .markdownText("# hi"))
        XCTAssertEqual(back.timelineEvents.count, 1)
        XCTAssertEqual(back.tokenUsage?.totalTokens, 11)
        XCTAssertFalse(back.content.isUnrecognised,
                       "Stamping made known content decode as .unknown — the wire format changed.")
    }
}

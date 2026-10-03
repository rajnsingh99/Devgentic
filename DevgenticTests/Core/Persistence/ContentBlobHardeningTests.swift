// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ContentBlobHardeningTests.swift
//  DevgenticTests
//
//  Created on 04/08/26.
//
//  Guards `ChatMessageSD.contentData` — the highest-stakes blob in the app, because it IS the
//  conversation.
//
//  Three separate defects were closed here, and they need separate tests because they fail
//  differently:
//    1. FORWARD COMPAT — `MessageContent.init(from:)` ended in
//       `default: throw … "Invalid MessageContent type"`, so one case added by a newer build turned
//       the message into a Decode Error card. Now `.unknown` preserves it verbatim.
//    2. WRITE-BACK — a genuinely corrupt blob still yields the Decode Error card, and BOTH writers
//       re-encoded that card over the original bytes. Now guarded by `canPersistContent`.
//    3. ENCODE FAILURE — `(try? encode(x)) ?? Data()` wrote an EMPTY blob over good data; empty is
//       itself undecodable, so a transient failure became permanent.
//

import XCTest
import SwiftData
@testable import devgentic

final class ContentBlobHardeningTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([ConversationSD.self, ChatMessageSD.self,
                         AttachedTextFileSD.self, AttachedImageFileSD.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// Readable JSON, unknown shape — what a newer build's content looks like to this one.
    private static let futureContent = Data(
        #"{"type":"videoStoryboard","frames":[{"at":0,"caption":"opening"}],"seq":9007199254740993}"#.utf8
    )
    /// Not JSON at all — genuine corruption, which must still produce the Decode Error card.
    private static let corrupt = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

    // MARK: - 1. Forward compatibility

    func testUnknownContentTypeIsPreservedInsteadOfThrowing() throws {
        let content = try JSONDecoder().decode(MessageContent.self, from: Self.futureContent)

        guard case .unknown(let type, _) = content else {
            return XCTFail("Expected .unknown, got \(content)")
        }
        XCTAssertEqual(type, "videoStoryboard")
        XCTAssertTrue(content.isUnrecognised)
    }

    /// Preservation is the whole point — and it must hold for the large integer too, which is why
    /// the carrier has `.int`/`.uint` arms rather than reusing the `Double`-only `JSONValue`.
    func testUnknownContentReEmitsTheSameJSONValue() throws {
        let content = try JSONDecoder().decode(MessageContent.self, from: Self.futureContent)
        let reencoded = try JSONEncoder().encode(content)

        let before = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Self.futureContent) as? NSObject
        )
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: reencoded) as? NSObject)
        XCTAssertTrue(before.isEqual(after),
                      "Unknown content was not preserved:\n  \(String(decoding: reencoded, as: UTF8.self))")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        )
        XCTAssertEqual(object["seq"] as? Int, 9_007_199_254_740_993,
                       "A 2^53+1 integer degraded through Double.")
    }

    /// Known types must be untouched — the wire format cannot change for existing conversations.
    func testKnownContentTypesRoundTripUnchanged() throws {
        let cases: [MessageContent] = [
            .plainText("hello"),
            .markdownText("# hi"),
            .codeBlock(language: "swift", code: "let x = 1"),
            .checkpoint(summary: "summarised"),
            .error(title: "T", details: "D"),
        ]
        for original in cases {
            let decoded = try JSONDecoder().decode(
                MessageContent.self, from: try JSONEncoder().encode(original)
            )
            XCTAssertEqual(decoded, original, "\(original) did not round-trip")
            XCTAssertFalse(decoded.isUnrecognised)
        }
    }

    /// The retired `"image"` type is no longer converted — it is preserved as unknown content, like
    /// any other type this build does not write.
    func testTheRetiredImageTypeIsPreservedAsUnknown() throws {
        let old = Data(#"{"type":"image","imageUrl":"https://example.com/a.png","imageAlt":"alt"}"#.utf8)
        let content = try JSONDecoder().decode(MessageContent.self, from: old)
        XCTAssertTrue(content.isUnrecognised)
    }

    /// Unknown content must not leak into prompts, RAG or exports as invented text.
    func testUnknownContentContributesNoSyntheticText() throws {
        let content = try JSONDecoder().decode(MessageContent.self, from: Self.futureContent)
        XCTAssertNil(content.textContent,
                     "Unknown content produced synthetic text that would reach prompts and RAG.")
    }

    // MARK: - 2. Write-back refusal (genuine corruption)

    func testCorruptContentStillProducesTheDecodeErrorCard() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let sd = ChatMessageSD(
            id: UUID(), conversationId: UUID(), timestamp: Date(), senderType: "agent",
            traceID: nil, contentData: Self.corrupt, agentResponseData: nil, timelineEventsData: nil
        )
        context.insert(sd)
        try context.save()

        let message = sd.toChatMessage()
        guard case .error(let title, _, _, _) = message.content else {
            return XCTFail("Expected the Decode Error card, got \(message.content)")
        }
        XCTAssertEqual(title, "Decode Error")
        XCTAssertNotNil(message.undecodableContentPlaceholder)
        XCTAssertFalse(message.canPersistContent,
                       "A message whose content failed to decode must not overwrite its own bytes.")
    }

    /// THE guarantee, end-to-end through the real store: a routine re-save must not replace
    /// unreadable content with the Decode Error card.
    @MainActor
    func testStoreDoesNotOverwriteUnreadableContentOnReSave() async throws {
        let container = try makeContainer()
        let store = ChatPersistenceStore.shared
        store.configureContainer(container)

        let conversationId = UUID()
        let messageId = UUID()
        let context = ModelContext(container)
        context.insert(ConversationSD(id: conversationId, userDefinedTitle: "C"))
        context.insert(ChatMessageSD(
            id: messageId, conversationId: conversationId, timestamp: Date(), senderType: "agent",
            traceID: nil, contentData: Self.corrupt, agentResponseData: nil, timelineEventsData: nil
        ))
        try context.save()

        let fetched = await store.fetchMessages(for: conversationId, offset: 0, limit: 50)
        let loaded = try XCTUnwrap(fetched.first)
        XCTAssertFalse(loaded.canPersistContent)

        await store.addMessages([loaded], toConversation: conversationId)

        let verify = ModelContext(container)
        let stored = try XCTUnwrap(
            try verify.fetch(FetchDescriptor<ChatMessageSD>()).first { $0.id == messageId }
        )
        XCTAssertEqual(stored.contentData, Self.corrupt,
                       """
                       The unreadable content was replaced by the Decode Error card. The original \
                       message text is now permanently gone.
                       """)
    }

    /// The other half: a deliberate replacement must still write, or a corrupted message would be
    /// permanently stuck as a Decode Error card.
    ///
    /// ⚠️ Uses a USER message deliberately. For an AGENT message `ChatMessage.init` auto-creates an
    /// `agentResponse` whose selected variant SHADOWS `.content`, and both the encoder and
    /// `canPersistContent` read `currentAgentContent ?? content` — so assigning `.content` on an
    /// agent message changes nothing that gets persisted. Found by this test failing.
    @MainActor
    func testDeliberateContentReplacementStillWrites() async throws {
        let container = try makeContainer()
        let store = ChatPersistenceStore.shared
        store.configureContainer(container)

        let conversationId = UUID()
        let messageId = UUID()
        let context = ModelContext(container)
        context.insert(ConversationSD(id: conversationId, userDefinedTitle: "C"))
        context.insert(ChatMessageSD(
            id: messageId, conversationId: conversationId, timestamp: Date(), senderType: "user",
            traceID: nil, contentData: Self.corrupt, agentResponseData: nil, timelineEventsData: nil
        ))
        try context.save()

        let fetched = await store.fetchMessages(for: conversationId, offset: 0, limit: 50)
        let loaded = try XCTUnwrap(fetched.first)
        XCTAssertFalse(loaded.canPersistContent, "Setup: the corrupt blob should be protected first.")
        loaded.content = .plainText("repaired by a real write")
        XCTAssertTrue(loaded.canPersistContent)

        await store.addMessages([loaded], toConversation: conversationId)

        let verify = ModelContext(container)
        let stored = try XCTUnwrap(
            try verify.fetch(FetchDescriptor<ChatMessageSD>()).first { $0.id == messageId }
        )
        XCTAssertNotEqual(stored.contentData, Self.corrupt)
        XCTAssertEqual(try JSONDecoder().decode(MessageContent.self, from: stored.contentData),
                       .plainText("repaired by a real write"))
    }

    /// A healthy message must be entirely unaffected — the guard must not make normal saves no-ops.
    /// User message, for the `currentAgentContent` reason documented above.
    @MainActor
    func testHealthyContentSavesNormally() async throws {
        let container = try makeContainer()
        let store = ChatPersistenceStore.shared
        store.configureContainer(container)

        let conversationId = UUID()
        let messageId = UUID()
        let context = ModelContext(container)
        context.insert(ConversationSD(id: conversationId, userDefinedTitle: "C"))
        context.insert(ChatMessageSD(
            id: messageId, conversationId: conversationId, timestamp: Date(), senderType: "user",
            traceID: nil,
            contentData: try JSONEncoder().encode(MessageContent.plainText("original")),
            agentResponseData: nil, timelineEventsData: nil
        ))
        try context.save()

        let fetched = await store.fetchMessages(for: conversationId, offset: 0, limit: 50)
        let loaded = try XCTUnwrap(fetched.first)
        XCTAssertTrue(loaded.canPersistContent)
        loaded.content = .plainText("updated")

        await store.addMessages([loaded], toConversation: conversationId)

        let verify = ModelContext(container)
        let stored = try XCTUnwrap(
            try verify.fetch(FetchDescriptor<ChatMessageSD>()).first { $0.id == messageId }
        )
        XCTAssertEqual(try JSONDecoder().decode(MessageContent.self, from: stored.contentData),
                       .plainText("updated"))
    }

    /// Unknown-but-readable content needs NO write guard — the codec preserves it — so it must
    /// still be freely persistable, or every such message would freeze.
    func testUnknownContentIsStillPersistable() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let sd = ChatMessageSD(
            id: UUID(), conversationId: UUID(), timestamp: Date(), senderType: "agent",
            traceID: nil, contentData: Self.futureContent, agentResponseData: nil, timelineEventsData: nil
        )
        context.insert(sd)
        try context.save()

        let message = sd.toChatMessage()
        XCTAssertTrue(message.content.isUnrecognised)
        XCTAssertNil(message.undecodableContentPlaceholder,
                     "Readable-but-unknown content is not a decode FAILURE and needs no placeholder.")
        XCTAssertTrue(message.canPersistContent)
    }

    // MARK: - 3. Encode failure must not write empty

    /// `encodeContent` is the single encode path for both writers; it must never emit empty bytes,
    /// because empty is itself undecodable and turns a transient failure into a permanent card.
    func testEncodeContentNeverProducesAnEmptyBlob() throws {
        for content: MessageContent in [
            .plainText(""),
            .markdownText(""),
            .codeBlock(language: nil, code: ""),
            .checkpoint(summary: ""),
        ] {
            let data = ChatMessageSD.encodeContent(content, messageID: UUID())
            XCTAssertFalse(data.isEmpty, "\(content) encoded to an empty blob")
            XCTAssertNoThrow(try JSONDecoder().decode(MessageContent.self, from: data),
                             "\(content) encoded to something undecodable")
        }
    }

    /// ⚠️ THE TEST ABOVE NEVER RAN THE BRANCH IT EXISTS TO PROVE. Every value it feeds encodes
    /// cleanly, so `encodeContent`'s catch — the "Save Error" fallback that stops a transient encode
    /// failure becoming a permanent Decode Error card — was never executed by anything.
    ///
    /// `JSONEncoder` refuses non-conforming floats by default, and `PreservedJSON.double` encodes a
    /// raw `Double`, so `.infinity` inside an `.unknown` payload is a genuine, reachable throw:
    /// content written by a newer build could legitimately contain one.
    func testEncodeContentFallsBackToAReadableCardWhenEncodingThrows() throws {
        let unencodable = MessageContent.unknown(
            type: "sensorReading",
            payload: .object(["value": .double(.infinity)])
        )

        // Precondition: this really does throw, or the test proves nothing.
        XCTAssertThrowsError(try JSONEncoder().encode(unencodable),
                             "PreservedJSON stopped rejecting non-conforming floats — pick another "
                             + "unencodable value or this test is vacuous again.")

        let data = ChatMessageSD.encodeContent(unencodable, messageID: UUID())

        XCTAssertFalse(data.isEmpty,
                       "The fallback wrote an EMPTY blob — empty is itself undecodable, which turns a "
                       + "transient encode failure into a permanent Decode Error card.")
        let decoded = try JSONDecoder().decode(MessageContent.self, from: data)
        guard case .error(let title, _, _, _) = decoded else {
            return XCTFail("Expected the readable Save Error card, got \(decoded)")
        }
        XCTAssertEqual(title, "Save Error")
    }

    // MARK: - G21: an ENCODE failure must not null a column that already holds good bytes

    /// A value whose `encode(to:)` always throws — the only way to exercise the failure branch.
    ///
    /// The existing encode tests all feed trivially-encodable values, so the fallback they exist to
    /// prove never actually ran.
    private struct AlwaysFailsToEncode: Encodable {
        struct Boom: Error {}
        func encode(to encoder: any Encoder) throws { throw Boom() }
    }

    /// ⚠️ THE POINT: `try? JSONEncoder().encode(x)` collapses "this value is legitimately nil" and
    /// "encoding threw" into the same `nil`. On the UPDATE path in `ChatPersistenceStore` that
    /// collapse SET THE COLUMN TO NULL, destroying whatever was already stored — silently, with no
    /// log, on three columns (`agentResponseData`, `timelineEventsData`, `tokenUsageData`).
    func testEncodeFailureReportsPreserveExistingRatherThanNil() {
        let outcome = ChatMessageSD.encodeAuxiliaryBlob(
            AlwaysFailsToEncode(), column: "testColumn", messageID: UUID(), version: 1
        )
        XCTAssertEqual(outcome, .preserveExisting,
                       "An encode failure must be distinguishable from a nil value, or the caller "
                       + "cannot know to leave the existing bytes alone.")
    }

    /// A genuinely nil value still clears the column — the guard must not freeze a column that the
    /// user really did empty.
    func testNilValueStillWritesNil() {
        let outcome = ChatMessageSD.encodeAuxiliaryBlob(
            Optional<AlwaysFailsToEncode>.none, column: "testColumn", messageID: UUID(), version: 1
        )
        XCTAssertEqual(outcome, .write(nil))
    }

    /// And an encodable value round-trips.
    func testEncodableValueIsWritten() throws {
        let outcome = ChatMessageSD.encodeAuxiliaryBlob(
            ["a", "b"], column: "testColumn", messageID: UUID(), version: 1
        )
        guard case .write(let data) = outcome, let data else {
            return XCTFail("Expected .write with data, got \(outcome)")
        }
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: data), ["a", "b"])
    }
}

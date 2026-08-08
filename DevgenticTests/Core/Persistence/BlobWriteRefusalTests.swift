//
//  BlobWriteRefusalTests.swift
//  DevgenticTests
//
//  Created on 04/08/26.
//
//  Guards the two remaining blob columns where a READ failure could become a WRITE failure.
//
//  Both are the same defect class already fixed for `BackendProfile`: a blob that cannot be decoded
//  yields a fallback, and the next save persists that fallback over the user's real bytes. Neither
//  needs a schema change to trigger — the store opens perfectly and the damage happens at read time.
//
//    G16 — `WorkflowLayoutSD.layout` fell back to `.empty` and the setter overwrote `layoutData`,
//          losing the user's entire workflow canvas.
//    G14/G15 — `ChatMessageSD.timelineEventsData` decoded all-or-nothing; a failure left
//          `timelineEvents == []`, and BOTH writers null the column whenever the timeline is empty,
//          so the next flush erased the run's timeline permanently.
//
//  ⚠️ The refusal RULES differ between the three entities, deliberately. See the comments on each
//  test — copying one to another would be wrong.
//

import XCTest
import SwiftData
@testable import devgentic

final class BlobWriteRefusalTests: XCTestCase {

    // MARK: - Helpers

    private func makeContainer(for types: any PersistentModel.Type...) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(types),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// A blob shape neither entity can decode.
    private static let unreadable = Data(#"{"payloadFromTheFuture":true,"nodes":42}"#.utf8)

    private func makeLayout(noteCount: Int) -> WorkflowLayout {
        WorkflowLayout(
            nodes: [], edges: [],
            annotations: (0..<noteCount).map {
                StickyNote(position: CGPoint(x: Double($0), y: 0), text: "note \($0)")
            }
        )
    }

    // MARK: - G16: WorkflowLayoutSD

    /// Persists a layout row carrying an unreadable blob, then returns it **re-materialized in a
    /// fresh context** — the only way the decode path actually runs, since the `@Transient` cache is
    /// populated by `init`.
    private func makeUnreadableLayoutRow(
        in container: ModelContainer, previousNoteCount: Int
    ) throws -> (row: WorkflowLayoutSD, context: ModelContext) {
        let seed = ModelContext(container)
        let row = WorkflowLayoutSD(workflowProfileID: UUID(), layout: makeLayout(noteCount: previousNoteCount))
        seed.insert(row)
        row.layoutData = Self.unreadable
        try seed.save()

        let fresh = ModelContext(container)
        let reloaded = try XCTUnwrap(try fresh.fetch(FetchDescriptor<WorkflowLayoutSD>()).first)
        return (reloaded, fresh)
    }

    func testUnreadableLayoutIsReportedAndCorroboratedByTheCounts() throws {
        let container = try makeContainer(for: WorkflowLayoutSD.self)
        let (row, _) = try makeUnreadableLayoutRow(in: container, previousNoteCount: 3)

        XCTAssertTrue(row.hasUnreadableLayout)
        XCTAssertTrue(row.countsContradictStoredLayout,
                      """
                      The denormalized counts are the only out-of-blob evidence that this row once \
                      held content — BackendProfile had no equivalent. They must survive the failure.
                      """)
        XCTAssertEqual(row.annotationCount, 3, "The counts must not be zeroed by a failed read.")
    }

    /// THE guarantee: any save while the canvas is unreadable is refused.
    ///
    /// ⚠️ STRICTER than the profile rule, on purpose. `BackendProfile` refuses only when the
    /// incoming value IS the placeholder, because a user typing a new model name can see the config
    /// is blank and is knowingly replacing it. A canvas user cannot tell a decode-failure blank
    /// canvas from a legitimately empty one, so every save from that session is uninformed.
    func testAnySaveIsRefusedWhileTheLayoutIsUnreadable() throws {
        let container = try makeContainer(for: WorkflowLayoutSD.self)
        let (row, context) = try makeUnreadableLayoutRow(in: container, previousNoteCount: 3)
        XCTAssertTrue(row.hasUnreadableLayout)

        // Both an "opportunistic empty save" AND a save carrying real content must be refused.
        row.layout = .empty
        row.layout = makeLayout(noteCount: 7)
        try context.save()

        XCTAssertEqual(row.layoutData, Self.unreadable, "The unreadable canvas was overwritten.")
        XCTAssertEqual(row.annotationCount, 3, "The corroborating counts were destroyed.")
    }

    /// The escape hatch must work, or a genuinely corrupt canvas would be permanently unusable.
    func testExplicitRepairReplacesAnUnreadableLayout() throws {
        let container = try makeContainer(for: WorkflowLayoutSD.self)
        let (row, context) = try makeUnreadableLayoutRow(in: container, previousNoteCount: 3)

        row.replaceUnreadableLayout(makeLayout(noteCount: 2), reason: "unit test")
        try context.save()

        XCTAssertFalse(row.hasUnreadableLayout)
        XCTAssertNotEqual(row.layoutData, Self.unreadable)
        XCTAssertEqual(row.annotationCount, 2)
        XCTAssertEqual(row.layout.annotations.count, 2)
    }

    /// ⚠️ THE case that makes this entity different from profiles: emptying the canvas is a LEGAL
    /// user gesture (`WorkflowCanvasState.clearCanvas()` produces exactly `.empty`). On a HEALTHY
    /// row it must be honoured. A value-equality refusal — the profile template — would have
    /// silently swallowed it and left the toolbar claiming unsaved changes forever.
    func testEmptyingAHealthyCanvasIsAllowed() throws {
        let container = try makeContainer(for: WorkflowLayoutSD.self)
        let context = ModelContext(container)
        let row = WorkflowLayoutSD(workflowProfileID: UUID(), layout: makeLayout(noteCount: 4))
        context.insert(row)
        try context.save()
        XCTAssertFalse(row.hasUnreadableLayout)

        row.layout = .empty
        try context.save()

        XCTAssertEqual(row.annotationCount, 0, "A deliberate 'clear canvas' must persist.")
        XCTAssertTrue(row.layout.annotations.isEmpty)
    }

    func testHealthyLayoutSavesNormally() throws {
        let container = try makeContainer(for: WorkflowLayoutSD.self)
        let context = ModelContext(container)
        let row = WorkflowLayoutSD(workflowProfileID: UUID(), layout: makeLayout(noteCount: 1))
        context.insert(row)
        try context.save()

        row.layout = makeLayout(noteCount: 5)
        try context.save()

        let fresh = ModelContext(container)
        let reloaded = try XCTUnwrap(try fresh.fetch(FetchDescriptor<WorkflowLayoutSD>()).first)
        XCTAssertFalse(reloaded.hasUnreadableLayout)
        XCTAssertEqual(reloaded.layout.annotations.count, 5)
        XCTAssertEqual(reloaded.annotationCount, 5)
    }

    // MARK: - G14/G15: the timeline blob

    /// The rule is `decodeFailed && isEmpty` — never `isEmpty` alone.
    ///
    /// ⚠️ Every user message and every bot message legitimately has an empty timeline and must still
    /// be able to clear its column; gating on emptiness alone would freeze those blobs forever.
    func testCanPersistTimelineOnlyBlocksTheExactDataLosingCase() {
        let message = ChatMessage(conversationId: UUID(), sender: .user, content: .plainText("hi"))

        // Healthy and empty — a normal user message. Must be writable.
        XCTAssertTrue(message.canPersistTimeline)

        // Failed decode, nothing appended — the placeholder. This is the only blocked case.
        message.timelineDecodeFailed = true
        XCTAssertFalse(message.canPersistTimeline)

        // Failed decode, but a live run appended real events — a deliberate change, so writable.
        message.timelineEvents = [TimelineEvent.thought(id: UUID(), text: "recovered work")]
        XCTAssertTrue(message.canPersistTimeline)
    }

    /// The flag lives on the VALUE object, not on the model — a `@Transient` would reset between the
    /// fetch that decodes and the separate fetch that writes.
    func testUndecodableTimelineMarksTheMessageOnLoad() throws {
        let container = try makeContainer(
            for: ChatMessageSD.self, ConversationSD.self, AttachedTextFileSD.self, AttachedImageFileSD.self
        )
        let context = ModelContext(container)
        let sd = ChatMessageSD(
            id: UUID(), conversationId: UUID(), timestamp: Date(), senderType: "assistant",
            traceID: nil, contentData: Data("[]".utf8), agentResponseData: nil,
            timelineEventsData: Self.unreadable
        )
        context.insert(sd)
        try context.save()

        let message = sd.toChatMessage()
        XCTAssertTrue(message.timelineDecodeFailed)
        XCTAssertTrue(message.timelineEvents.isEmpty)
        XCTAssertFalse(message.canPersistTimeline,
                       "A message whose timeline failed to decode must not be allowed to null it.")
    }

    // MARK: - G91: the third blob column, which was missed

    /// ⚠️ `contentData` and `timelineEventsData` both got a write refusal; `agentResponseData` did
    /// not — even though its decode-failure branch sets `agentResponse = nil`, and nil is exactly
    /// what both writers persist. So a response blob this build could not read was turned into NULL
    /// on the first flush after the failed load, which happens on any resume or in-flight flush of
    /// the enclosing conversation.
    func testUndecodableAgentResponseMarksTheMessageAndBlocksTheNull() throws {
        let container = try makeContainer(
            for: ChatMessageSD.self, ConversationSD.self, AttachedTextFileSD.self, AttachedImageFileSD.self
        )
        let context = ModelContext(container)
        let sd = ChatMessageSD(
            id: UUID(), conversationId: UUID(), timestamp: Date(), senderType: "assistant",
            traceID: nil, contentData: Data("[]".utf8), agentResponseData: Self.unreadable,
            timelineEventsData: nil
        )
        context.insert(sd)
        try context.save()

        let message = sd.toChatMessage()
        XCTAssertTrue(message.agentResponseDecodeFailed)
        XCTAssertNil(message.agentResponse, "The pinned contract is NO response, not the default one.")
        XCTAssertFalse(message.canPersistAgentResponse,
                       "A message whose response blob failed to decode must not be allowed to null it.")

        // And the INSERT path must honour it too — this path is reached for rebuilt messages.
        XCTAssertNil(ChatMessageSD.from(message).agentResponseData,
                     "A refused response must not be written on the insert path either.")
    }

    /// A healthy response round-trips and never sets the flag.
    func testDecodableAgentResponseDoesNotMarkTheMessage() throws {
        let container = try makeContainer(
            for: ChatMessageSD.self, ConversationSD.self, AttachedTextFileSD.self, AttachedImageFileSD.self
        )
        let context = ModelContext(container)
        let response = AgentResponse(variants: [
            ResponseMessageVariant(content: .plainText("hello"), backendEntityId: nil)
        ])
        let sd = ChatMessageSD(
            id: UUID(), conversationId: UUID(), timestamp: Date(), senderType: "assistant",
            traceID: nil, contentData: Data("[]".utf8),
            agentResponseData: try JSONEncoder().encode(response),
            timelineEventsData: nil
        )
        context.insert(sd)
        try context.save()

        let message = sd.toChatMessage()
        XCTAssertFalse(message.agentResponseDecodeFailed)
        XCTAssertEqual(message.agentResponse?.variants.count, 1)
        XCTAssertTrue(message.canPersistAgentResponse)
    }

    /// The refusal must not FREEZE the column: a regeneration that produces a real response after a
    /// failed load is a deliberate replacement and must write, exactly like the timeline rule.
    func testRealResponseStillWritesAfterAFailedLoad() throws {
        let container = try makeContainer(
            for: ChatMessageSD.self, ConversationSD.self, AttachedTextFileSD.self, AttachedImageFileSD.self
        )
        let context = ModelContext(container)
        let sd = ChatMessageSD(
            id: UUID(), conversationId: UUID(), timestamp: Date(), senderType: "assistant",
            traceID: nil, contentData: Data("[]".utf8), agentResponseData: Self.unreadable,
            timelineEventsData: nil
        )
        context.insert(sd)
        try context.save()

        let message = sd.toChatMessage()
        XCTAssertFalse(message.canPersistAgentResponse)

        message.agentResponse = AgentResponse(variants: [
            ResponseMessageVariant(content: .plainText("regenerated"), backendEntityId: nil)
        ])
        XCTAssertTrue(message.canPersistAgentResponse,
                      "A real regenerated response is a deliberate replacement and must write.")
        XCTAssertNotNil(ChatMessageSD.from(message).agentResponseData)
    }

    // MARK: - G89: variant identity must survive a load

    /// ⚠️ `let variantId: UUID = UUID()` is a Swift trap: the synthesized ENCODER emits an immutable
    /// property that has an initial value, while the synthesized DECODER skips it. The id was
    /// therefore written on every flush and regenerated on every load — churning the blob's bytes,
    /// and, because it participates in synthesized `Equatable`, making a re-fetched conversation
    /// NEVER compare equal to the identical in-memory one.
    func testVariantIdSurvivesARoundTripSoEqualityHolds() throws {
        let response = AgentResponse(variants: [
            ResponseMessageVariant(content: .plainText("one"), backendEntityId: nil),
            ResponseMessageVariant(content: .plainText("two"), backendEntityId: UUID()),
        ])

        let decoded = try JSONDecoder().decode(
            AgentResponse.self, from: JSONEncoder().encode(response)
        )

        XCTAssertEqual(decoded.variants.map(\.variantId), response.variants.map(\.variantId),
                       "variantId regenerated on decode — the id is not round-tripping.")
        XCTAssertEqual(decoded, response,
                       "A response re-read from its own bytes must equal the original, or every "
                       + "consumer of ChatMessage.== / Conversation.== sees a spurious change.")
    }

    /// Encoding twice must be stable — the symptom that made this visible was blob bytes changing
    /// on every load→save cycle even when nothing about the response had changed.
    func testReEncodingALoadedResponseIsStable() throws {
        let original = AgentResponse(variants: [
            ResponseMessageVariant(content: .plainText("stable"), backendEntityId: nil)
        ])
        let first = try JSONEncoder().encode(original)
        let reloaded = try JSONDecoder().decode(AgentResponse.self, from: first)
        let second = try JSONEncoder().encode(reloaded)

        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: first) as? NSDictionary,
            try JSONSerialization.jsonObject(with: second) as? NSDictionary,
            "A load→save cycle changed the blob even though nothing changed."
        )
    }

    /// Tolerance: a blob written before `variantId` existed carries no id and must still decode —
    /// minting one there is correct, and it is stable from that save onward.
    func testVariantWithoutAStoredIdStillDecodes() throws {
        let payload = Data(#"{"content":{"type":"plainText","text":"legacy"}}"#.utf8)
        let variant = try JSONDecoder().decode(ResponseMessageVariant.self, from: payload)
        XCTAssertEqual(variant.content, .plainText("legacy"))
        XCTAssertNil(variant.backendEntityId)
    }

    /// A healthy timeline round-trips and never sets the flag.
    func testDecodableTimelineDoesNotMarkTheMessage() throws {
        let container = try makeContainer(
            for: ChatMessageSD.self, ConversationSD.self, AttachedTextFileSD.self, AttachedImageFileSD.self
        )
        let context = ModelContext(container)
        let events: [TimelineEvent] = [.thought(id: UUID(), text: "step one")]
        let sd = ChatMessageSD(
            id: UUID(), conversationId: UUID(), timestamp: Date(), senderType: "assistant",
            traceID: nil, contentData: Data("[]".utf8), agentResponseData: nil,
            timelineEventsData: try JSONEncoder().encode(events)
        )
        context.insert(sd)
        try context.save()

        let message = sd.toChatMessage()
        XCTAssertFalse(message.timelineDecodeFailed)
        XCTAssertEqual(message.timelineEvents.count, 1)
        XCTAssertTrue(message.canPersistTimeline)
    }

    /// `ChatMessageSD.from` must honour the flag too — it is reached for messages rebuilt from a
    /// load, not only for fresh inserts.
    func testFromDoesNotEncodeATimelineItMustNotPersist() {
        let message = ChatMessage(conversationId: UUID(), sender: .agent, content: .plainText("x"))
        message.timelineDecodeFailed = true

        let sd = ChatMessageSD.from(message)

        XCTAssertNil(sd.timelineEventsData,
                     "A fresh insert has nothing to protect, so nil is correct here — but the "
                     + "guard must not crash or invent data.")
        XCTAssertFalse(message.canPersistTimeline)
    }

    /// The flag describes THIS LOAD, not the message, so it must not leak into persisted identity.
    func testDecodeFailureFlagIsNotPersisted() throws {
        let container = try makeContainer(
            for: ChatMessageSD.self, ConversationSD.self, AttachedTextFileSD.self, AttachedImageFileSD.self
        )
        let context = ModelContext(container)
        let events: [TimelineEvent] = [.thought(id: UUID(), text: "kept")]
        let sd = ChatMessageSD(
            id: UUID(), conversationId: UUID(), timestamp: Date(), senderType: "assistant",
            traceID: nil, contentData: Data("[]".utf8), agentResponseData: nil,
            timelineEventsData: try JSONEncoder().encode(events)
        )
        context.insert(sd)
        try context.save()

        // A message that failed once must not poison a later, healthy load of the same row.
        _ = sd.toChatMessage()
        let second = sd.toChatMessage()
        XCTAssertFalse(second.timelineDecodeFailed)
    }

    // MARK: - The actual destructive path (ChatPersistenceStore)

    /// END-TO-END through the real store. This is the write that destroyed data: `addMessages`
    /// re-persists an existing message and nulls `timelineEventsData` whenever the in-memory
    /// timeline is empty.
    ///
    /// ⚠️ The `timelineRevision` skip-cache is NOT what protects this — it is the opposite. The
    /// revision is seeded randomly per instance so two instances of the same persisted message can
    /// never alias, which means a freshly-loaded message ALWAYS looks changed and the very first
    /// flush takes the write branch. That is exactly when an undecodable blob would be nulled.
    @MainActor
    func testStoreDoesNotNullAnUndecodableTimelineOnReSave() async throws {
        let container = try makeContainer(
            for: ConversationSD.self, ChatMessageSD.self,
            AttachedTextFileSD.self, AttachedImageFileSD.self
        )
        let store = ChatPersistenceStore.shared
        store.configureContainer(container)

        let conversationId = UUID()
        let messageId = UUID()
        let context = ModelContext(container)
        context.insert(ConversationSD(id: conversationId, userDefinedTitle: "Run"))
        let sd = ChatMessageSD(
            id: messageId, conversationId: conversationId, timestamp: Date(), senderType: "agent",
            traceID: nil, contentData: Data("[]".utf8), agentResponseData: nil,
            timelineEventsData: Self.unreadable
        )
        context.insert(sd)
        try context.save()

        // Load it the way the app does — the decode fails and marks the message.
        let fetched = await store.fetchMessages(for: conversationId, offset: 0, limit: 50)
        let loaded = try XCTUnwrap(fetched.first)
        XCTAssertTrue(loaded.timelineDecodeFailed)
        XCTAssertTrue(loaded.timelineEvents.isEmpty)

        // Re-persist it, as any later flush of this conversation would.
        await store.addMessages([loaded], toConversation: conversationId)

        let verify = ModelContext(container)
        let stored = try XCTUnwrap(
            try verify.fetch(FetchDescriptor<ChatMessageSD>()).first { $0.id == messageId }
        )
        XCTAssertEqual(stored.timelineEventsData, Self.unreadable,
                       """
                       The undecodable timeline blob was NULLED by a routine re-save. That is the                        G14/G15 data loss: the run's entire timeline is gone, not merely unrendered.
                       """)
    }

    /// The other half: a message that genuinely has no timeline must still be able to clear its
    /// column, and a live run that appended events onto a failed load must still persist them.
    @MainActor
    func testStoreStillWritesWhenThereIsSomethingRealToWrite() async throws {
        let container = try makeContainer(
            for: ConversationSD.self, ChatMessageSD.self,
            AttachedTextFileSD.self, AttachedImageFileSD.self
        )
        let store = ChatPersistenceStore.shared
        store.configureContainer(container)

        let conversationId = UUID()
        let messageId = UUID()
        let context = ModelContext(container)
        context.insert(ConversationSD(id: conversationId, userDefinedTitle: "Run"))
        context.insert(ChatMessageSD(
            id: messageId, conversationId: conversationId, timestamp: Date(), senderType: "agent",
            traceID: nil, contentData: Data("[]".utf8), agentResponseData: nil,
            timelineEventsData: Self.unreadable
        ))
        try context.save()

        let fetched = await store.fetchMessages(for: conversationId, offset: 0, limit: 50)
        let loaded = try XCTUnwrap(fetched.first)
        // A live run appends onto the failed load — a deliberate change, so it must be written.
        loaded.timelineEvents = [TimelineEvent.thought(id: UUID(), text: "new work")]
        XCTAssertTrue(loaded.canPersistTimeline)

        await store.addMessages([loaded], toConversation: conversationId)

        let verify = ModelContext(container)
        let stored = try XCTUnwrap(
            try verify.fetch(FetchDescriptor<ChatMessageSD>()).first { $0.id == messageId }
        )
        XCTAssertNotEqual(stored.timelineEventsData, Self.unreadable,
                          "Real appended events must overwrite the unreadable blob.")
        // ⚠️ Read through `decodeTimeline`, not a bare `[TimelineEvent]` decode. Since G19 the
        // timeline is written as a `VersionedBlob` envelope (an ARRAY has nowhere to put a version
        // key), so a raw array decode asserts an on-disk shape that is no longer the current one —
        // it would fail here while the behaviour under test is perfectly fine.
        let decoded = try ChatMessageSD.decodeTimeline(from: try XCTUnwrap(stored.timelineEventsData))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(BlobVersioning.version(of: try XCTUnwrap(stored.timelineEventsData)),
                       ChatMessageSD.timelineBlobVersion,
                       "New timeline writes must carry the version.")
    }

    // MARK: - The guard must not depend on access order

    /// ⚠️ THE REGRESSION THIS FILE MOST NEEDED AND DID NOT HAVE.
    ///
    /// `_layoutDecodeFailed` is `@Transient`, so it is `false` on every freshly materialized instance
    /// and was set ONLY by the getter. Every existing test in this file reads `hasUnreadableLayout`
    /// (or `layout`) before writing, which primes the flag — so they all passed while the real
    /// production path did not: `WorkflowLayoutStore.save` fetches a row and assigns straight to
    /// `layout`, and that write sailed past the refusal and destroyed the unreadable blob.
    ///
    /// This test writes with NO prior read, which is the only shape that reproduces it.
    func testSetterRefusesWithoutAPriorReadToPrimeTheFlag() throws {
        let container = try makeContainer(for: WorkflowLayoutSD.self)
        let (row, _) = try makeUnreadableLayoutRow(in: container, previousNoteCount: 3)

        // NOTHING reads `row.layout` or `row.hasUnreadableLayout` first — that is the whole point.
        row.layout = makeLayout(noteCount: 99)

        XCTAssertEqual(row.layoutData, Self.unreadable,
                       "The setter must refuse on a row whose getter never ran; the guard cannot "
                       + "depend on someone happening to read first.")
        XCTAssertEqual(row.nodeCount, 0)
        XCTAssertEqual(row.annotationCount, 3, "The denormalized counts must survive the refusal.")
    }

    /// The same ordering hazard on `BackendProfileSD`. It works today only because the opportunistic
    /// savers read `details` before writing; this pins the behaviour so it stops being an accident.
    func testProfileRefusalDoesNotDependOnAPriorRead() throws {
        let container = try makeContainer(for: BackendProfile.self)
        let seed = ModelContext(container)
        let profile = BackendProfile(
            displayName: "Configured", details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
        )
        seed.insert(profile)
        profile.configData = Self.unreadable
        try seed.save()

        let fresh = ModelContext(container)
        let reloaded = try XCTUnwrap(try fresh.fetch(FetchDescriptor<BackendProfile>()).first)

        // No prior read. Hand back exactly what a decode failure would have produced.
        let placeholder = BackendProfileSD_placeholderForTesting()
        reloaded.details = placeholder

        XCTAssertEqual(reloaded.configData, Self.unreadable,
                       "An opportunistic save must be refused even when nothing read `details` first.")
    }

    /// The placeholder `decodeDetails` issues on failure, obtained the same way production does.
    private func BackendProfileSD_placeholderForTesting() -> ProfileDetails {
        let container = try! makeContainer(for: BackendProfile.self)
        let ctx = ModelContext(container)
        let p = BackendProfile(displayName: "x", details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"))))
        ctx.insert(p)
        p.configData = Self.unreadable
        try! ctx.save()
        let fresh = ModelContext(container)
        return (try! fresh.fetch(FetchDescriptor<BackendProfile>()).first!).details
    }

    // MARK: - The refusal must reach the caller

    /// `WorkflowLayoutStore.save` used to return `Void`, so the model's refusal had nowhere to go and
    /// the canvas kept accepting edits that were silently discarded. The outcome is the seam a UI
    /// needs in order to say so.
    /// ⚠️ Uses an ON-DISK store opened by TWO containers, deliberately. The corruption has to be
    /// visible to a genuinely freshly-materialized instance, and an in-memory container hands back
    /// the same registered object whose `@Transient` cache `init` already populated — so the decode
    /// path never runs and the test proves nothing. Two containers over one file is also the honest
    /// model of how this arises in production: written one launch, read the next.
    @MainActor
    func testStoreReportsTheRefusalAndRepairClearsIt() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-refusal-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let profileID = UUID()

        // Launch 1: write a real canvas, then corrupt the blob underneath it.
        do {
            let seeding = try ModelContainer(
                for: Schema([WorkflowLayoutSD.self]),
                configurations: ModelConfiguration(url: storeURL)
            )
            let context = ModelContext(seeding)
            let row = WorkflowLayoutSD(workflowProfileID: profileID, layout: makeLayout(noteCount: 4))
            context.insert(row)
            row.layoutData = Self.unreadable
            try context.save()
        }

        // Launch 2: a fresh container, so nothing is cached.
        let container = try ModelContainer(
            for: Schema([WorkflowLayoutSD.self]),
            configurations: ModelConfiguration(url: storeURL)
        )
        WorkflowLayoutStore.shared.configureContainer(container)

        XCTAssertTrue(WorkflowLayoutStore.shared.isLayoutUnreadable(for: profileID))

        let outcome = WorkflowLayoutStore.shared.save(makeLayout(noteCount: 1), for: profileID)
        XCTAssertEqual(outcome, .refusedUnreadable(nodeCount: 0, edgeCount: 0, annotationCount: 4),
                       "The store must REPORT the refusal — a Void return is how the canvas ended up "
                       + "accepting edits that were silently discarded.")
        XCTAssertFalse(outcome.didPersist)

        let afterRefusal = try XCTUnwrap(
            try container.mainContext.fetch(FetchDescriptor<WorkflowLayoutSD>()).first
        )
        XCTAssertEqual(afterRefusal.layoutData, Self.unreadable,
                       "Refusal must leave the bytes untouched.")

        // The explicit escape hatch is the only way past it.
        let repaired = WorkflowLayoutStore.shared.repairUnreadableLayout(
            makeLayout(noteCount: 2), for: profileID, reason: "unit test"
        )
        XCTAssertEqual(repaired, .saved)
        XCTAssertFalse(WorkflowLayoutStore.shared.isLayoutUnreadable(for: profileID))
        XCTAssertTrue(WorkflowLayoutStore.shared.save(makeLayout(noteCount: 5), for: profileID).didPersist,
                      "Ordinary saves must work again after a repair.")
    }
}

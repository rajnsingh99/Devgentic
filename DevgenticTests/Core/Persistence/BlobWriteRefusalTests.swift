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

    // MARK: - WF-PE2: newer-version blobs are read-only, never downgraded

    /// Persists a VALID layout whose blob is then re-stamped as a newer version, re-materialized
    /// cold so `primeDecodeState` actually runs.
    private func makeNewerVersionLayoutRow(
        in container: ModelContainer
    ) throws -> (row: WorkflowLayoutSD, context: ModelContext, originalBytes: Data) {
        let seed = ModelContext(container)
        let row = WorkflowLayoutSD(workflowProfileID: UUID(), layout: makeLayout(noteCount: 3))
        seed.insert(row)
        // Simulate the newer build's write: same payload, higher stamp.
        let restamped = String(data: row.layoutData, encoding: .utf8)!
            .replacingOccurrences(of: "\"schemaVersion\":\(WorkflowLayoutSD.layoutBlobVersion)",
                                  with: "\"schemaVersion\":\(WorkflowLayoutSD.layoutBlobVersion + 1)")
        XCTAssertNotEqual(restamped, String(data: row.layoutData, encoding: .utf8)!,
                          "precondition: the restamp must actually change the version")
        row.layoutData = Data(restamped.utf8)
        try seed.save()

        let fresh = ModelContext(container)
        let reloaded = try XCTUnwrap(try fresh.fetch(FetchDescriptor<WorkflowLayoutSD>()).first)
        return (reloaded, fresh, Data(restamped.utf8))
    }

    /// The stamp was WRITE-ONLY: a newer blob decoded cleanly, and the next save re-encoded the
    /// in-memory struct freshly stamped at this build's version — permanently stripping every
    /// newer-version field with no error and no log. The blob must now be readable but REFUSE writes.
    func testNewerVersionLayoutIsViewableButRefusesWrites() throws {
        let container = try makeContainer(for: WorkflowLayoutSD.self)
        let (row, context, originalBytes) = try makeNewerVersionLayoutRow(in: container)

        // Viewable and runnable: the decode genuinely succeeded.
        XCTAssertTrue(row.hasNewerVersionLayout)
        XCTAssertFalse(row.hasUnreadableLayout,
                       "newer-version is NOT corruption — conflating them steers the user to the destructive repair")
        XCTAssertEqual(row.layout.annotations.count, 3, "the graph itself must stay readable")

        // …but a save on this build must be refused with the bytes left intact.
        row.layout = makeLayout(noteCount: 0)
        try context.save()
        XCTAssertEqual(row.layoutData, originalBytes,
                       "the refused write must leave the newer build's bytes byte-for-byte intact")
    }

    /// The control: this build's own stamp saves normally — the refusal must not catch v-current.
    func testCurrentVersionLayoutStillSaves() throws {
        let container = try makeContainer(for: WorkflowLayoutSD.self)
        let seed = ModelContext(container)
        let row = WorkflowLayoutSD(workflowProfileID: UUID(), layout: makeLayout(noteCount: 3))
        seed.insert(row)
        try seed.save()

        let fresh = ModelContext(container)
        let reloaded = try XCTUnwrap(try fresh.fetch(FetchDescriptor<WorkflowLayoutSD>()).first)
        XCTAssertFalse(reloaded.hasNewerVersionLayout)

        reloaded.layout = makeLayout(noteCount: 5)
        try fresh.save()
        XCTAssertEqual(reloaded.layout.annotations.count, 5, "an ordinary save must still work")
    }

    // MARK: - WF-TS5: what the version stamp is actually protecting

    /// The JSON key a FUTURE build would have added. Injected by string surgery on purpose: the
    /// point is a key no `CodingKeys` in THIS build knows, which by definition cannot be produced
    /// by encoding a current-build value.
    private static let futureNodeKey = "concurrencyLimit"

    private func makeLayoutWithConfiguredNode() -> WorkflowLayout {
        var node = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Worker")
        node.nodeConfig = WorkflowNodeConfig(maxNodeRetries: 2)
        return WorkflowLayout(nodes: [node], edges: [], annotations: [])
    }

    /// v(current+1) bytes carrying `futureNodeKey` inside `nodeConfig`. The replacement is
    /// position-independent — `"maxNodeRetries":` may be first, middle or last in the encoded
    /// object and the spliced result is valid JSON either way.
    private func makeFutureBuildLayoutBytes() throws -> Data {
        let encoded = try JSONEncoder().encode(makeLayoutWithConfiguredNode())
        let withFutureKey = String(data: encoded, encoding: .utf8)!
            .replacingOccurrences(of: "\"maxNodeRetries\":",
                                  with: "\"\(Self.futureNodeKey)\":4,\"maxNodeRetries\":")
        XCTAssertTrue(withFutureKey.contains(Self.futureNodeKey), "precondition: the injection must land")
        return BlobVersioning.stamped(Data(withFutureKey.utf8),
                                      version: WorkflowLayoutSD.layoutBlobVersion + 1)
    }

    /// ⚠️ THE ASSERTION THE FORWARD-COMPAT SUITE NEVER MAKES (WF-TS5). Every test in
    /// `WorkflowLayoutForwardCompatTests` mutates an enum RAW VALUE; none adds a FIELD. Unknown
    /// keys are NOT preserved by any Codable in `WorkflowModels.swift` — there is no extras bag —
    /// so the version stamp is the ONLY thing standing between a newer build's added field and its
    /// permanent loss.
    ///
    /// ⚠️ Uses the ON-DISK two-container pattern, not an in-memory container: in-memory hands
    /// `WorkflowLayoutStore.shared.mainContext` back the same registered instance whose `@Transient`
    /// cache `init` already populated, so the decode path never runs and the test proves nothing.
    @MainActor
    func testNewerVersionBlobKeepsAFutureFieldTheDecoderCannotSee() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-futurekey-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let profileID = UUID()
        let futureBytes = try makeFutureBuildLayoutBytes()

        // Launch 1: the newer build's write.
        do {
            let seeding = try ModelContainer(for: Schema([WorkflowLayoutSD.self]),
                                             configurations: ModelConfiguration(url: storeURL))
            let context = ModelContext(seeding)
            let row = WorkflowLayoutSD(workflowProfileID: profileID, layout: makeLayoutWithConfiguredNode())
            context.insert(row)
            row.layoutData = futureBytes
            try context.save()
        }

        // Launch 2 — the ROLLED-BACK build. Nothing is cached.
        let container = try ModelContainer(for: Schema([WorkflowLayoutSD.self]),
                                           configurations: ModelConfiguration(url: storeURL))
        WorkflowLayoutStore.shared.configureContainer(container)

        // It decodes and runs: unknown keys never throw, which is exactly what made the loss silent.
        let loaded = WorkflowLayoutStore.shared.load(for: profileID)
        XCTAssertEqual(loaded.nodes.count, 1, "the graph must stay readable and runnable")
        XCTAssertEqual(loaded.nodes[0].nodeConfig?.maxNodeRetries, 2)

        // The save must be REFUSED, and the store must SAY SO — this outcome had no test at all.
        let outcome = WorkflowLayoutStore.shared.save(makeLayoutWithConfiguredNode(), for: profileID)
        XCTAssertEqual(outcome,
                       .refusedNewerVersion(blobVersion: WorkflowLayoutSD.layoutBlobVersion + 1,
                                            appVersion: WorkflowLayoutSD.layoutBlobVersion))
        XCTAssertFalse(outcome.didPersist)

        // …and the future field is still on disk, byte-for-byte.
        //
        // ⚠️ MUTATION NOTE (measured, not assumed): these two halves are guarded by DIFFERENT
        // code. Disabling `WorkflowLayoutStore.save`'s `hasNewerVersionLayout` check flips the
        // outcome above to `.saved` but leaves these bytes intact, because `WorkflowLayoutSD`'s
        // `layout` setter refuses a second time. So the store guard is what makes the refusal
        // OBSERVABLE to the caller; the setter is what makes it SAFE. Both are pinned here, and
        // neither assertion can stand in for the other.
        let stored = try XCTUnwrap(
            try container.mainContext.fetch(FetchDescriptor<WorkflowLayoutSD>()).first)
        XCTAssertEqual(stored.layoutData, futureBytes,
                       "the refused write must leave the newer build's bytes intact")
        XCTAssertTrue(String(data: stored.layoutData, encoding: .utf8)!.contains(Self.futureNodeKey),
                      "WF-TS5: the field a newer build added was laundered out of the blob by an "
                      + "older build's save. No Codable in WorkflowModels.swift preserves unknown "
                      + "keys, so the version refusal is the only thing that can prevent this.")
    }

    // MARK: - WF-PE3: a save FAILURE leaves nothing pending on the shared context

    /// Every store shares one `container.mainContext`, and `save` mutates the model BEFORE
    /// `context.save()`. A throw there used to leave the mutation PENDING — so the very next save
    /// any other store performed (in the shipped path, `profileService.saveProfile` on the next
    /// line of the canvas's `saveLayout`) silently flushed the "failed" layout after all. `.failed`
    /// must mean "not on disk AND nothing pending", which is what the caller's guard relies on.
    ///
    /// A read-only container (`allowsSave: false`) makes `context.save()` throw DETERMINISTICALLY —
    /// no disk-full simulation needed.
    @MainActor
    func testFailedUpdateSaveRollsBackThePendingMutation() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-pe3-update-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let profileID = UUID()

        // Launch 1 (writable): the row the user last successfully saved — ONE note.
        do {
            let seeding = try ModelContainer(for: Schema([WorkflowLayoutSD.self]),
                                             configurations: ModelConfiguration(url: storeURL))
            let context = ModelContext(seeding)
            context.insert(WorkflowLayoutSD(workflowProfileID: profileID, layout: makeLayout(noteCount: 1)))
            try context.save()
        }

        // Launch 2 (read-only): every context.save() will throw.
        let readOnly = try ModelContainer(
            for: Schema([WorkflowLayoutSD.self]),
            configurations: ModelConfiguration(url: storeURL, allowsSave: false))
        WorkflowLayoutStore.shared.configureContainer(readOnly)

        let outcome = WorkflowLayoutStore.shared.save(makeLayout(noteCount: 5), for: profileID)

        guard case .failed = outcome else {
            return XCTFail("Precondition: a read-only container must fail the save, got \(outcome)")
        }
        XCTAssertFalse(outcome.didPersist)

        // ⚠️ THE CONTRACT. Read back through the SAME context the store mutated: it must hold the
        // PRIOR layout, not the failed one. Without the rollback this fetch shows 5 notes — the
        // pending mutation — which is exactly what a later unrelated save would have flushed.
        let row = try XCTUnwrap(
            try readOnly.mainContext.fetch(FetchDescriptor<WorkflowLayoutSD>()).first)
        XCTAssertEqual(row.layout.annotations.count, 1,
                       "a failed save must leave the in-memory row at its last-persisted state — "
                       + "a pending 'failed' layout rides out on the shared context's next save")
    }

    /// The insert-path twin: the first-ever save of a profile failing must leave NO pending row on
    /// the main context, or the phantom rides out the same way. (⚠️ Measured: retracting via
    /// `context.delete(pendingInsert)` after a throwing save does NOT work — SwiftData still
    /// returns the row from a fetch on that context — which is why the store stages first inserts
    /// on a throwaway context instead.)
    @MainActor
    func testFailedInsertSaveRetractsThePendingRow() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-pe3-insert-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        // Launch 1 (writable): materialize the store file with NO layout rows.
        _ = try ModelContainer(for: Schema([WorkflowLayoutSD.self]),
                               configurations: ModelConfiguration(url: storeURL))

        let readOnly = try ModelContainer(
            for: Schema([WorkflowLayoutSD.self]),
            configurations: ModelConfiguration(url: storeURL, allowsSave: false))
        WorkflowLayoutStore.shared.configureContainer(readOnly)

        let outcome = WorkflowLayoutStore.shared.save(makeLayout(noteCount: 2), for: UUID())

        guard case .failed = outcome else {
            return XCTFail("Precondition: a read-only container must fail the save, got \(outcome)")
        }
        let pending = try readOnly.mainContext.fetch(FetchDescriptor<WorkflowLayoutSD>())
        XCTAssertTrue(pending.isEmpty,
                      "a failed first save must retract its insert — a pending phantom row rides "
                      + "out on the shared context's next save")
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

    // MARK: - WF-PE2: refused-by-design must not be treated as a retriable failure

    /// The exhaustive classifier `persistDirtyWorkflowCanvases` and the quit-time alert both key
    /// off. Written exhaustively (a `switch` with no `default`, mirroring the property's own
    /// implementation) so a SIXTH case added to `WorkflowLayoutSaveOutcome` fails to COMPILE here
    /// rather than silently defaulting to the wrong bucket — the exact silent-drift class of defect
    /// this session has hit before with other exhaustive-switch additions.
    func testIsRefusedByDesignIsExhaustiveAndCorrectPerCase() {
        let cases: [(WorkflowLayoutSaveOutcome, Bool)] = [
            (.saved, false),
            (.notConfigured, false),
            (.refusedUnreadable(nodeCount: 1, edgeCount: 2, annotationCount: 3), true),
            (.refusedNewerVersion(blobVersion: 4, appVersion: 3), true),
            (.failed("disk full"), false),
        ]
        for (outcome, expected) in cases {
            XCTAssertEqual(outcome.isRefusedByDesign, expected,
                           "got \(outcome.isRefusedByDesign) for \(outcome), wanted \(expected)")
        }
    }

    /// ⚠️ NOT a duplicate of the exhaustive table above despite the overlapping cases — this checks
    /// a CROSS-PROPERTY invariant the table doesn't: `isRefusedByDesign == false` must imply
    /// `quitTimeRefusalReason == nil`. A mutation that widened one property's cases without the
    /// other (e.g. a future outcome case marked refused but given no reason text, or vice versa)
    /// would pass every row of the exhaustive table yet break this.
    func testNonRefusedOutcomesHaveNoRefusalReason() {
        let nonRefused: [WorkflowLayoutSaveOutcome] = [.saved, .notConfigured, .failed("disk full")]
        for outcome in nonRefused {
            XCTAssertFalse(outcome.isRefusedByDesign, "precondition for \(outcome)")
            XCTAssertNil(outcome.quitTimeRefusalReason,
                        "isRefusedByDesign says no, but a reason exists — got: \(outcome.quitTimeRefusalReason ?? "nil")")
        }
    }

    /// The quit-time alert's copy — must name the actual reason (interpolating the real version
    /// numbers, POSITIONALLY, not just present as substrings — a transposed blobVersion/appVersion
    /// would still contain both digits and read backwards, telling the user their build is the
    /// newer one when the opposite is true), and must be nil for every case the caller should never
    /// be asking about (guarded by `isRefusedByDesign` before this is ever read).
    func testQuitTimeRefusalReasonNamesTheRealReason() {
        let unreadable = WorkflowLayoutSaveOutcome.refusedUnreadable(nodeCount: 1, edgeCount: 2, annotationCount: 3)
        let unreadableReason = try? XCTUnwrap(unreadable.quitTimeRefusalReason)
        XCTAssertNotNil(unreadableReason)

        let newer = WorkflowLayoutSaveOutcome.refusedNewerVersion(blobVersion: 5, appVersion: 3)
        let newerReason = newer.quitTimeRefusalReason
        XCTAssertNotNil(newerReason)
        XCTAssertTrue(newerReason?.contains("v5 format") == true,
                      "the STORED version must read as v5 — a transposition would still pass a bare .contains(\"5\") check. got: \(newerReason ?? "nil")")
        XCTAssertTrue(newerReason?.contains("writes v3") == true,
                      "this BUILD must read as v3 — got: \(newerReason ?? "nil")")

        XCTAssertNil(WorkflowLayoutSaveOutcome.saved.quitTimeRefusalReason)
        XCTAssertNil(WorkflowLayoutSaveOutcome.notConfigured.quitTimeRefusalReason)
        XCTAssertNil(WorkflowLayoutSaveOutcome.failed("disk full").quitTimeRefusalReason)
    }

    /// End-to-end: a layout genuinely refused as unreadable, saved through the REAL store, still
    /// reports `isRefusedByDesign == true` and a non-nil reason — the classifier is exercised
    /// against a real `WorkflowLayoutSaveOutcome` the store actually returned, not just a
    /// hand-constructed enum value, closing the gap between "the cases match" and "the store's own
    /// refusal reaches the classifier unchanged."
    ///
    /// ⚠️ ON-DISK two-container pattern, like `testStoreReportsTheRefusalAndRepairClearsIt` above —
    /// NOT `makeContainer`'s in-memory helper. An in-memory container hands
    /// `WorkflowLayoutStore.shared.mainContext` back the SAME registered instance whose `@Transient`
    /// cache `init` already populated, so the decode path never runs and the test proves nothing
    /// (an earlier draft of this test used the in-memory helper and failed with `.saved` instead of
    /// the refusal, for exactly that reason).
    @MainActor
    func testRealRefusedUnreadableOutcomeClassifiesCorrectly() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-pe2-unreadable-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let profileID = UUID()

        do {
            let seeding = try ModelContainer(for: Schema([WorkflowLayoutSD.self]),
                                              configurations: ModelConfiguration(url: storeURL))
            let context = ModelContext(seeding)
            let row = WorkflowLayoutSD(workflowProfileID: profileID, layout: makeLayout(noteCount: 1))
            context.insert(row)
            row.layoutData = Self.unreadable
            try context.save()
        }

        let container = try ModelContainer(for: Schema([WorkflowLayoutSD.self]),
                                            configurations: ModelConfiguration(url: storeURL))
        WorkflowLayoutStore.shared.configureContainer(container)

        let outcome = WorkflowLayoutStore.shared.save(makeLayout(noteCount: 1), for: profileID)
        XCTAssertTrue(outcome.isRefusedByDesign, "got: \(outcome)")
        XCTAssertNotNil(outcome.quitTimeRefusalReason)
    }

    /// Same, for the newer-version path — reuses the exact on-disk two-container lever
    /// `testNewerVersionBlobKeepsAFutureFieldTheDecoderCannotSee` above establishes
    /// (`BlobVersioning.stamped`, never an in-memory container — that hands back the same cached
    /// registered instance and the decode path never runs).
    @MainActor
    func testRealRefusedNewerVersionOutcomeClassifiesCorrectly() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-pe2-newer-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let profileID = UUID()

        let stampedBytes = try BlobVersioning.stamped(
            JSONEncoder().encode(makeLayout(noteCount: 1)),
            version: WorkflowLayoutSD.layoutBlobVersion + 1)

        do {
            let seeding = try ModelContainer(for: Schema([WorkflowLayoutSD.self]),
                                              configurations: ModelConfiguration(url: storeURL))
            let context = ModelContext(seeding)
            let row = WorkflowLayoutSD(workflowProfileID: profileID, layout: makeLayout(noteCount: 1))
            context.insert(row)
            row.layoutData = stampedBytes
            try context.save()
        }

        let container = try ModelContainer(for: Schema([WorkflowLayoutSD.self]),
                                            configurations: ModelConfiguration(url: storeURL))
        WorkflowLayoutStore.shared.configureContainer(container)

        let outcome = WorkflowLayoutStore.shared.save(makeLayout(noteCount: 1), for: profileID)
        XCTAssertTrue(outcome.isRefusedByDesign, "got: \(outcome)")
        XCTAssertNotNil(outcome.quitTimeRefusalReason)
    }
}

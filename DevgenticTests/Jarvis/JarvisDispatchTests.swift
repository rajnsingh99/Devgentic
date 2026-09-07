//
//  JarvisDispatchTests.swift
//  DevgenticTests
//
//  Jarvis had 261 tests across 20 classes and NONE of them touched the dispatch — zero references
//  to `startMessageStream` in the whole Jarvis suite. Its voice stack (ASR, approvals, narration,
//  speaker, config) was thoroughly covered; what it handed to the send path was not. That is the
//  gap this file closes, and it is the gap the orphan defect lived in for the entire life of the
//  feature.
//
//  ⚠️ THE DEFECT, stated once. Jarvis persists the CLEAN spoken command (so the chat window shows
//  what was said) and sends the model the command PLUS a spoken-style hint. Those are two
//  different strings. `BackendOrchestrationService` used to strip the current question out of
//  history by comparing TEXT against `userQuery`, so for every voice turn in every speaking mode
//  the comparison failed, the question survived into the episodic blob, and
//  `EpisodicHistoryFormatter.pairTurns` emitted it through its orphan handler as
//  `wasCancelled: true` / "Agent never responded to this query". Every voice turn told the model
//  that the question it was being asked had already been abandoned.
//
//  The strip is now BY ID. That only works if the row Jarvis persists and the row it hands to the
//  send path are ONE message — same object, same id, differing only in the model-facing text
//  carried separately as `promptOverride`. `JarvisSpokenStyleHintTests` already pins that the
//  TEXT diverges correctly; nothing pinned that the IDENTITY does not. These tests do.
//
//  ⚠️ Why `voiceTurn` and not `execute(_:)`. The dispatch reaches four singletons
//  (`WhisperRecognitionService`, `JarvisConfigManager`, `SessionToolApprovals`,
//  `ChatPersistenceStore`) and a `MainApplicationViewModel`, whose init runs
//  `ChatOpsCoordinator.bootstrap()` and opens REAL Telegram/Discord/Slack connections when the
//  developer has them enabled. A unit test must never be able to do that. The contract that
//  actually carries the defect is extracted instead — the same treatment
//  `SchedulerCoordinator.prepareScheduledRequest` and `MessagingCoordinator.deliverCheckpoint`
//  got. What remains untested here is the surrounding orchestration (approvals, notification,
//  stream bookkeeping); that gap is real and is recorded rather than implied away.
//

import XCTest
@testable import devgentic


@MainActor
final class JarvisDispatchTests: XCTestCase {

    private let convID = UUID()

    private func turn(_ command: String,
                      mode: JarvisSpokenResponses) async -> (userMessage: ChatMessage, promptOverride: String?) {
        await JarvisSessionController.voiceTurn(
            command: command,
            conversationID: convID,
            mode: mode,
            fileProcessorService: FileProcessorService()
        )
    }

    // MARK: - The identity the id-based strip depends on

    /// ⚠️ THE LOAD-BEARING ASSERTION. The persisted/displayed row and the model's copy are ONE
    /// message with ONE id; only the text differs, and that difference travels separately.
    /// If this ever fails, the strip stops matching and every voice turn becomes an orphan again.
    func testTheDisplayedMessageAndTheModelsQueryAreOneMessage() async {
        let command = "summarise the release notes"
        let (userMessage, promptOverride) = await turn(command, mode: .automatic)

        XCTAssertEqual(userMessage.content.textContent, command,
                       "the row the user sees is exactly what they said — no hint, no decoration")
        XCTAssertNotNil(promptOverride, "a speaking mode must decorate the model's copy")
        XCTAssertNotEqual(promptOverride, command, "…and that copy must actually differ")
        XCTAssertTrue(promptOverride?.hasPrefix(command) ?? false,
                      "the user's own words survive verbatim at the front")
    }

    /// The strip removes the row whose ID matches, wherever it sits — so the row Jarvis PERSISTS
    /// must be findable by the id it hands to the send path. Run the real derivation and the real
    /// strip over the real turn, and assert the question comes back out.
    ///
    /// ⚠️ This test asserted `idForTheStrip == userMessage.id` after `let idForTheStrip =
    /// userMessage.id` until 2026-09-07 — a value compared to itself, which no mutation anywhere
    /// could fail. It named the right property and tested nothing.
    func testTheMessageHandedOverIsTheRowTheStripWillFind() async {
        let store = DispatchStubStore()
        let (userMessage, promptOverride) = await turn("check the build", mode: .automatic)
        // What the dispatch persists (JarvisSessionController.execute) is this same object.
        await store.addMessage(userMessage, toConversation: convID)

        let history = await ActiveStreamManager.deriveHistory(
            userMessage: userMessage, before: nil, persistence: store)

        XCTAssertEqual(history.filter { $0.id == userMessage.id }.count, 1,
                       "the persisted row and the handed-over row are ONE message, so the derived "
                       + "history contains it exactly once")

        // The model-facing query differs from that row's text; only the id can reach it.
        let stripped = BackendOrchestrationService.strippingCurrentQuery(
            from: history, userQuery: promptOverride ?? "", currentUserMessageID: userMessage.id)

        XCTAssertFalse(stripped.history.contains { $0.id == userMessage.id },
                       "the strip finds the question by the id Jarvis handed over…")
        XCTAssertEqual(stripped.history.count, history.count - 1, "…and removes only it")
        XCTAssertEqual(userMessage.sender, .user)
        XCTAssertEqual(userMessage.conversationId, convID,
                       "and it is filed against the conversation the turn belongs to")
    }

    /// End-to-end on the actual consequence: with the decorated text as `userQuery`, a TEXT strip
    /// misses and `pairTurns` reports the live question as abandoned; an ID strip does not.
    /// This is the defect reproduced and then closed, using the real formatter.
    func testTextComparisonMissesWhereIdentityMatches() async {
        let command = "summarise the release notes"
        let (userMessage, promptOverride) = await turn(command, mode: .automatic)
        let history = [userMessage]

        // The old rule: drop the last row when its text equals the model-facing query.
        let survivesTextStrip = history.last.map {
            ($0.content.textContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                != (promptOverride ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? false
        XCTAssertTrue(survivesTextStrip,
                      "text equality cannot match a decorated query against a clean message")

        // …and what the surviving row becomes, through the real formatter.
        let turns = EpisodicHistoryFormatter.pairTurns(from: history)
        XCTAssertEqual(turns.last?.terminalReason, "Agent never responded to this query",
                       "the un-stripped question is reported to the model as abandoned")

        // The current rule: drop by id. Nothing survives, so no orphan is produced.
        let afterIDStrip = history.filter { $0.id != userMessage.id }
        XCTAssertTrue(EpisodicHistoryFormatter.pairTurns(from: afterIDStrip).isEmpty,
                      "identity removes the row the text comparison could not reach")
    }

    // MARK: - The silent mode

    /// `.preferSilent` does not decorate, so there is no divergence to declare. `nil` says that in
    /// the type rather than passing a string identical to the message's own text.
    func testASilentTurnDeclaresNoOverride() async {
        let (userMessage, promptOverride) = await turn("run the tests", mode: .preferSilent)

        XCTAssertNil(promptOverride,
                     "no decoration means no override — a divergence exists in the type only when "
                     + "it exists in fact")
        XCTAssertEqual(userMessage.content.textContent, "run the tests")
    }

    /// Every speaking mode must decorate, and none may alter the persisted row. Loops the enum so
    /// a new mode cannot be added without deciding which side of this it falls on.
    func testEveryModeKeepsThePersistedRowCleanAndOnlyVariesTheOverride() async {
        for mode in JarvisSpokenResponses.allCases {
            let command = "open the log"
            let (userMessage, promptOverride) = await turn(command, mode: mode)

            XCTAssertEqual(userMessage.content.textContent, command,
                           "\(mode): the displayed row must never carry the hint")
            if mode.speaksAnswer {
                XCTAssertNotNil(promptOverride, "\(mode): a spoken answer needs the style hint")
                XCTAssertTrue(promptOverride?.hasPrefix(command) ?? false, "\(mode): command first")
            } else {
                XCTAssertNil(promptOverride, "\(mode): nothing is spoken, so nothing is decorated")
            }
        }
    }

    // MARK: - Attribution

    /// Voice traffic is attributed before it is persisted, so ChatOps mirroring, analytics and the
    /// audit trail can tell a spoken turn from a typed one.
    func testVoiceTrafficIsAttributedOnTheMessageItself() async {
        let (userMessage, _) = await turn("what changed in the build", mode: .automatic)
        XCTAssertEqual(userMessage.messageSource, .jarvis)
    }

    /// A voice turn carries no attachments — the file-processing dependency is required by the
    /// shared factory and never exercised on this path.
    func testAVoiceTurnCarriesNoAttachments() async {
        let (userMessage, _) = await turn("no files here", mode: .automatic)
        XCTAssertNil(userMessage.attachedTextFiles)
        XCTAssertNil(userMessage.attachedImageFiles)
    }

    // MARK: - Wiring

    /// ⚠️ The assertions above are worth nothing if `execute(_:)` stops using `voiceTurn` and goes
    /// back to building the two halves separately — which is exactly how they drifted apart in the
    /// first place. Source-scanned, in the `ToolRegistryDriftTests` idiom.
    func testTheDispatchBuildsBothHalvesTogether() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = repoRoot.appendingPathComponent("Devgentic/Jarvis/JarvisSessionController.swift")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("source not reachable — running outside a checkout")
        }
        let code = try String(contentsOf: source, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }

        XCTAssertTrue(code.contains { $0.contains("await Self.voiceTurn(") },
                      "the dispatch must build the persisted row and the model's copy together")
        XCTAssertTrue(code.contains { $0.contains("promptOverride: turn.promptOverride") },
                      "and hand over the override that voiceTurn paired with THAT message")
        XCTAssertFalse(code.contains { $0.contains("promptOverride: Self.decoratedQuery(") },
                       "decorating at the call site is what let the two halves drift — the "
                       + "persisted row and the model's copy must come from one place")

        // ⚠️ ONE OBJECT, PERSISTED AND SENT. `testTheMessageHandedOverIsTheRowTheStripWillFind`
        // proves the strip finds the row GIVEN that the persisted and sent rows are the same
        // message; nothing in a unit test can prove they ARE, because the persist happens in
        // `execute(_:)`, behind a `MainApplicationViewModel` whose init opens real ChatOps
        // connections. A call site that persisted a copy — or rebuilt the message for the send —
        // would restore the id mismatch that made every voice turn an orphan, and no unit test
        // in this file would fail. These three lines are what actually pin it.
        let body = code.joined(separator: "\n")
        XCTAssertTrue(body.contains("let userMessage = turn.userMessage"),
                      "the dispatch must bind the turn's own message…")
        XCTAssertTrue(body.contains("await persistence.addMessage(userMessage, toConversation: convID)"),
                      "…persist THAT binding…")
        XCTAssertTrue(body.contains("userMessage: userMessage,"),
                      "…and hand the SAME binding to the send path")
    }

    /// ⚠️ The session used to keep a `transcript: [ChatMessage]` holding every user AND agent
    /// message of a voice session — full streamed content and timeline events — after its only
    /// real consumer (`history: transcript` on the send call) was removed by the derive-don't-
    /// accept change. What survived was two `.count` reads in log lines, so the array was
    /// retaining a conversation to produce an Int, and the Int it produced was about DOUBLE the
    /// "turn(s)" those lines claimed (two appends per turn).
    ///
    /// Source-scanned: the retention is invisible to a unit test — it costs memory and reports a
    /// wrong number, neither of which an assertion on behaviour can see — and the array is exactly
    /// the kind of thing re-added on sight of a `.count` that needs a source.
    func testTheSessionKeepsATurnCountNotATranscript() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = repoRoot.appendingPathComponent("Devgentic/Jarvis/JarvisSessionController.swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "source not reachable at \(source.path) — running outside a checkout")
        let body = try String(contentsOf: source, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertFalse(body.contains("private var transcript: [ChatMessage]"),
                       "a session-scoped array of whole messages must not come back for a count")
        XCTAssertFalse(body.contains("transcript.append("),
                       "…and nothing may append messages to one")
        XCTAssertTrue(body.contains("private var spokenTurnCount: Int"),
                      "the signal the log lines need is a turn count")
        XCTAssertTrue(body.contains("spokenTurnCount += 1"),
                      "counted ONCE per turn, at the user's message — the agent's reply is the "
                      + "same turn, and counting it too is what doubled the reported number")
    }

    // MARK: - What the widening bought

    /// ⚠️ THIS TEST COULD NOT BE WRITTEN BEFORE 2026-09-07. `JarvisSessionController` reached
    /// `ChatPersistenceStore.shared` directly at three call sites, so constructing one in a test
    /// meant writing to the real SwiftData store — which is why nothing ever did, and why this
    /// surface shipped its send path with 269 tests around it and none through it.
    ///
    /// With the store injected as `ChatPersistenceProtocol` the controller can be built against a
    /// double. It does not prove the dispatch runs (that still needs a `MainApplicationViewModel`,
    /// whose init opens real ChatOps connections) — it proves the store dependency is no longer a
    /// wall, which is the precondition for ever testing the rest.
    func testTheControllerCanBeBuiltAgainstAStoreDouble() {
        let store = DispatchStubStore()
        let controller = JarvisSessionController(persistence: store)

        XCTAssertNotNil(controller)
        XCTAssertTrue(store.written.isEmpty, "construction alone must not write anything")
    }

    /// The default keeps the one production construction site
    /// (`JarvisPanelController.swift:128`) working unchanged — the widening is source-compatible.
    func testTheDefaultIsStillTheRealStore() {
        XCTAssertNotNil(JarvisSessionController(),
                        "the no-argument initializer must still exist for production")
    }
}


/// Records what a controller would persist, without a SwiftData container.
@MainActor
private final class DispatchStubStore: ChatPersistenceProtocol {
    private(set) var written: [ChatMessage] = []

    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {
        written.append(message)
    }

    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        written.filter { $0.conversationId == conversationId }
            .sorted { $0.timestamp > $1.timestamp }
    }

    func addConversation(from conversation: Conversation) {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {}
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

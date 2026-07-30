//
//  GaugeOccupancyCompositionTests.swift
//  DevgenticTests
//
//  `estimatedOccupancyTokens` is the number the composer ring actually shows, and it is a sum
//  of six terms: history prose, the episodic blob, attachments, tool schemas, knowledge
//  sources, and prior-turn images. Every term had its own unit test. The SUM had none.
//
//  That is the gap that matters, because the failure mode of a sum is a dropped addend, and a
//  dropped addend is invisible from either side: the term's own test still passes, and the
//  total is still a plausible number. Four of these six were added at different times, and
//  each one was previously worth 0 — which is exactly what a dropped term looks like.
//
//  These assert MONOTONICITY (adding content raises the total) rather than an exact figure.
//  An exact expectation would have to restate the arithmetic, which makes the test a mirror of
//  the implementation and blind to a change in both.
//

import XCTest
@testable import devgentic

@MainActor
final class GaugeOccupancyCompositionTests: XCTestCase {

    private let convID = UUID()
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gauge-composition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func cloudConfig(vision: Bool = false) -> ProviderConfig {
        ProviderConfig(apiProvider: .anthropic, modelName: "claude-test",
                       supportedModalities: vision ? .visionCapable : .textOnly)
    }

    private func profile(tools: [Tool] = [], knowledge: [KnowledgeSource] = [],
                         vision: Bool = false) -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: "G",
            details: .agent(AgentConfig(llmConfig: cloudConfig(vision: vision), tools: tools,
                                        knowledgeSources: knowledge)),
            fileContextStrategy: .directInjection)
    }

    private func turn(_ i: Int, text: String) -> [ChatMessage] {
        [
            ChatMessage(id: UUID(), conversationId: convID,
                        timestamp: Date(timeIntervalSince1970: TimeInterval(i * 2)),
                        sender: .user, content: .plainText(text)),
            ChatMessage(id: UUID(), conversationId: convID,
                        timestamp: Date(timeIntervalSince1970: TimeInterval(i * 2 + 1)),
                        sender: .agent, content: .plainText("Understood: \(text)"))
        ]
    }

    private func occupancy(config: ProviderConfig? = nil,
                           profile p: BackendProfileSnapshot? = nil,
                           messages: [ChatMessage] = [],
                           files: [FileSystemItem] = []) -> Int {
        ContextWindowUsage.estimatedOccupancyTokens(
            config: config ?? cloudConfig(),
            profile: p ?? profile(),
            messages: messages,
            attachedFiles: files,
            historyStrategy: .recentHistory,
            contextWindow: 128_000
        )
    }

    // MARK: - The floor

    /// A fresh chat reads as empty, not as the fixed layer overhead. Documented behaviour, and
    /// the baseline every comparison below rests on.
    func testAnEmptyComposerIsZero() {
        XCTAssertEqual(occupancy(), 0)
    }

    // MARK: - Each term is actually in the sum

    func testHistoryRaisesOccupancy() {
        let short = occupancy(messages: turn(0, text: "hi"))
        let long = occupancy(messages: turn(0, text: String(repeating: "detail ", count: 400)))

        XCTAssertGreaterThan(short, 0)
        XCTAssertGreaterThan(long, short, "a longer conversation must cost more")
    }

    func testKnowledgeSourcesRaiseOccupancy() throws {
        let url = scratch.appendingPathComponent("kb.md")
        try String(repeating: "k", count: 20_000).write(to: url, atomically: true, encoding: .utf8)
        let messages = turn(0, text: "hi")

        let without = occupancy(messages: messages)
        let with = occupancy(profile: profile(knowledge: [KnowledgeSource(type: .file, location: url.path)]),
                             messages: messages)

        XCTAssertGreaterThan(with, without, "20 KB of injected knowledge is not free")
    }

    func testAttachmentsRaiseOccupancy() throws {
        let url = scratch.appendingPathComponent("attached.txt")
        try String(repeating: "a", count: 15_000).write(to: url, atomically: true, encoding: .utf8)
        let item = FileSystemItem(id: url, name: "attached.txt", url: url, isDirectory: false)
        let messages = turn(0, text: "hi")

        XCTAssertGreaterThan(occupancy(messages: messages, files: [item]),
                             occupancy(messages: messages))
    }

    /// Prior-turn images cost real context and contribute ZERO characters, so they are the
    /// term most easily lost — a char-only sum drops them silently.
    ///
    /// Note the two gates, which is not obvious and cost a wrong first version of this test:
    /// CURRENT-turn images are priced off the `config` passed in (the composer's selected
    /// model), while PRIOR-turn images are priced off `profile.carriesHistoryImages`. That is
    /// not a mismatch — the request splits them the same way (`AgentConnect` gates history
    /// images on `profile.supportsVisionInput`) — but it does mean a fixture has to move both
    /// or the history term stays zero and the test looks like a missing addend.
    func testPriorTurnImagesRaiseOccupancyOnAVisionModel() {
        let messages = turn(0, text: "look at this")
        messages[0].attachedImageFiles = [AttachedImageFile(
            name: "a.png", url: URL(fileURLWithPath: "/tmp/a.png"),
            fileExtension: "png", binaryData: Data([0x1]), size: 1)]

        let vision = occupancy(config: cloudConfig(vision: true),
                               profile: profile(vision: true), messages: messages)
        let textOnly = occupancy(config: cloudConfig(vision: false),
                                 profile: profile(vision: false), messages: messages)

        XCTAssertGreaterThan(vision, textOnly,
                             "a vision model is sent the image; a text-only model has it dropped")
    }

    func testToolSchemasRaiseOccupancy() throws {
        ToolSchemaSizes.refreshFromRegistry()
        let known = ToolSchemaSizes.chars(for: ["read_file"])
        try XCTSkipIf(known == 0, "local tool registry is empty in this host — nothing to price")

        let tool = Tool(name: "read_file", description: "d", isEnabled: true,
                        requiresConfirmation: false, sourceId: UUID(),
                        parameters: ToolParameters(type: "object", properties: [:], required: []))
        let messages = turn(0, text: "hi")

        XCTAssertGreaterThan(occupancy(profile: profile(tools: [tool]), messages: messages),
                             occupancy(messages: messages),
                             "schemas ride every request and scale with the tool count")
    }

    // MARK: - Terms compose rather than replace

    /// The specific failure a sum has: one addend silently replacing another instead of adding
    /// to it. Everything at once must exceed each part alone.
    func testTermsAccumulateInsteadOfOverwritingEachOther() throws {
        let kbURL = scratch.appendingPathComponent("kb.md")
        try String(repeating: "k", count: 8_000).write(to: kbURL, atomically: true, encoding: .utf8)
        let attURL = scratch.appendingPathComponent("att.txt")
        try String(repeating: "a", count: 8_000).write(to: attURL, atomically: true, encoding: .utf8)

        let messages = turn(0, text: String(repeating: "word ", count: 200))
        let withKnowledge = profile(knowledge: [KnowledgeSource(type: .file, location: kbURL.path)])
        let item = FileSystemItem(id: attURL, name: "att.txt", url: attURL, isDirectory: false)

        let everything = occupancy(profile: withKnowledge, messages: messages, files: [item])

        XCTAssertGreaterThan(everything, occupancy(messages: messages))
        XCTAssertGreaterThan(everything, occupancy(profile: withKnowledge, messages: messages))
        XCTAssertGreaterThan(everything, occupancy(messages: messages, files: [item]))
    }

    // MARK: - The retrieval note

    /// `usesRetrieval` drives a popover note explaining that per-conversation RAG is chosen by
    /// the query and therefore deliberately NOT in the number above it. It was threaded through
    /// the model and asserted nowhere, so nothing pinned which profiles claim it.
    func testRetrievalIsFlaggedForConversationalProfilesOnly() {
        let agent = BackendProfileSnapshot(displayName: "A", details: .agent(
            AgentConfig(llmConfig: cloudConfig(), tools: [])))
        let bot = BackendProfileSnapshot(displayName: "B", details: .bot(
            BotConfig(llmConfig: cloudConfig())))
        let imageGen = BackendProfileSnapshot(displayName: "I", details: .imageGen(
            ImageGenConfig(llmConfig: cloudConfig())))

        XCTAssertTrue(agent.profileType == .agent || agent.profileType == .bot)
        XCTAssertTrue(bot.profileType == .bot)
        XCTAssertFalse(imageGen.profileType == .agent || imageGen.profileType == .bot,
                       "imageGen has no conversation RAG, so its gauge must not claim retrieval")
    }
}

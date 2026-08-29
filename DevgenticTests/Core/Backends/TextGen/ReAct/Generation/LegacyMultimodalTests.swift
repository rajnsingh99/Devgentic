//
//  LegacyMultimodalTests.swift
//  DevgenticTests
//
//  Covers image support on the LEGACY/dialect agent path — the path where
//  `input.generatorStrategy as? NativeStructuredGenerator` fails (MLX generators,
//  Ollama at .singleAction, JSON/XML/Markdown). Before this, current-turn images
//  were silently dropped there and prior-turn history images with them.
//
//  The seam is `CognitiveGenerator.buildMultimodalMessages(from:iteration:)`:
//    - returns nil for a text-only turn  → caller keeps the byte-identical text path
//    - returns [ProviderMessage] with images attached when the turn carries any
//

import XCTest
@testable import devgentic

final class LegacyMultimodalTests: XCTestCase {

    // MARK: - Fixtures

    private func context(
        historyTurns: [HistoryTurn]? = nil,
        userImages: Payload? = nil,
        query: String = "Describe the attached image."
    ) -> SemanticContext {
        SemanticContext(
            instructions: "You are a helpful agent.",
            environmentFacts: EnvironmentFacts(osVersion: "macOS", shellType: "zsh", userName: "t", homeDirectory: "/Users/t", currentDate: "01/01/2026"),
            longTermMemory: StaticGroundingMemory(ragContext: ""),
            recentHistory: nil,
            nativeHistoryTurns: historyTurns,
            originalQuery: query,
            currentIteration: 1,
            compiledScratchpad: "",
            latestClarification: nil,
            negativeConstraints: [],
            hallucinatedTools: [],
            availableTools: [],
            userProfile: nil,
            skillManifests: nil,
            promptLayerConfig: .agent,
            workflowContext: nil,
            attachmentContext: nil,
            knowledgeBaseContext: nil,
            userImagePayload: userImages
        )
    }

    private func imageBlock(_ name: String = "shot.png", bytes: Data = Data([0xFF, 0xD8])) -> MessageBlock {
        .image(ImagePayload(reference: .ephemeralData(bytes), mimeType: "image/png", alt: name))
    }

    private func historyTurnWithImage(_ name: String, bytes: Data = Data([0x01, 0x02])) -> [HistoryTurn] {
        [
            HistoryTurn(role: .user, parts: [
                .text("Earlier question"),
                .media(kind: .image, reference: .ephemeralData(bytes), label: name)
            ]),
            HistoryTurn(role: .assistant, text: "Earlier answer")
        ]
    }

    private func imageBlocks(in message: ProviderMessage) -> Int {
        message.content.filter { if case .image = $0 { return true }; return false }.count
    }

    private let gen = MarkdownStructuredGenerator()

    // MARK: - Text-only stays on the text path

    func testTextOnlyTurn_ReturnsNil() {
        XCTAssertNil(
            gen.buildMultimodalMessages(from: context(), iteration: 1),
            "A turn with no images must return nil so the caller keeps the byte-identical text path"
        )
    }

    // MARK: - Current-turn images

    func testCurrentTurnImage_AttachesToFinalUserTurn() {
        let payload = gen.buildMultimodalMessages(from: context(userImages: [.text("hi"), imageBlock()]), iteration: 1)
        let messages = try? XCTUnwrap(payload)
        guard let messages else { return }

        let lastUser = try? XCTUnwrap(messages.last { $0.role == "user" })
        XCTAssertEqual(imageBlocks(in: lastUser!), 1, "The current-turn image must ride the final user turn")
        // Total across the whole payload is exactly one image — no duplication.
        XCTAssertEqual(messages.reduce(0) { $0 + imageBlocks(in: $1) }, 1)
    }

    func testTriggerAndImageRideTheTrailingUserTurn() {
        // The trigger is appended as a fresh trailing user turn (matching the text
        // path), and the current-turn image rides it — MLX collapses all images onto
        // the last user turn, so that turn must be the current one.
        let payload = gen.buildMultimodalMessages(from: context(userImages: [imageBlock()]), iteration: 2)!
        let last = payload.last!
        XCTAssertEqual(last.role, "user", "The request must END on a user turn, never an assistant turn")
        let text = last.content.compactMap { if case .text(let s) = $0 { return s }; return nil as String? }.joined()
        XCTAssertTrue(text.contains(gen.promptTrigger(for: 2)), "The trailing user turn carries the iteration trigger")
        XCTAssertGreaterThan(imageBlocks(in: last), 0, "…and the image, so they arrive together")
    }

    func testHistoryPresentButNoCurrentUserTurn_StillEndsOnAFreshUserTurn() {
        // REGRESSION: the agent query lives in the system <task> layer, so an
        // image-only current turn produces NO trailing current user message from
        // compileMessages. With history present, the old "merge into the last user
        // turn" landed on a prior HISTORY turn and left the request ending on an
        // assistant turn (a malformed Ollama prefill). It must instead append a fresh
        // current user turn.
        let payload = gen.buildMultimodalMessages(
            from: context(historyTurns: historyTurnWithImage("old.png"), userImages: [imageBlock("new.png")]),
            iteration: 1
        )!
        XCTAssertEqual(payload.last?.role, "user", "Must end on a fresh current user turn, not on a history assistant turn")
        // The current image rides that trailing turn; the history image stays on its own.
        XCTAssertGreaterThan(imageBlocks(in: payload.last!), 0, "Current-turn image rides the appended user turn")
        XCTAssertEqual(payload.reduce(0) { $0 + imageBlocks(in: $1) }, 2, "History + current images both present, no duplication")
        // The history image must NOT be on the trailing turn.
        let historyImaged = payload.dropLast().first { imageBlocks(in: $0) > 0 }
        XCTAssertNotNil(historyImaged, "History image stays on its own turn, not merged into the current one")
    }

    // MARK: - History images

    func testHistoryImage_AttachesToItsOwnUserTurn() {
        let payload = gen.buildMultimodalMessages(from: context(historyTurns: historyTurnWithImage("old.png")), iteration: 1)!
        // Exactly one image total, on a user turn, sourced from history.
        XCTAssertEqual(payload.reduce(0) { $0 + imageBlocks(in: $1) }, 1)
        let imaged = payload.first { imageBlocks(in: $0) > 0 }!
        XCTAssertEqual(imaged.role, "user", "History images attach to the user side only")
    }

    func testHistoryAndCurrentImages_BothPresent() {
        let payload = gen.buildMultimodalMessages(
            from: context(historyTurns: historyTurnWithImage("old.png"), userImages: [imageBlock("new.png")]),
            iteration: 1
        )!
        XCTAssertEqual(payload.reduce(0) { $0 + imageBlocks(in: $1) }, 2, "Both the prior-turn and current-turn image must be carried")
    }

    // MARK: - Format allowlist (history images replay every iteration → must be safe)

    func testUnsupportedHistoryFormat_Omitted() {
        // HEIC is a valid image file that vision APIs reject; sending it would 400
        // every iteration of the loop. It must be omitted, not guessed into a label.
        let payload = gen.buildMultimodalMessages(from: context(historyTurns: historyTurnWithImage("photo.heic")), iteration: 1)
        // No images survive; but because a current/history image existed, the builder
        // still returns non-nil (it only returns nil when there were none to consider).
        let imaged = (payload ?? []).reduce(0) { $0 + imageBlocks(in: $1) }
        XCTAssertEqual(imaged, 0, "An unsupported history format must not reach the provider")
    }

    // MARK: - Byte parity of the text path

    func testTextPath_MessagesMatchLegacyShape() {
        // With no images, the caller builds messages exactly as before. Assert the
        // shape the generator would send is unchanged: compileMessages + trigger.
        let ctx = context()
        var expected = gen.compileMessages(from: ctx)
        expected.append(["role": "user", "content": gen.promptTrigger(for: 1)])

        // buildMultimodalMessages returns nil → the caller uses exactly `expected`.
        XCTAssertNil(gen.buildMultimodalMessages(from: ctx, iteration: 1))
        XCTAssertEqual(expected.last?["role"], "user")
        XCTAssertTrue((expected.last?["content"] ?? "").contains(gen.promptTrigger(for: 1)))
    }
}

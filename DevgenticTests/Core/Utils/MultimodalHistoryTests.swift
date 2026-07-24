//
//  MultimodalHistoryTests.swift
//  DevgenticTests
//
//  Covers the HistoryTurn refactor that made prior-turn images representable.
//
//  THE PIN THAT MATTERS: `testWireParity_TextOnlyHistory_MatchesLegacyShape`.
//  Every existing conversation is text-only, and the native path depends on a
//  byte-stable prompt prefix for KV-cache reuse. If lowering a text-only history
//  ever stops producing exactly `["role": …, "content": …]`, caches invalidate and
//  model behavior shifts app-wide with no other symptom.
//
//  NOTE ON "BYTE PARITY": the request body is built with `JSONSerialization` and no
//  `.sortedKeys`, so intra-object key ORDER is Swift hash order and already varies
//  across process launches. Byte-equality of the serialized request is therefore not
//  a property that can be asserted at all. The meaningful invariant — and what these
//  tests pin — is JSON-object equivalence: same message count, same order, same
//  role/content values.
//

import XCTest
@testable import devgentic

final class MultimodalHistoryTests: XCTestCase {

    // MARK: - Fixtures

    private let conversationID = UUID()

    private func userMessage(_ text: String, at seconds: TimeInterval, images: [AttachedImageFile] = []) -> ChatMessage {
        let message = ChatMessage(
            id: UUID(),
            conversationId: conversationID,
            timestamp: Date(timeIntervalSince1970: seconds),
            sender: .user,
            content: .plainText(text)
        )
        if !images.isEmpty { message.attachedImageFiles = images }
        return message
    }

    private func agentMessage(_ text: String, at seconds: TimeInterval) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            conversationId: conversationID,
            timestamp: Date(timeIntervalSince1970: seconds),
            sender: .agent,
            content: .plainText(text)
        )
    }

    private func image(named name: String, bytes: Data = Data([0xFF, 0xD8, 0xFF])) -> AttachedImageFile {
        AttachedImageFile(
            name: name,
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            fileExtension: (name as NSString).pathExtension,
            binaryData: bytes,
            size: Int64(bytes.count)
        )
    }

    /// The legacy converter's exact output shape, reproduced independently so the
    /// parity test compares against a fixed expectation rather than against the
    /// implementation it is meant to police.
    private func legacyWireShape(userText: String, assistantText: String) -> [[String: String]] {
        [
            ["role": "user", "content": userText],
            ["role": "assistant", "content": assistantText]
        ]
    }

    // MARK: - THE PARITY PIN

    func testWireParity_TextOnlyHistory_MatchesLegacyShape() {
        let history = [
            userMessage("What is Swift?", at: 100),
            agentMessage("A programming language.", at: 101)
        ]

        let wire = NativeHistoryConverter
            .buildNativeTurns(from: history, limit: 10, charBudget: 50_000)
            .asWireDicts()

        XCTAssertEqual(
            wire,
            legacyWireShape(userText: "What is Swift?", assistantText: "A programming language."),
            "Text-only history must lower to the exact legacy two-key shape — any drift silently invalidates every conversation's KV-cache prefix"
        )
        // Belt and braces: assert the KEY SET explicitly. A future `Part` case that
        // leaked an extra key would still satisfy a loose content comparison.
        for turn in wire {
            XCTAssertEqual(Set(turn.keys), ["role", "content"], "No key beyond role/content may reach the wire")
        }
    }

    func testWireParity_ImagesDoNotLeakIntoTextLowering() {
        let history = [
            userMessage("Look at this", at: 100, images: [image(named: "1.jpg")]),
            agentMessage("A screenshot.", at: 101)
        ]

        let turns = NativeHistoryConverter.buildNativeTurns(
            from: history, limit: 10, charBudget: 50_000, includeImages: true
        )

        XCTAssertEqual(turns[0].imageMedia.count, 1, "The image must be carried on the turn")
        XCTAssertEqual(
            turns.asWireDicts(),
            legacyWireShape(userText: "Look at this", assistantText: "A screenshot."),
            "Lowering to the text wire shape must drop media, not stringify it — the prompt-builder array cannot carry an image"
        )
    }

    // MARK: - Image attachment

    func testImagesAttachToTheCorrectUserTurn() {
        let history = [
            userMessage("First", at: 100, images: [image(named: "a.png")]),
            agentMessage("Reply one", at: 101),
            userMessage("Second", at: 102),
            agentMessage("Reply two", at: 103),
            userMessage("Third", at: 104, images: [image(named: "b.png"), image(named: "c.png")]),
            agentMessage("Reply three", at: 105)
        ]

        let turns = NativeHistoryConverter.buildNativeTurns(
            from: history, limit: 10, charBudget: 500_000, includeImages: true
        )

        XCTAssertEqual(turns.count, 6)
        XCTAssertEqual(turns[0].imageMedia.map(\.label), ["a.png"])
        XCTAssertEqual(turns[2].imageMedia.count, 0, "A turn with no attachment must carry no media")
        XCTAssertEqual(turns[4].imageMedia.map(\.label), ["b.png", "c.png"])
        for assistant in [turns[1], turns[3], turns[5]] {
            XCTAssertFalse(assistant.hasMedia, "Assistant turns never carry media")
        }
    }

    func testIncludeImagesFalse_OmitsMediaEntirely() {
        let history = [
            userMessage("Look", at: 100, images: [image(named: "a.png")]),
            agentMessage("OK", at: 101)
        ]

        let turns = NativeHistoryConverter.buildNativeTurns(
            from: history, limit: 10, charBudget: 50_000, includeImages: false
        )

        XCTAssertEqual(turns.totalImageCount, 0, "The vision gate must keep media out of the turns entirely")
    }

    // MARK: - Bytes-first resolution

    func testResolutionOrder_PrefersPersistedBytesOverDiskPath() async throws {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let history = [
            // The URL points at a path that does NOT exist — resolution must still
            // succeed, because the persisted blob is the durable source. This is the
            // post-relaunch case: we store raw URL strings, not security-scoped
            // bookmarks, so the path routinely goes stale while the bytes survive.
            userMessage("Look", at: 100, images: [
                AttachedImageFile(
                    name: "gone.png",
                    url: URL(fileURLWithPath: "/nonexistent/definitely/gone.png"),
                    fileExtension: "png",
                    binaryData: bytes,
                    size: Int64(bytes.count)
                )
            ]),
            agentMessage("OK", at: 101)
        ]

        let turns = NativeHistoryConverter.buildNativeTurns(
            from: history, limit: 10, charBudget: 50_000, includeImages: true
        )

        let reference = try XCTUnwrap(turns[0].imageMedia.first?.reference)
        let resolved = try await reference.resolve()
        XCTAssertEqual(resolved, bytes, "Persisted bytes must win over a stale disk path")
    }

    func testResolutionOrder_FallsBackToDiskPathWhenBytesEmpty() throws {
        let history = [
            userMessage("Look", at: 100, images: [image(named: "empty.png", bytes: Data())]),
            agentMessage("OK", at: 101)
        ]

        let turns = NativeHistoryConverter.buildNativeTurns(
            from: history, limit: 10, charBudget: 50_000, includeImages: true
        )

        let reference = try XCTUnwrap(turns[0].imageMedia.first?.reference)
        guard case .diskPath(let url) = reference else {
            return XCTFail("Expected a disk-path fallback when no bytes are persisted, got \(reference)")
        }
        XCTAssertEqual(url.lastPathComponent, "empty.png")
    }

    // MARK: - Budget

    func testImagesWeighAgainstTheCharBudget() {
        let withoutImage = [userMessage("Q", at: 100), agentMessage("A", at: 101)]
        let withImage = [
            userMessage("Q", at: 100, images: [image(named: "big.png")]),
            agentMessage("A", at: 101)
        ]

        // A budget that comfortably fits the text but not the text + one image.
        let budget = ImageTokenHeuristic.budgetCharsPerImage / 2

        let textOnly = NativeHistoryConverter.buildNativeTurns(
            from: withoutImage, limit: 10, charBudget: budget, includeImages: true
        )
        let imaged = NativeHistoryConverter.buildNativeTurns(
            from: withImage, limit: 10, charBudget: budget, includeImages: true
        )

        XCTAssertEqual(textOnly.count, 2, "Two short text turns fit the budget")
        XCTAssertEqual(imaged.count, 0, "An image must consume budget — otherwise image-heavy turns never trim while text turns starve")
    }

    func testImageBudgetWeight_IsFlatNotBase64Length() {
        // A 3 MB image and a 3-byte image must weigh the SAME. Weighing by byte
        // length is what let one screenshot evict an entire conversation.
        let tiny = [userMessage("Q", at: 100, images: [image(named: "t.png", bytes: Data([0x01]))]),
                    agentMessage("A", at: 101)]
        let huge = [userMessage("Q", at: 100, images: [image(named: "h.png", bytes: Data(count: 3_000_000))]),
                    agentMessage("A", at: 101)]

        let budget = ImageTokenHeuristic.budgetCharsPerImage * 4
        let tinyTurns = NativeHistoryConverter.buildNativeTurns(from: tiny, limit: 10, charBudget: budget, includeImages: true)
        let hugeTurns = NativeHistoryConverter.buildNativeTurns(from: huge, limit: 10, charBudget: budget, includeImages: true)

        XCTAssertEqual(tinyTurns.count, hugeTurns.count, "Image budget weight must not scale with file size")
        XCTAssertEqual(hugeTurns.count, 2, "A single image must not evict the turn that carries it")
    }

    func testBudgetTrimming_DropsOldestTurnsFirst() {
        var history: [ChatMessage] = []
        for i in 0..<6 {
            history.append(userMessage("Q\(i)", at: TimeInterval(i * 2)))
            history.append(agentMessage("A\(i)", at: TimeInterval(i * 2 + 1)))
        }
        // Each pair is 4 chars ("Q0" + "A0"); budget for ~3 pairs.
        let turns = NativeHistoryConverter.buildNativeTurns(from: history, limit: 10, charBudget: 12)

        XCTAssertEqual(turns.count, 6, "Budget should admit exactly three pairs")
        XCTAssertEqual(turns.first?.text, "Q3", "Oldest turns drop first; the newest survive")
        XCTAssertEqual(turns.last?.text, "A5")
    }

    // MARK: - Checkpoint interaction

    func testCheckpointExclusion_ImagesBehindCheckpointAreDropped() {
        let history: [ChatMessage] = [
            userMessage("Before", at: 100, images: [image(named: "old.png")]),
            agentMessage("Reply", at: 101),
            ChatMessage(id: UUID(), conversationId: conversationID,
                        timestamp: Date(timeIntervalSince1970: 102),
                        sender: .agent, content: .checkpoint(summary: "Summarized")),
            userMessage("After", at: 103, images: [image(named: "new.png")]),
            agentMessage("Reply2", at: 104)
        ]

        let turns = NativeHistoryConverter.buildNativeTurns(
            from: history, limit: 10, charBudget: 500_000, includeImages: true
        )

        let labels = turns.flatMap { $0.imageMedia.map(\.label) }
        XCTAssertEqual(labels, ["new.png"], "Images follow their turns: pre-checkpoint images are excluded with them")
    }

    // MARK: - Determinism

    func testSerializationIsDeterministicAcrossBuilds() {
        let history = [
            userMessage("Q", at: 100, images: [image(named: "a.png"), image(named: "b.png")]),
            agentMessage("A", at: 101)
        ]

        let first = NativeHistoryConverter.buildNativeTurns(from: history, limit: 10, charBudget: 500_000, includeImages: true)
        let second = NativeHistoryConverter.buildNativeTurns(from: history, limit: 10, charBudget: 500_000, includeImages: true)

        XCTAssertEqual(first, second, "Same input must produce identical turns — the KV-cache prefix depends on it")
        XCTAssertEqual(first[0].imageMedia.map(\.label), ["a.png", "b.png"], "Image order must follow attachment order")
    }

    // MARK: - Nil-vs-empty (isNativeFlow depends on this)

    func testEmptyHistoryYieldsEmptyArrayNotNil() {
        // `ChatExecutor` derives `isNativeFlow` from `nativeHistoryTurns != nil`, so
        // an empty-but-non-nil result must stay representable and distinct from nil.
        let turns = NativeHistoryConverter.buildNativeTurns(from: [], limit: 10, charBudget: 50_000)
        XCTAssertEqual(turns.count, 0)

        let input: [HistoryTurn]? = turns
        XCTAssertNotNil(input, "An empty history must remain non-nil — nil means 'non-native flow', not 'no turns'")
    }

    // MARK: - HistoryTurn projections

    func testTextProjectionJoinsOnlyTextParts() {
        let turn = HistoryTurn(role: .user, parts: [
            .text("hello"),
            .media(kind: .image, reference: .ephemeralData(Data([0x01])), label: "x.png")
        ])
        XCTAssertEqual(turn.text, "hello", "Media must not contribute to the text projection")
        XCTAssertEqual(turn.asWireDict(), ["role": "user", "content": "hello"])
    }
}

// MARK: - Image-aware turn accounting

final class ApproximateTurnCharsImageTests: XCTestCase {

    /// A base64 blob long enough that counting it literally would dwarf any budget.
    private var hugeBase64: String { String(repeating: "A", count: 1_000_000) }

    func testOllamaImagesChargeFlatWeight() {
        let turn: [String: Any] = ["role": "user", "content": "hi", "images": [hugeBase64]]
        let chars = approximateTurnChars(turn)
        XCTAssertLessThan(chars, ImageTokenHeuristic.budgetCharsPerImage * 2,
                          "A 1 MB base64 image must not be charged at its string length")
        XCTAssertGreaterThan(chars, ImageTokenHeuristic.budgetCharsPerImage / 2, "…but it must not be free either")
    }

    func testClaudeImageBlockChargesFlatWeight() {
        let turn: [String: Any] = [
            "role": "user",
            "content": [
                ["type": "text", "text": "hi"],
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": hugeBase64]]
            ]
        ]
        XCTAssertLessThan(approximateTurnChars(turn), ImageTokenHeuristic.budgetCharsPerImage * 2)
    }

    func testGeminiInlineDataChargesFlatWeight() {
        let turn: [String: Any] = [
            "role": "user",
            "parts": [["text": "hi"], ["inlineData": ["mimeType": "image/png", "data": hugeBase64]]]
        ]
        XCTAssertLessThan(approximateTurnChars(turn), ImageTokenHeuristic.budgetCharsPerImage * 2)
    }

    func testOpenAIDataURLChargesFlatWeight() {
        let turn: [String: Any] = [
            "role": "user",
            "content": [
                ["type": "text", "text": "hi"],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(hugeBase64)"]]
            ]
        ]
        XCTAssertLessThan(approximateTurnChars(turn), ImageTokenHeuristic.budgetCharsPerImage * 2)
    }

    func testMultipleImagesChargePerImage() {
        let one: [String: Any] = ["role": "user", "content": "x", "images": ["a"]]
        let three: [String: Any] = ["role": "user", "content": "x", "images": ["a", "b", "c"]]
        let delta = approximateTurnChars(three) - approximateTurnChars(one)
        XCTAssertEqual(delta, ImageTokenHeuristic.budgetCharsPerImage * 2, "Each additional image adds one flat weight")
    }

    func testTextOnlyTurnAccountingUnchanged() {
        // The pre-existing contract for text turns: sum of key lengths + value lengths.
        let turn: [String: Any] = ["role": "user", "content": "hello"]
        XCTAssertEqual(approximateTurnChars(turn), "role".count + "user".count + "content".count + "hello".count)
    }
}

// MARK: - Fit gauge

final class ImageTokenHeuristicTests: XCTestCase {

    func testUnknownDimensionsFallBackToFlatEstimate() {
        XCTAssertEqual(ImageTokenHeuristic.tokens(pixels: nil, provider: .anthropic),
                       ImageTokenHeuristic.defaultTokensPerImage)
        XCTAssertEqual(ImageTokenHeuristic.tokens(pixels: 0, provider: .openAI),
                       ImageTokenHeuristic.defaultTokensPerImage)
    }

    func testLocalProvidersUseFlatEstimateRegardlessOfSize() {
        XCTAssertEqual(ImageTokenHeuristic.tokens(pixels: 4_000_000, provider: .ollama),
                       ImageTokenHeuristic.defaultTokensPerImage)
        XCTAssertEqual(ImageTokenHeuristic.tokens(pixels: 4_000_000, provider: .mlx),
                       ImageTokenHeuristic.defaultTokensPerImage)
    }

    func testAnthropicScalesWithPixelsAndClamps() {
        // 1000×750 = 750_000 px → 1000 tokens.
        XCTAssertEqual(ImageTokenHeuristic.tokens(pixels: 750_000, provider: .anthropic), 1_000)
        // Absurd dimensions must clamp rather than poison a budget.
        XCTAssertEqual(ImageTokenHeuristic.tokens(pixels: 100_000_000, provider: .anthropic),
                       ImageTokenHeuristic.maxTokensPerImage)
    }

    func testTinyImageIsNeverFree() {
        XCTAssertGreaterThanOrEqual(ImageTokenHeuristic.tokens(pixels: 1, provider: .anthropic),
                                    ImageTokenHeuristic.minTokensPerImage)
    }

    // MARK: - Format allowlist (regression: unsupported formats poisoned conversations)

    func testUnsupportedFormatsAreRejectedNotGuessed() {
        // HEIC is the macOS default photo format and passes the app's image
        // classifier, but every vision API rejects it. Before the allowlist it was
        // labelled `image/heic` and re-sent on EVERY subsequent turn, 400-ing the
        // conversation permanently.
        XCTAssertNil(VisionImageFormat.mimeType(forExtension: "heic"))
        XCTAssertNil(VisionImageFormat.mimeType(forExtension: "heif"))
        XCTAssertNil(VisionImageFormat.mimeType(forExtension: "tiff"))
        XCTAssertNil(VisionImageFormat.mimeType(forExtension: "bmp"))
    }

    func testGifIsRejected_GeminiDoesNotAcceptIt() {
        // GIF is accepted by Anthropic/OpenAI but REJECTED by Gemini, so it is not in
        // the shared intersection. Sending image/gif on a history payload would 400 a
        // Gemini conversation permanently — the exact poison the allowlist prevents.
        XCTAssertNil(VisionImageFormat.mimeType(forExtension: "gif"))
        XCTAssertFalse(VisionImageFormat.supportedMimeTypes.contains("image/gif"))
    }

    func testSupportedFormatsMapToProviderAcceptedMimeTypes() {
        XCTAssertEqual(VisionImageFormat.mimeType(forExtension: "PNG"), "image/png")
        XCTAssertEqual(VisionImageFormat.mimeType(forExtension: "jpg"), "image/jpeg")
        XCTAssertEqual(VisionImageFormat.mimeType(forExtension: "jpeg"), "image/jpeg")
        XCTAssertEqual(VisionImageFormat.mimeType(forExtension: "webp"), "image/webp")
        // The shared set is the TRUE intersection: jpeg ∩ png ∩ webp.
        XCTAssertEqual(VisionImageFormat.supportedMimeTypes, ["image/jpeg", "image/png", "image/webp"])
    }

    func testExtensionlessNameIsRejectedRatherThanAssumedJPEG() {
        // Guessing JPEG for an unknown file produced "declared JPEG, actually PNG" 400s.
        XCTAssertNil(VisionImageFormat.mimeType(forName: "screenshot", fallbackURL: nil))
        XCTAssertEqual(
            VisionImageFormat.mimeType(forName: "screenshot", fallbackURL: URL(fileURLWithPath: "/tmp/a.png")),
            "image/png",
            "A nameless-extension case should still fall back to the URL"
        )
    }

    // MARK: - History-image gauge scoping

    func testHistoryImageTokens_BoundedByTheConverterWindow() {
        // 40 image-bearing messages, but only the most recent turns ever ship.
        let history = (0..<40).map { i in
            ChatMessage(id: UUID(), conversationId: UUID(),
                        timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                        sender: .user, content: .plainText("m\(i)"))
        }
        for message in history {
            message.attachedImageFiles = [AttachedImageFile(
                name: "x.png", url: URL(fileURLWithPath: "/tmp/x.png"),
                fileExtension: "png", binaryData: Data([0x1]), size: 1
            )]
        }

        let tokens = PromptFitCheck.estimatedHistoryImageTokens(in: history, provider: .anthropic)
        let unbounded = ImageTokenHeuristic.tokens(imageCount: 40, provider: .anthropic)

        XCTAssertLessThan(tokens, unbounded, "The gauge must not bill images the converter will never ship")
        XCTAssertEqual(
            tokens,
            ImageTokenHeuristic.tokens(imageCount: PromptFitCheck.historyImageLookback, provider: .anthropic),
            "Lookback should match the converter's default 10-pair window"
        )
    }

    func testHistoryImageTokens_ExcludesUnsupportedFormats() {
        // The history splice DROPS HEIC/TIFF/BMP/GIF, so the gauge must not charge for
        // them — otherwise a HEIC-heavy conversation posts an un-clearable overflow
        // banner for cost that never ships.
        func msg(_ ext: String) -> ChatMessage {
            let m = ChatMessage(id: UUID(), conversationId: UUID(),
                                timestamp: Date(timeIntervalSince1970: 1), sender: .user,
                                content: .plainText("x"))
            m.attachedImageFiles = [AttachedImageFile(name: "f.\(ext)", url: URL(fileURLWithPath: "/tmp/f.\(ext)"),
                                                      fileExtension: ext, binaryData: Data([0x1]), size: 1)]
            return m
        }
        let heicOnly = [msg("heic"), msg("heic")]
        XCTAssertEqual(PromptFitCheck.estimatedHistoryImageTokens(in: heicOnly, provider: .anthropic), 0,
                       "Unsupported-format history images must not be charged")
        let mixed = [msg("png"), msg("heic"), msg("gif")]
        XCTAssertEqual(
            PromptFitCheck.estimatedHistoryImageTokens(in: mixed, provider: .anthropic),
            ImageTokenHeuristic.tokens(imageCount: 1, provider: .anthropic),
            "Only the png ships; heic + gif are dropped by the allowlist and not counted"
        )
    }

    func testHistoryImageTokens_ZeroForPointerStrategy() {
        let history = [ChatMessage(id: UUID(), conversationId: UUID(),
                                   timestamp: Date(timeIntervalSince1970: 1), sender: .user,
                                   content: .plainText("x"))]
        history[0].attachedImageFiles = [AttachedImageFile(name: "a.png", url: URL(fileURLWithPath: "/tmp/a.png"),
                                                           fileExtension: "png", binaryData: Data([0x1]), size: 1)]
        // Pointer ships skeletons only — zero images — so the gauge must charge zero.
        XCTAssertEqual(PromptFitCheck.estimatedHistoryImageTokens(in: history, provider: .anthropic, shipsHistoryImages: false), 0)
        XCTAssertGreaterThan(PromptFitCheck.estimatedHistoryImageTokens(in: history, provider: .anthropic, shipsHistoryImages: true), 0)
    }

    func testZeroImagesCostNothing() {
        XCTAssertEqual(ImageTokenHeuristic.tokens(imageCount: 0), 0)
        XCTAssertEqual(ImageTokenHeuristic.budgetChars(imageCount: 0), 0)
    }

    func testBudgetCharsUsesTheBudgetRatioNotTheGaugeRatio() {
        // The char budgets this weight feeds (AgentConnect.charBudget,
        // nativeContextBudgetChars) are denominated at 4 chars/token. Pricing at
        // PromptFitCheck's 3.0 would under-reserve room for every image by 25%.
        XCTAssertEqual(
            ImageTokenHeuristic.budgetChars(imageCount: 1),
            Int(Double(ImageTokenHeuristic.defaultTokensPerImage) * 4.0)
        )
        XCTAssertNotEqual(
            ImageTokenHeuristic.budgetCharsPerToken,
            PromptFitCheck.charsPerToken,
            "These two ratios convert in opposite directions and must not be conflated"
        )
    }

    func testEstimatedTokensAddsImageTermWithoutDisturbingCharArithmetic() {
        let base = PromptFitCheck.estimatedTokens(
            attachmentChars: 30_000, knowledgeChars: 0, retrievalChars: 0,
            queryChars: 1_000, historyChars: 0
        )
        XCTAssertEqual(base, 11_000, "Existing char arithmetic must be untouched by the new term")

        let withImages = PromptFitCheck.estimatedTokens(
            attachmentChars: 30_000, knowledgeChars: 0, retrievalChars: 0,
            queryChars: 1_000, historyChars: 0, imageTokens: 1_500
        )
        XCTAssertEqual(withImages, 12_500, "Image tokens add directly — they are already tokens, not chars")
    }
}

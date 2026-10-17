// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ImageEditIntentTests.swift
//  devgenticTests
//
//  Readiness CR-13 — image generation decided "is this an edit?" by SUBSTRING and then a capability
//  GUESSED from the model's name refused it.
//
//  ⚠️ Two standing rules broken at once: capability metadata may LABEL, never GATE; and shape-matching
//  a payload ("ladder" contains "add") is the defect class this codebase keeps paying for.
//

import XCTest
@testable import devgentic

/// A provider whose behaviour is chosen per test, recording what it was asked to do.
private final class StubImageProvider: ImageGenProvider, @unchecked Sendable {
    let canEdit: Bool
    private(set) var calls: [String] = []
    init(canEdit: Bool) { self.canEdit = canEdit }

    private func artifact() -> MediaArtifact {
        MediaArtifact(kind: .image, reference: .ephemeralData(Data([1])), mimeType: "image/png")
    }
    func generateImage(prompt: String, negativePrompt: String?, options: ImageGenOptions, conversationID: UUID,
                       progressHandler: (@Sendable (Int, Int) -> Void)?) async throws -> MediaArtifact {
        calls.append("generate"); return artifact()
    }
    func generateImageVariation(prompt: String, negativePrompt: String?, inputImage: Data, options: ImageGenOptions,
                                conversationID: UUID, progressHandler: (@Sendable (Int, Int) -> Void)?) async throws -> MediaArtifact {
        calls.append("variation")
        guard canEdit else { throw ImageGenError.imageToImageNotSupported(modelName: "stub") }
        return artifact()
    }
}

final class ImageEditIntentTests: XCTestCase {

    // MARK: - Whole words, never substrings

    /// ⚠️⚠️ THE CR-13 MISCLASSIFICATION: each of these is a NEW image, and each contained an edit
    /// keyword as a substring ("ladder"→add, "timeless"→less, "fixed"→fix, "remorseful"→more).
    func testWordsThatMerelyContainAnEditKeywordAreNotEdits() {
        for prompt in ["a cat on a ladder", "a timeless portrait", "a colour-fixed print", "a remorseful knight",
                       "an addictive puzzle box", "a correctional facility at dusk"] {
            XCTAssertFalse(ImageIntentResolver.isEditRequest(prompt), "'\(prompt)' is a new image")
        }
    }

    /// The control: real edit wording is still recognised.
    func testRealEditWordingIsStillAnEdit() {
        for prompt in ["make it brighter", "add a hat", "remove the background", "more blue please",
                       "same but at night", "can you fix the hands"] {
            XCTAssertTrue(ImageIntentResolver.isEditRequest(prompt), "'\(prompt)' is an edit")
        }
    }

    // MARK: - No gate on a guessed capability

    private let profile = BackendProfileModel(
        displayName: "Images",
        details: .imageGen(ImageGenConfig(llmConfig: ProviderConfig(apiProvider: .google, modelName: "gemini-2.5-flash-image"))))

    /// The guessed label for this model says "no image-to-image" — the exact false refusal.
    private let labelSaysNoEdit = ImageModalitySupport(supportsTextToImage: true, supportsImageToImage: false,
                                                       maxResolution: nil, supportedAspectRatios: nil)

    private func run(_ intent: ImageIntent, provider: StubImageProvider) async -> [AgentStreamEvent] {
        var events: [AgentStreamEvent] = []
        let stream = ImageGenExecutor().execute(intent: intent, provider: provider, capability: labelSaysNoEdit,
                                                profile: profile, conversationID: UUID(),
                                                traceContext: TestTraceContext.make(), options: ImageGenOptions())
        do { for try await e in stream { events.append(e) } } catch {}
        return events
    }

    private func produced(_ events: [AgentStreamEvent]) -> Bool {
        events.contains { if case .artifactProduced = $0 { return true }; return false }
    }
    private func errored(_ events: [AgentStreamEvent]) -> Bool {
        events.contains { if case .error = $0 { return true }; return false }
    }

    /// ⚠️⚠️ THE CR-13 GATE: a model that CAN edit, labelled as unable, got an error card instead of
    /// an edit. The label must not decide — the provider must be asked.
    func testAGuessedLabelNeverRefusesAnEditTheProviderCanDo() async {
        let provider = StubImageProvider(canEdit: true)
        let events = await run(.imageToImage(prompt: "add a hat", sourceImage: Data([1]), inferred: false), provider: provider)
        XCTAssertEqual(provider.calls, ["variation"], "the provider was never asked — the guessed label refused it")
        XCTAssertTrue(produced(events))
        XCTAssertFalse(errored(events))
    }

    /// An INFERRED edit the provider genuinely cannot do becomes a new image, not an error card.
    func testAnInferredEditTheProviderCannotDoFallsBackToANewImage() async {
        let provider = StubImageProvider(canEdit: false)
        let events = await run(.imageToImage(prompt: "more blue", sourceImage: Data([1]), inferred: true), provider: provider)
        XCTAssertEqual(provider.calls, ["variation", "generate"])
        XCTAssertTrue(produced(events))
        XCTAssertFalse(errored(events))
    }

    /// The control: an ATTACHED image is the user's explicit ask, so the provider's real refusal is shown.
    func testAnExplicitEditTheProviderCannotDoIsReported() async {
        let provider = StubImageProvider(canEdit: false)
        let events = await run(.imageToImage(prompt: "add a hat", sourceImage: Data([1]), inferred: false), provider: provider)
        XCTAssertEqual(provider.calls, ["variation"], "an explicit edit must not silently become a different request")
        XCTAssertTrue(errored(events))
        XCTAssertFalse(produced(events))
    }
}

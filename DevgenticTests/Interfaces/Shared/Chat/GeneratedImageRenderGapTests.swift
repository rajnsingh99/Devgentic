// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GeneratedImageRenderGapTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class GeneratedImageRenderGapTests: XCTestCase {

    // MARK: - Fixtures

    /// An agent message mid-imageGen-run: empty streamed markdown, profile-tagged,
    /// with the `.thought` + completed `.mediaGeneration` events the run appends —
    /// mirroring ActiveStreamManager exactly (which does nothing else with the artifact).
    private func makeStreamedImageGenMessage(label: String) -> (ChatMessage, MediaArtifact) {
        let message = ChatMessage(
            conversationId: UUID(),
            sender: .agent,
            content: .markdownText(""),
            isStreaming: true
        )
        message.profileType = .imageGen
        message.appendTimelineEvent(.thought(id: UUID(), text: "Generating image with flux..."))

        let artifact = MediaArtifact(
            kind: .image,
            reference: .ephemeralData(Data([0xFF, 0xD8, 0xFF, 0xE0])), // JPEG magic
            mimeType: "image/jpeg",
            label: label
        )
        message.appendTimelineEvent(.mediaGeneration(
            id: UUID(),
            toolName: artifact.label ?? artifact.kind.rawValue,
            artifact: artifact,
            isComplete: true
        ))
        return (message, artifact)
    }

    /// Applies the REAL finalize content-selection (the same call
    /// `ActiveStreamManager.finalizeMessage` makes) and commits it to the message.
    private func finalize(_ message: ChatMessage) {
        let resolved = ChatMessage.resolveFinalizedContent(
            streamed: message.currentAgentContent,
            imageArtifact: message.lastCompletedImageArtifact
        )
        message.isStreaming = false
        message.content = resolved
        if let resp = message.agentResponse, resp.variants.indices.contains(resp.selectedVariantIndex) {
            message.agentResponse?.variants[resp.selectedVariantIndex].content = resolved
        }
    }

    /// Mirrors EXACTLY the one bubble surface that renders a generated image:
    /// `AgentBubbleContentView.contentView` `case .mediaArtifact` (kind `.image`) →
    /// `MediaArtifactImageView`, the sole instantiation in the app.
    private func renderedImage(in message: ChatMessage) -> MediaArtifact? {
        let displayed = message.currentAgentContent ?? message.content
        if case .mediaArtifact(let artifact) = displayed, artifact.kind == .image {
            return artifact
        }
        return nil
    }

    // MARK: - The fix: a completed image generation surfaces its image

    func test_completedImageGenRun_surfacesTheGeneratedImageAsContent() {
        let (message, artifact) = makeStreamedImageGenMessage(label: "A sunset over the sea")
        finalize(message)

        // Surfaced through the one renderable surface (.mediaArtifact → MediaArtifactImageView).
        XCTAssertEqual(
            renderedImage(in: message)?.id, artifact.id,
            "A completed image-generation run must surface its artifact as displayable content"
        )
        // ...and it's no longer the 'stopped' placeholder an empty-text run used to show.
        XCTAssertNil(message.currentAgentContent?.textContent, "An image message carries no text content")
    }

    // MARK: - No regressions in the other finalize branches

    func test_runThatStreamedText_keepsTheText_ratherThanPromotingAnArtifact() {
        let (message, _) = makeStreamedImageGenMessage(label: "unused")
        // A run that produced real prose keeps it — text wins over a stray artifact.
        // (Capture the index first: reading `agentResponse` inside the same statement
        // that mutates it would trip Swift's exclusive-access enforcement.)
        let idx = message.agentResponse?.selectedVariantIndex ?? 0
        message.agentResponse?.variants[idx].content = .markdownText("Here is your answer.")
        finalize(message)

        XCTAssertEqual(message.currentAgentContent?.textContent, "Here is your answer.")
        XCTAssertNil(renderedImage(in: message), "Text content must not be replaced by the image")
    }

    func test_emptyRunWithNoArtifact_stillShowsStoppedPlaceholder() {
        let message = ChatMessage(
            conversationId: UUID(),
            sender: .agent,
            content: .markdownText(""),
            isStreaming: true
        )
        finalize(message)

        XCTAssertEqual(
            message.currentAgentContent?.textContent,
            "*Operation was stopped before a response could be generated.*",
            "A cancelled/empty run with no artifact keeps the stopped placeholder (behavior preserved)"
        )
    }

    // MARK: - The timeline still cannot render the media event (why we route via content)

    func test_mediaGenerationEvent_fallsThroughToABareActionRow_whichActionDetailViewCannotRender() {
        let artifact = MediaArtifact(
            kind: .image,
            reference: .ephemeralData(Data([0xFF, 0xD8, 0xFF, 0xE0])),
            mimeType: "image/jpeg",
            label: "A sunset"
        )
        let events: [TimelineEvent] = [
            .mediaGeneration(id: UUID(), toolName: "flux", artifact: artifact, isComplete: true)
        ]

        let nodes = AgentTimelineView.buildGroupedNodes(from: events, isStreaming: false)

        // A lone media event becomes a bare `.action` node routed to ActionDetailView,
        // whose body is `if case .toolExecution` — so it draws nothing. This is WHY the
        // fix surfaces the image as message content instead of relying on the timeline.
        XCTAssertEqual(nodes.count, 1)
        guard case .action(let event) = nodes[0], case .mediaGeneration = event else {
            return XCTFail("Expected the media event to fall through to a bare .action row carrying a .mediaGeneration payload")
        }
    }
}

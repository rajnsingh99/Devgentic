// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ImageIntentResolver.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "ImageIntentResolver")

// MARK: - Image Intent

/// Represents the resolved user intent for image generation.
enum ImageIntent: Sendable {
    /// Generate a new image from a text description.
    case textToImage(prompt: String)
    /// Generates a variation of an existing image with a guiding prompt.
    /// - Parameter inferred: true when the edit was inferred from wording plus a recent image, none attached.
    ///   An inferred edit the model cannot perform falls back to a new image; an attached one reports its failure.
    case imageToImage(prompt: String, sourceImage: Data, inferred: Bool)
}

// MARK: - Image Intent Resolver

/// Resolves user intent for image generation by analyzing query text,
/// attached files, and chat history context.
enum ImageIntentResolver {

    /// Resolves the user's image generation intent.
    /// - Parameters: the typed query, any attached image files, and recent chat history for context.
    /// - Returns: the resolved `ImageIntent`.
    static func resolve(
        userQuery: String,
        attachedImages: [Data]?,
        chatHistory: [ChatMessage]
    ) async -> ImageIntent {

        // CONDITION A: User explicitly attached an image → Image-to-Image
        if let images = attachedImages, let firstImage = images.first {
            logger.info("Intent resolved: Image-to-Image (user attached image)")
            return .imageToImage(prompt: userQuery, sourceImage: firstImage, inferred: false)
        }

        // CONDITION B: Check if chat history has recent generated images
        // and user's query suggests a variation
        let recentArtifacts = extractRecentImageArtifacts(from: chatHistory)

        if !recentArtifacts.isEmpty && isEditRequest(userQuery) {
            // Try to resolve the source image from the most recent artifact
            if let lastArtifact = recentArtifacts.first,
               let imageData = try? await lastArtifact.reference.resolve() {
                logger.info("Intent resolved: Image-to-Image (variation of recent artifact)")
                return .imageToImage(prompt: userQuery, sourceImage: imageData, inferred: true)
            }
        }

        // CONDITION C: Default to Text-to-Image
        logger.info("Intent resolved: Text-to-Image")
        return .textToImage(prompt: userQuery)
    }

    // MARK: - Private Helpers

    /// Extracts recent `MediaArtifact` images from chat history (most recent first).
    private static func extractRecentImageArtifacts(from messages: [ChatMessage]) -> [MediaArtifact] {
        var artifacts: [MediaArtifact] = []

        // Look at the last 5 messages for generated images
        let recentMessages = messages.suffix(5)
        for message in recentMessages.reversed() {
            // Check the message content for media artifacts
            if case .mediaArtifact(let artifact) = message.content, artifact.kind == .image {
                artifacts.append(artifact)
            }
            // Also check timeline events for media generation
            for event in message.flattenedTimelineEvents {
                if case .mediaGeneration(_, _, let artifact, let isComplete) = event,
                   isComplete, let artifact = artifact, artifact.kind == .image {
                    artifacts.append(artifact)
                }
            }
        }

        return artifacts
    }

    // Why: substring matching read words like "ladder" or "timeless" as edits of the previous image.
    /// Whether the query asks to edit the last image rather than draw a new one.
    /// Matches whole words and phrases, never substrings.
    static func isEditRequest(_ query: String) -> Bool {
        let lowered = query.lowercased()
        return editPhrases.contains { phrase in
            lowered.range(of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b", options: .regularExpression) != nil
        }
    }

    private static let editPhrases: [String] = {
        let variationKeywords = [
            "make it", "change it", "modify", "adjust", "tweak",
            "more", "less", "brighter", "darker", "warmer", "cooler",
            "add", "remove", "replace", "edit", "refine",
            "variation", "variant", "similar", "like the last",
            "same but", "keep the", "update it", "redo",
            "improve", "enhance", "fix", "correct"
        ]
        return variationKeywords
    }()
}

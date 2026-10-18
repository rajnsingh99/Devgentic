// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PreSendFitHint.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Composer-side overflow hint: shows the advisory once attachments and profile imply the prompt will not fit.
/// Posts and clears the same `contextOverflow` advisory the send-time check refines, under the same dedupe key.
/// A heuristic (file sizes are stat'd, content unread, history excluded); the send-time check stays authoritative.
@MainActor
enum PreSendFitHint {

    // File kinds come from `AttachmentClassifier`, the owner the backend, transcript and attach-time intake also ask,
    // so the estimate agrees with what is actually sent.

    /// Re-evaluates the composer state and posts/clears the overflow advisory.
    /// Called on attachment and profile changes — human-speed events, no debounce.
    static func evaluate(
        attachedFiles: [FileSystemItem],
        typedText: String,
        profile: BackendProfileModel?,
        conversationID: UUID?
    ) {
        // New-chat edge: no conversation to key the advisory on yet — the
        // send-time check catches the first turn of a fresh chat.
        guard let conversationID else { return }
        // Code is included because large file attachments are most common there; Workflow / imageGen stay out, since
        // they have no single primary context window.
        guard let profile,
              profile.profileType == .bot || profile.profileType == .agent || profile.profileType == .code
        else { return }

        // `resolvedLLMConfig`, not `primaryLLMConfig`: the latter returns nil for `.code`. `primaryLLMConfig` is left alone
        // because it also backs `supportsVisionInput` and the orchestration path.
        let llmConfig = profile.resolvedLLMConfig
        // Resolved through the same call the ring uses so both composer surfaces agree on the denominator (including MLX
        // healing); the shared dedupe key ends in `|window`, so differing windows would leave two banners.
        let flavour: OllamaConfigDefaultProfile = .forProfileType(profile.profileType)
        let (window, trained) = llmConfig.map {
            ContextWindowUsage.windows(for: $0, profileID: profile.id, flavour: flavour)
        } ?? (EffectiveContextWindow.resolve(for: nil, flavour: flavour), nil)

        // Gated on vision so the composer never warns about images a non-vision model will have stripped; matches the
        // send-time gate. Read from `resolvedLLMConfig`, not `supportsVisionInput`, which is nil for `.code`.
        let supportsVision = llmConfig?.supportedModalities.contains(.visionInput) ?? false
        let imageTokens = supportsVision
            ? PromptFitCheck.estimatedImageTokens(forImageURLs: imageURLs(of: attachedFiles), provider: llmConfig?.apiProvider)
            : 0

        let estimated = PromptFitCheck.estimatedTokens(
            attachmentChars: PromptFitCheck.estimatedAttachmentChars(for: attachedFiles, profile: profile),
            knowledgeChars: 0,
            retrievalChars: 0,
            queryChars: typedText.count,
            historyChars: 0,
            imageTokens: imageTokens
        )

        guard PromptFitCheck.exceeds(estimatedTokens: estimated, windowTokens: window) else {
            // Composer state fits: self-heal. A history-driven overflow the send-time check posted may clear here too;
            // it re-posts with accurate numbers on the next send.
            AdvisoryCenter.shared.clear(category: .contextOverflow, conversationID: conversationID)
            return
        }

        // Condition-aware advice — same logic as the orchestrator's Section 5:
        // "raise num_ctx" only helps below the trained max.
        let canRaiseWindow = llmConfig?.apiProvider == .ollama && (trained ?? 0) > window
        let modelName = llmConfig?.modelName ?? String(localized: "this model")
        let message: String
        if canRaiseWindow {
            message = String(localized: "Attached content is ~\(PromptFitCheck.roundedK(estimated)) tokens but the context window is set to \(PromptFitCheck.roundedK(window)) — content will be cut off. \(modelName) supports up to \(PromptFitCheck.roundedK(trained ?? 0)): raise Context Window in the profile's Advanced settings.")
        } else {
            message = String(localized: "Attached content is ~\(PromptFitCheck.roundedK(estimated)) tokens but \(modelName)'s context window is \(PromptFitCheck.roundedK(window)) — the model will only see part of it. Use fewer or smaller files, or switch to a larger-context model.")
        }

        AdvisoryCenter.shared.post(Advisory(
            conversationID: conversationID,
            category: .contextOverflow,
            message: message,
            actionLabel: canRaiseWindow ? "Open Settings" : "Profile Settings",
            action: .openProfileSettings(profileID: profile.id),
            // Identical key shape to the orchestrator's Section 5 — its accurate
            // send-time post updates this banner in place.
            dedupeKey: "\(conversationID.uuidString)|contextOverflow|\(profile.id.uuidString)|\(window)"
        ))
    }

    /// Byte sizes of the attachments that will flow through text injection.
    /// Priced: `.text` and plain-text `.document`s (CSV, TSV, RTF); not priced: images, binary documents, binaries, folders.
    /// Stat for the size; classifying reads at most `BinaryFileProbe.probeLength` bytes of the head.
    static func estimatableSizes(of files: [FileSystemItem]) -> [Int] {
        files.compactMap { file in
            switch AttachmentClassifier.classify(file) {
            case .text:
                break
            case .document where !BinaryFileProbe.contentLooksBinary(file.url):
                break
            case .document, .image, .folder, .video, .binary:
                return nil
            }
            return (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }
    }

    /// The counterpart to `estimatableSizes`: the attachments it drops because they are priced in tokens, not characters.
    /// Every image is returned; `ImageTokenHeuristic` falls back to a flat per-image estimate if a read fails.
    static func imageURLs(of files: [FileSystemItem]) -> [URL] {
        files.compactMap { file in
            AttachmentClassifier.classify(file) == .image ? file.url : nil
        }
    }
}

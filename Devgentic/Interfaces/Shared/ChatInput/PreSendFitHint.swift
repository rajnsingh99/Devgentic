// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PreSendFitHint.swift
//  Devgentic
//
//  Created on 12/07/26.
//
//  COMPOSER-SIDE pre-send overflow hint: the moment attachments + the selected
//  profile imply the prompt won't fit, the advisory banner appears — BEFORE the
//  user spends a (30-second, on local models) turn on a doomed send.
//
//  Deliberately the same surface, not a new one: this posts/clears the SAME
//  contextOverflow advisory the orchestrator's send-time check (Section 5)
//  refines — identical dedupe key, so the accurate send-time numbers update the
//  banner in place with no flicker or duplicate. This estimate is a heuristic
//  (file sizes are stat'd, content unread; history not included); send-time
//  remains the authority.
//

import Foundation

@MainActor
enum PreSendFitHint {

    // ⚠️ File kinds come from `AttachmentClassifier` — the owner the backend, the transcript and
    // attach-time intake already ask. This file used to carry its own extension lists, and they
    // disagreed with the send: an `.svg` was priced as text here but shipped as an image, an
    // `.xls` was priced by its binary bytes, and an extension-less text file was missed by
    // the image check entirely.

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
        // Code is included deliberately: it's where large file attachments are MOST
        // common, and it was the one text profile getting no pre-send warning at all.
        // Workflow / imageGen stay out — they have no single primary context window.
        guard let profile,
              profile.profileType == .bot || profile.profileType == .agent || profile.profileType == .code
        else { return }

        // `resolvedLLMConfig` (not `primaryLLMConfig`) — the latter returns nil for
        // `.code`, so the estimate would have been computed against nothing. Left the
        // shared `primaryLLMConfig` alone on purpose: it also backs `supportsVisionInput`
        // and the orchestration path, so widening it would change Code-mode vision
        // behaviour as a side effect of adding a hint.
        let llmConfig = profile.resolvedLLMConfig
        // Resolved through the SAME call the ring uses, so both composer surfaces agree on the
        // denominator — including MLX healing, which only the ring used to run. An unhealed
        // MLX profile therefore read a real 32K in the ring and 8K here, and because the
        // shared dedupe key ends in `|window`, the send-time banner then stopped updating this
        // one in place: two banners, two numbers, neither replacing the other.
        let flavour: OllamaConfigDefaultProfile = .forProfileType(profile.profileType)
        let (window, trained) = llmConfig.map {
            ContextWindowUsage.windows(for: $0, profileID: profile.id, flavour: flavour)
        } ?? (EffectiveContextWindow.resolve(for: nil, flavour: flavour), nil)

        // Gated on vision so the composer never warns about images a non-vision model
        // will have stripped before they reach the wire. Matches the send-time gate, so
        // the two numbers agree and the shared-dedupeKey banner doesn't jump on send.
        // Vision is read off `resolvedLLMConfig`, NOT `profile.supportsVisionInput`:
        // the latter is built on `primaryLLMConfig`, which is nil for `.code`, so
        // using it would have made this term dead for exactly the profile type where
        // large attachments are most common — the same trap the window lookup above
        // already sidesteps.
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
            // Composer state fits — self-heal. (A history-driven overflow the
            // send-time check posted may clear here too; it re-posts, with
            // accurate numbers, on the next send.)
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

    /// Byte sizes of the attachments that will flow through TEXT injection. Stat for the size;
    /// classifying reads at most `BinaryFileProbe.probeLength` bytes of the head.
    ///
    /// Priced:
    ///  • `.text` — its bytes ARE what gets injected.
    ///  • a `.document` whose bytes are plain text (CSV, TSV, RTF) — a usable bound on what
    ///    extraction yields: under for CSV (cells gain ` | ` table padding), over for RTF
    ///    (markup). Either is capped at the per-file budget by the injection arithmetic.
    /// Not priced: images (in tokens, `imageURLs`); binary documents (PDF, DOCX, XLSX — their
    /// bytes overstate the extracted text by orders of magnitude; send-time measures the
    /// truth); binaries, videos and folders, which deliver no content.
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

    /// The counterpart to `estimatableSizes`: the attachments it deliberately drops
    /// because they are priced in tokens, not characters. Every image is returned —
    /// unlike the size lookup above, nothing is silently skipped on a read failure,
    /// because `ImageTokenHeuristic` falls back to a flat per-image estimate.
    static func imageURLs(of files: [FileSystemItem]) -> [URL] {
        files.compactMap { file in
            AttachmentClassifier.classify(file) == .image ? file.url : nil
        }
    }
}

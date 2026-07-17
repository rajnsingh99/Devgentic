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

    /// Binary containers whose on-disk size wildly overstates extracted text
    /// (a PDF's bytes ≫ its text) — skipped here; send-time measures the truth.
    static let binaryContainerExtensions: Set<String> = [
        "pdf", "doc", "docx", "rtf", "rtfd", "pptx", "xlsx", "pages", "key", "numbers"
    ]

    /// Images ride the native vision payload, never the text-injection path.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp"
    ]

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
        guard let profile,
              profile.profileType == .bot || profile.profileType == .agent else { return }

        let llmConfig = profile.primaryLLMConfig
        let window = EffectiveContextWindow.resolve(for: llmConfig)
        let trained = EffectiveContextWindow.trainedWindow(for: llmConfig)

        let estimated = PromptFitCheck.estimatedTokens(
            attachmentChars: PromptFitCheck.estimatedAttachmentChars(forFileSizes: estimatableSizes(of: attachedFiles)),
            knowledgeChars: 0,
            retrievalChars: 0,
            queryChars: typedText.count,
            historyChars: 0
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
        let modelName = llmConfig?.modelName ?? "this model"
        let message: String
        if canRaiseWindow {
            message = "Attached content is ~\(PromptFitCheck.roundedK(estimated)) tokens but the context window is set to \(PromptFitCheck.roundedK(window)) — content will be cut off. \(modelName) supports up to \(PromptFitCheck.roundedK(trained ?? 0)): raise Context Window in the profile's Advanced settings."
        } else {
            message = "Attached content is ~\(PromptFitCheck.roundedK(estimated)) tokens but \(modelName)'s context window is \(PromptFitCheck.roundedK(window)) — the model will only see part of it. Use fewer or smaller files, or switch to a larger-context model."
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

    /// Byte sizes of the attachments that will flow through TEXT injection —
    /// images and binary containers excluded. Stat only; no content is read.
    static func estimatableSizes(of files: [FileSystemItem]) -> [Int] {
        files.compactMap { file in
            let ext = file.url.pathExtension.lowercased()
            guard !imageExtensions.contains(ext), !binaryContainerExtensions.contains(ext) else { return nil }
            return (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }
    }
}

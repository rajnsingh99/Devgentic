// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MessageStreamStarting.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Starting and cancelling one run, as seen by the surface that owns it.
@MainActor
protocol MessageStreamStarting: AnyObject {

    /// Starts a run and returns the assistant message it will stream into. There is no `history` parameter: the manager
    /// derives the model-facing history from its own state. `promptOverride` is model-facing text that differs from what
    /// was persisted; `updating` streams into an existing message (regenerate/resume).
    @discardableResult
    func startMessageStream(
        withConfig config: BackendRequestConfig,
        userMessage: ChatMessage,
        promptOverride: String?,
        files: [FileSystemItem],
        updating existingMessage: ChatMessage?,
        workflowExecutionState: WorkflowExecutionState?,
        resumeState: TimelineReconstruction?,
        onComplete: @escaping () -> Void
    ) -> ChatMessage

    /// Cancels the run streaming into `messageId`.
    func cancelStream(for messageId: UUID)
}

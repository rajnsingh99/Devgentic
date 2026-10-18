// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PromptEditViewModel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Edit-buffer view model for create/edit forms.
/// Each edit surface owns its own instance so drafts never leak between contexts.
@Observable @MainActor
final class PromptEditViewModel {

    // MARK: - Dependencies
    @ObservationIgnored private let service = PromptService.shared
    @ObservationIgnored private let logger = DGLogger(category: "PromptEditViewModel")

    // MARK: - Buffer
    /// The original prompt being edited. `nil` means we're creating.
    var originalPrompt: DevPrompt?

    var title: String = ""
    var text: String = ""
    var category: PromptCategory = .general
    var tagsString: String = ""
    var isPinned: Bool = false

    // MARK: - Derived

    var isCreating: Bool { originalPrompt == nil }

    /// Save is allowed once title and text both have non-whitespace content.
    var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the buffer differs from the original prompt. New prompts are
    /// "dirty" as soon as the user types anything.
    var isDirty: Bool {
        guard let original = originalPrompt else {
            return !title.isEmpty || !text.isEmpty || !tagsString.isEmpty
        }
        let originalTagsString = original.tags?.joined(separator: ", ") ?? ""
        return title != original.title
            || text != original.text
            || category.rawValue != original.category
            || tagsString != originalTagsString
            || isPinned != original.isPinned
    }

    // MARK: - Setup

    func loadCreateDraft() {
        originalPrompt = nil
        title = ""
        text = ""
        category = .general
        tagsString = ""
        isPinned = false
        logger.info("Prepared new-prompt draft.")
    }

    func loadDraft(from prompt: DevPrompt) {
        originalPrompt = prompt
        title = prompt.title
        text = prompt.text
        category = prompt.categoryEnum
        tagsString = prompt.tags?.joined(separator: ", ") ?? ""
        isPinned = prompt.isPinned
        logger.info("Loaded draft for prompt '\(prompt.title)' (ID: \(prompt.id.uuidString)).")
    }

    // MARK: - Persist

    /// Commits the buffer via the service, returning the saved prompt or `nil` on failure.
    /// On success `originalPrompt` updates so `isDirty` returns to `false`.
    @discardableResult
    func save() -> DevPrompt? {
        let tags = parsedTags()
        if let original = originalPrompt {
            var updated = original
            updated.title = title
            updated.text = text
            updated.category = category.rawValue
            updated.tags = tags.isEmpty ? nil : tags
            updated.isPinned = isPinned
            guard service.updatePrompt(updated) else { return nil }
            originalPrompt = updated
            return updated
        } else {
            let new = DevPrompt(
                title: title,
                text: text,
                category: category.rawValue,
                isUserDefined: true,
                tags: tags.isEmpty ? nil : tags,
                isPinned: isPinned
            )
            guard service.addPrompt(new) else { return nil }
            originalPrompt = new
            return new
        }
    }

    /// Deletes the prompt currently loaded in the buffer (no-op when creating).
    @discardableResult
    func deleteLoadedPrompt() -> Bool {
        guard let id = originalPrompt?.id else { return false }
        let ok = service.deletePrompt(withId: id)
        if ok { originalPrompt = nil }
        return ok
    }

    // MARK: - Helpers

    private func parsedTags() -> [String] {
        tagsString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

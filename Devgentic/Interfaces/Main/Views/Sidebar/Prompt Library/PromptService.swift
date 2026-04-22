//
//  PromptService.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import Foundation
import os

/// Observable load state for the prompt library. Lets the UI distinguish
/// "still fetching," "loaded but empty," and "fetch failed" — previously
/// all three looked identical.
enum PromptLoadState: Equatable {
    case idle
    case loading
    case loaded
    case error(String)

    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

/// Manages the collection of prompts, handling persistence and providing access.
///
/// Mutation methods return `Bool` indicating whether the change succeeded.
/// Failures surface via `loadState = .error(_)` so any observer (sidebar,
/// detail editor, chat input) can reflect the problem.
@MainActor
@Observable
class PromptService {
    static let shared = PromptService()

    private let promptStore: PromptStoreProtocol
    @ObservationIgnored private let logger = DGLogger(category: "PromptService")

    /// The collection of all prompts, published for UI updates.
    var prompts: [DevPrompt] = []

    /// Current load/error state. Consumers should react to `.error` by
    /// surfacing a banner or toast; it clears automatically on next
    /// successful load.
    var loadState: PromptLoadState = .idle

    private init(promptStore: PromptStoreProtocol = PromptStore.shared) {
        self.promptStore = promptStore

        // Load all prompts from the store.
        loadPrompts()

        // If still empty (first launch), seed defaults.
        if prompts.isEmpty && !loadState.isError {
            logger.info("Prompt library is empty. Adding default example prompts.")
            addDefaultPrompts()
        }

        logger.info("PromptService initialized. Loaded \(self.prompts.count) prompts.")
    }

    // MARK: - Loading

    /// Reloads the full prompt list from persistence. Exposed for the rare
    /// case where an external actor has written to the DB; callers should
    /// prefer the granular helpers which update in-memory state directly.
    func reload() {
        loadPrompts()
    }

    private func loadPrompts() {
        loadState = .loading
        switch promptStore.fetchPrompts() {
        case .success(let loaded):
            self.prompts = loaded.sorted(by: { $0.createdAt > $1.createdAt })
            loadState = .loaded
        case .failure(let error):
            logger.error("Prompt fetch failed: \(error.localizedDescription)")
            loadState = .error(error.localizedDescription ?? "Unknown error")
        }
    }

    private func addDefaultPrompts() {
        for prompt in DevPrompt.examplePrompts {
            _ = promptStore.addPrompt(from: prompt)
        }
        loadPrompts()
    }

    // MARK: - CRUD (granular — mutates in-memory state, no full reload)

    /// Adds a new prompt. Returns `true` on success.
    @discardableResult
    func addPrompt(_ prompt: DevPrompt) -> Bool {
        switch promptStore.addPrompt(from: prompt) {
        case .success:
            prompts.insert(prompt, at: 0)
            logger.info("Added new prompt: '\(prompt.title)'")
            loadState = .loaded
            return true
        case .failure(let error):
            loadState = .error(error.localizedDescription ?? "Unknown error")
            return false
        }
    }

    /// Updates an existing prompt. Returns `true` on success.
    @discardableResult
    func updatePrompt(_ prompt: DevPrompt) -> Bool {
        switch promptStore.updatePrompt(from: prompt) {
        case .success:
            if let idx = prompts.firstIndex(where: { $0.id == prompt.id }) {
                prompts[idx] = prompt
            } else {
                prompts.insert(prompt, at: 0)
            }
            logger.info("Updated prompt: '\(prompt.title)'")
            loadState = .loaded
            return true
        case .failure(let error):
            loadState = .error(error.localizedDescription ?? "Unknown error")
            return false
        }
    }

    /// Deletes a prompt by ID. Returns `true` on success.
    ///
    /// Built-in prompts (`isUserDefined == false`) are refused and return
    /// `false` without touching persistence — they're seeded defaults that
    /// should remain available across fresh installs. Hide the filter with
    /// `PromptSourceFilter.user` if a user never wants to see them.
    @discardableResult
    func deletePrompt(withId id: UUID) -> Bool {
        if let existing = prompts.first(where: { $0.id == id }), !existing.isUserDefined {
            logger.warning("Refused to delete built-in prompt '\(existing.title)' (ID: \(id.uuidString))")
            return false
        }
        switch promptStore.deletePrompt(withId: id) {
        case .success:
            prompts.removeAll { $0.id == id }
            logger.info("Deleted prompt with ID: \(id.uuidString)")
            loadState = .loaded
            return true
        case .failure(let error):
            loadState = .error(error.localizedDescription ?? "Unknown error")
            return false
        }
    }

    /// Deletes multiple prompts. Returns the count that succeeded.
    ///
    /// Silently filters out built-in prompts — they can't be deleted (see
    /// `deletePrompt(withId:)`). Callers that care about the skip count can
    /// compare against the input set size.
    @discardableResult
    func deletePrompts(withIds ids: Set<UUID>) -> Int {
        guard !ids.isEmpty else { return 0 }
        let deletableIDs = ids.filter { id in
            guard let prompt = prompts.first(where: { $0.id == id }) else { return false }
            return prompt.isUserDefined
        }
        let skipped = ids.count - deletableIDs.count
        if skipped > 0 {
            logger.info("Skipped \(skipped) built-in prompt(s) from batch delete.")
        }
        var ok = 0
        for id in deletableIDs {
            if case .success = promptStore.deletePrompt(withId: id) {
                ok += 1
            }
        }
        prompts.removeAll { deletableIDs.contains($0.id) }
        logger.info("Deleted \(ok)/\(deletableIDs.count) prompts.")
        loadState = .loaded
        return ok
    }

    // MARK: - Pinning

    /// Toggles a prompt's pinned state. Convenience wrapper over `updatePrompt`.
    @discardableResult
    func togglePin(_ prompt: DevPrompt) -> Bool {
        var copy = prompt
        copy.isPinned.toggle()
        return updatePrompt(copy)
    }

    // MARK: - Usage tracking

    /// Updates `lastUsedAt` to now. Called by the chat insertion path so
    /// "Recently Used" sort reflects real usage.
    func recordUsage(of prompt: DevPrompt) {
        var copy = prompt
        copy.lastUsedAt = Date()
        _ = updatePrompt(copy)
    }

    // MARK: - Global tag management

    /// Renames a tag everywhere it appears. Returns the number of prompts
    /// that were touched. Deduplicates within each prompt so renaming
    /// "dev" → "development" on a prompt tagged `["dev", "development"]`
    /// collapses to `["development"]`.
    @discardableResult
    func renameTag(_ oldTag: String, to newTag: String) -> Int {
        let oldTrimmed = oldTag.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTrimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldTrimmed.isEmpty, !newTrimmed.isEmpty, oldTrimmed != newTrimmed else { return 0 }

        var updatedCount = 0
        let snapshot = prompts  // copy — updatePrompt mutates the array
        for var prompt in snapshot {
            guard let existing = prompt.tags, existing.contains(oldTrimmed) else { continue }
            var seen: Set<String> = []
            let rewritten = existing
                .map { $0 == oldTrimmed ? newTrimmed : $0 }
                .filter { seen.insert($0).inserted }
            prompt.tags = rewritten.isEmpty ? nil : rewritten
            if updatePrompt(prompt) { updatedCount += 1 }
        }
        logger.info("Renamed tag '\(oldTrimmed)' → '\(newTrimmed)' on \(updatedCount) prompts.")
        return updatedCount
    }

    /// Removes a tag from every prompt that has it. Returns the number of
    /// prompts that were touched.
    @discardableResult
    func deleteTag(_ tag: String) -> Int {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        var updatedCount = 0
        let snapshot = prompts
        for var prompt in snapshot {
            guard let existing = prompt.tags, existing.contains(trimmed) else { continue }
            let filtered = existing.filter { $0 != trimmed }
            prompt.tags = filtered.isEmpty ? nil : filtered
            if updatePrompt(prompt) { updatedCount += 1 }
        }
        logger.info("Deleted tag '\(trimmed)' from \(updatedCount) prompts.")
        return updatedCount
    }

    /// Returns every tag in use across the library with its usage count,
    /// sorted alphabetically. Used by the tag-management sheet.
    func tagUsageCounts() -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for prompt in prompts {
            for tag in prompt.tags ?? [] {
                counts[tag, default: 0] += 1
            }
        }
        return counts
            .map { (tag: $0.key, count: $0.value) }
            .sorted { $0.tag.lowercased() < $1.tag.lowercased() }
    }

    // MARK: - Lookup

    func getPrompt(withId id: UUID) -> DevPrompt? {
        prompts.first { $0.id == id }
    }

    func getAllPrompts() -> [DevPrompt] {
        prompts
    }
}

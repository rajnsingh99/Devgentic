//
//  PromptBrowseViewModel.swift
//  Devgentic
//
//  Browse-state for the sidebar: search, category chip, sort, selection.
//  Split from the old PromptLibraryViewModel (2026-04-21) — the edit buffer
//  fields moved to PromptEditViewModel so the two concerns no longer share
//  an instance. Sidebar filter state persists across tab switches via
//  DestinationCoordinator; edit state is per-edit-session.
//

import Foundation
import os

/// How the sidebar list is ordered.
enum PromptSortOrder: String, CaseIterable, Identifiable {
    case alphabetical    = "Alphabetical"
    case recentlyUsed    = "Recently Used"
    case recentlyCreated = "Recently Created"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .alphabetical:    return "textformat.abc"
        case .recentlyUsed:    return "clock.arrow.circlepath"
        case .recentlyCreated: return "calendar.badge.plus"
        }
    }
}

@Observable @MainActor
final class PromptBrowseViewModel {

    // MARK: - Dependencies
    @ObservationIgnored private let service = PromptService.shared
    @ObservationIgnored private let logger = DGLogger(category: "PromptBrowseViewModel")
    @ObservationIgnored private let defaults = UserDefaults.standard

    // Persistence keys — deliberately namespaced so they don't collide with
    // any other sidebar that might want its own filter state later.
    @ObservationIgnored private static let categoryKey = "promptBrowse.selectedCategory"
    @ObservationIgnored private static let sortKey = "promptBrowse.sortOrder"
    @ObservationIgnored private static let tagKey = "promptBrowse.selectedTag"
    @ObservationIgnored private static let sourceKey = "promptBrowse.selectedSource"

    // MARK: - Filter state (stored)
    //
    // Sort / category / tag filters persist across launches via UserDefaults.
    // `searchText` is *not* persisted — a stale search from last session would
    // hide most of the library on relaunch, which is a worse default than
    // starting fresh. DestinationCoordinator keeps it alive within a session.

    var searchText: String = ""

    var selectedCategory: PromptCategoryFilter = .all {
        didSet { defaults.set(selectedCategory.rawValue, forKey: Self.categoryKey) }
    }

    var sortOrder: PromptSortOrder = .alphabetical {
        didSet { defaults.set(sortOrder.rawValue, forKey: Self.sortKey) }
    }

    /// Optional tag filter applied on top of category/search. `nil` means "any".
    var selectedTag: String? = nil {
        didSet {
            if let tag = selectedTag, !tag.isEmpty {
                defaults.set(tag, forKey: Self.tagKey)
            } else {
                defaults.removeObject(forKey: Self.tagKey)
            }
        }
    }

    /// Filters by authorship (All / User / Built-in).
    var selectedSource: PromptSourceFilter = .all {
        didSet { defaults.set(selectedSource.rawValue, forKey: Self.sourceKey) }
    }

    // MARK: - Derived (computed so changes to `service.prompts` flow through
    //         the observation graph without needing manual refresh calls).

    var filteredPrompts: [DevPrompt] {
        let all = service.prompts
        let sourceScoped = all.filter { selectedSource.matches($0) }
        let categoryScoped = sourceScoped.filter { selectedCategory.matches($0) }

        let searchScoped: [DevPrompt]
        if searchText.isEmpty {
            searchScoped = categoryScoped
        } else {
            let needle = searchText.lowercased()
            searchScoped = categoryScoped.filter { prompt in
                prompt.title.lowercased().contains(needle)
                    || prompt.text.lowercased().contains(needle)
                    || (prompt.tags?.contains(where: { $0.lowercased().contains(needle) }) ?? false)
            }
        }

        let tagScoped: [DevPrompt]
        if let tag = selectedTag {
            tagScoped = searchScoped.filter { $0.tags?.contains(tag) ?? false }
        } else {
            tagScoped = searchScoped
        }

        return sort(tagScoped)
    }

    var pinnedPrompts: [DevPrompt] { filteredPrompts.filter { $0.isPinned } }
    var unpinnedPrompts: [DevPrompt] { filteredPrompts.filter { !$0.isPinned } }

    /// All tag strings currently in use across the library (sorted, deduped).
    var availableTags: [String] {
        let tags = service.prompts.flatMap { $0.tags ?? [] }
        return Array(Set(tags)).sorted { $0.lowercased() < $1.lowercased() }
    }

    var loadState: PromptLoadState { service.loadState }

    // MARK: - Init
    init() {
        // Restore persisted filters. Assignments here bypass the `didSet`
        // hooks (Swift semantics — stored properties set during init don't
        // trigger observers), which is exactly what we want: no redundant
        // write-back of the value we just read.
        if let raw = defaults.string(forKey: Self.categoryKey),
           let filter = PromptCategoryFilter(rawValue: raw) {
            selectedCategory = filter
        }
        if let raw = defaults.string(forKey: Self.sortKey),
           let sort = PromptSortOrder(rawValue: raw) {
            sortOrder = sort
        }
        if let tag = defaults.string(forKey: Self.tagKey), !tag.isEmpty {
            selectedTag = tag
        }
        if let raw = defaults.string(forKey: Self.sourceKey),
           let source = PromptSourceFilter(rawValue: raw) {
            selectedSource = source
        }
        logger.info("PromptBrowseViewModel initialized. sort=\(self.sortOrder.rawValue) category=\(self.selectedCategory.rawValue) tag=\(self.selectedTag ?? "—") source=\(self.selectedSource.rawValue)")
    }

    // MARK: - Actions

    func clearFilters() {
        searchText = ""
        selectedCategory = .all
        selectedTag = nil
        selectedSource = .all
    }

    // MARK: - CRUD pass-through

    @discardableResult
    func deletePrompt(_ prompt: DevPrompt) -> Bool {
        service.deletePrompt(withId: prompt.id)
    }

    @discardableResult
    func togglePin(_ prompt: DevPrompt) -> Bool {
        service.togglePin(prompt)
    }

    // MARK: - Internal

    private func sort(_ prompts: [DevPrompt]) -> [DevPrompt] {
        switch sortOrder {
        case .alphabetical:
            return prompts.sorted { $0.title.lowercased() < $1.title.lowercased() }
        case .recentlyUsed:
            return prompts.sorted { lhs, rhs in
                // nil lastUsedAt sorts to the bottom
                switch (lhs.lastUsedAt, rhs.lastUsedAt) {
                case let (l?, r?): return l > r
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):   return lhs.title.lowercased() < rhs.title.lowercased()
                }
            }
        case .recentlyCreated:
            return prompts.sorted { $0.createdAt > $1.createdAt }
        }
    }
}

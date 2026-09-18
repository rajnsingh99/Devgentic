// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DestinationCoordinator.swift
//  Devgentic
//
//  Owns long-lived view models for destination routes so their state survives
//  view recreation. Rationale:
//
//  `MainApplicationView` wraps Layer 2 (destination container views) in an
//  `if !router.isShowingChat { destinationView }` gate. Each time `isShowingChat`
//  toggles, SwiftUI tears the subtree down and next render materializes fresh
//  container views — which means fresh `@State` view models on every visit.
//  For Ollama/MLX that meant: refetching all local models, firing `/api/show`
//  per model, losing the user's search text, scroll position, selected sort,
//  and selected category every time they glanced back at chat.
//
//  The coordinator holds the VMs outside the view hierarchy so they persist
//  for the app's lifetime. Container views read the VM from environment via
//  `@Environment(DestinationCoordinator.self)` and bind to it with `@Bindable`.
//
//  Instantiation is lazy — VMs are only created on first access, so users who
//  never open a model store never pay the observation-tracking setup cost.
//

import Foundation

@Observable @MainActor
final class DestinationCoordinator {

    // MARK: - Lazy-created view models
    //
    // The backing stores are `@ObservationIgnored` because the coordinator
    // itself doesn't need SwiftUI observation — the VMs returned from these
    // getters are individually `@Observable` and drive view updates directly.

    @ObservationIgnored private var _ollamaStore: OllamaModelStoreViewModel?

    @ObservationIgnored private var _mlxGeneralStore: MLXModelStoreViewModel?
    @ObservationIgnored private var _mlxToolsStore: MLXModelStoreViewModel?

    @ObservationIgnored private var _promptBrowse: PromptBrowseViewModel?

    // MARK: - Accessors

    /// Long-lived Ollama model-store view model. Created on first access; same
    /// instance returned across the app's lifetime so the user's search text,
    /// sort option, and cached displayedModels survive navigation away and back.
    var ollamaStore: OllamaModelStoreViewModel {
        if let existing = _ollamaStore { return existing }
        let vm = OllamaModelStoreViewModel()
        _ollamaStore = vm
        return vm
    }

    /// MLX store VM for the requested filter context. The unfiltered (`false`)
    /// and tool-filtered (`true`) variants are cached separately because each
    /// tracks its own category, search, and sort state.
    func mlxStore(filterForTools: Bool) -> MLXModelStoreViewModel {
        if filterForTools {
            if let existing = _mlxToolsStore { return existing }
            let vm = MLXModelStoreViewModel(filterForTools: true)
            _mlxToolsStore = vm
            return vm
        } else {
            if let existing = _mlxGeneralStore { return existing }
            let vm = MLXModelStoreViewModel(filterForTools: false)
            _mlxGeneralStore = vm
            return vm
        }
    }

    /// Prompt-library browse VM (search / category / sort / pin / tag / selection)
    /// owned here so sidebar state survives tab switches. The sidebar lives
    /// inside a `switch selectedTab` in `SidebarPaneView` — selecting any other
    /// tab destroys `PromptLibrarySidebarView`, and previously the `@State` VM
    /// died with it, resetting filters on every return visit.
    ///
    /// The edit-buffer fields used to live on this same VM, but that forced
    /// every edit site (detail view, AdvancedPromptEditor, AgentConfigDetailView,
    /// create popover) to either reuse the sidebar's buffer (leaking drafts
    /// across contexts) or instantiate its own full-blown `PromptLibraryViewModel`
    /// just to get the buffer — both ugly. Edit state now lives on
    /// `PromptEditViewModel`, one instance per edit surface.
    var promptBrowse: PromptBrowseViewModel {
        if let existing = _promptBrowse { return existing }
        let vm = PromptBrowseViewModel()
        _promptBrowse = vm
        return vm
    }

    // MARK: - Init

    init() {}
}

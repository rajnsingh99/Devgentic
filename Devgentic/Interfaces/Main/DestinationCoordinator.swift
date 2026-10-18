// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DestinationCoordinator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Owns long-lived view models for destination routes so their state (search text, scroll position, sort, category)
/// survives view recreation. Created lazily on first access; container views read them via
/// `@Environment(DestinationCoordinator.self)` and bind with `@Bindable`.
@Observable @MainActor
final class DestinationCoordinator {

    // MARK: - Lazy-created view models
    // The backing stores are `@ObservationIgnored` because the VMs returned from the getters are individually
    // `@Observable` and drive view updates themselves.

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

    /// Prompt-library browse VM (search, category, sort, pin, tag, selection) owned here so sidebar state survives tab
    /// switches. Edit state lives on `PromptEditViewModel`, one instance per edit surface.
    var promptBrowse: PromptBrowseViewModel {
        if let existing = _promptBrowse { return existing }
        let vm = PromptBrowseViewModel()
        _promptBrowse = vm
        return vm
    }

    // MARK: - Init

    init() {}
}

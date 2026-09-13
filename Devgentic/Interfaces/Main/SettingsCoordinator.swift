// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SettingsCoordinator.swift
//  Devgentic
//
//  Owns the read/persist paths for every UserDefaults-backed user setting
//  the VM exposes: streaming response toggle, intelligence core toggle,
//  web search API key + active state, and the persisted interface mode.
//
//  Scope choice: state stays on `MainApplicationViewModel`. SwiftUI views
//  use `Bindable(viewModel).useStreamingResponse` directly — moving the
//  property into the coordinator would require every settings view to
//  switch to `Bindable(viewModel.settingsCoordinator).useStreamingResponse`
//  or to observe the coordinator through a new environment injection. The
//  goal of this extraction is to lift the *load/persist logic* out of the
//  VM, not to re-shape the observed-state graph.
//
//  The coordinator mutates VM state through a weak back-reference on load
//  and reads VM state on persist — the same pattern the prior coordinators
//  use.
//

import Foundation
import os

@MainActor
final class SettingsCoordinator {

    private let logger = DGLogger(category: "SettingsCoordinator")

    private weak var viewModel: MainApplicationViewModel?

    /// UserDefaults key for the web search API key. Kept here rather than in
    /// `AppSettings` because nothing outside the settings load/persist paths
    /// references it — centralizing it in the coordinator scopes its use.
    private let webSearchAPIKeyDefaultsKey = "webSearchAPIKey"

    /// UserDefaults key for the persisted interface mode. Likewise coordinator-scoped.
    private let interfaceModeDefaultsKey = "devgentic.interfaceMode"

    init(viewModel: MainApplicationViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Load (call once from VM init)

    /// Pulls every persisted setting into the VM in a single pass. Run once
    /// from `MainApplicationViewModel.init` before anything else uses these
    /// values (the conversation loader observes `isWebSearchActive`, etc.).
    func load() {
        guard let vm = viewModel else { return }

        // Interface mode
        if let saved = UserDefaults.standard.string(forKey: interfaceModeDefaultsKey),
           let mode = MainApplicationViewModel.InterfaceMode(rawValue: saved) {
            vm.interfaceMode = mode
        }

        // Streaming response default-on. Seed if absent so first-launch users
        // get streaming enabled without an extra settings visit.
        if UserDefaults.standard.object(forKey: AppSettings.useStreamingResponseKey) == nil {
            UserDefaults.standard.set(true, forKey: AppSettings.useStreamingResponseKey)
        }
        // ⚠️ NOTHING TO COPY INTO THE VIEW MODEL ANY MORE. `useStreamingResponse` and
        // `isIntelligenceCoreEnabled` are computed over `UserDefaults`, so assigning them here
        // would write back the value just read. The seeding above stays: it is load-bearing for
        // the DIRECT readers of the key (e.g. `WorkflowPreferenceSource`), which use
        // `bool(forKey:)` and would read an absent key as false — the opposite of the shipped
        // default.

        // Web search: API key presence determines enablement; active state starts off.
        vm.webSearchAPIKey = UserDefaults.standard.string(forKey: webSearchAPIKeyDefaultsKey)
        vm.isWebSearchEnabled = (vm.webSearchAPIKey != nil && !vm.webSearchAPIKey!.isEmpty)
        vm.isWebSearchActive = false

        logger.info("Loaded 'useStreamingResponse' setting from UserDefaults: \(vm.useStreamingResponse)")
        if vm.isWebSearchEnabled {
            logger.info("Web search is enabled (API key found in UserDefaults).")
        } else {
            logger.info("Web search is disabled (API key not found in UserDefaults).")
        }
    }

    // MARK: - Individual-Setting Change Persisters

    // ⚠️ `didChangeUseStreamingResponse` and `didChangeIntelligenceCoreEnabled` lived here and
    // were the ONLY writers of their two keys. Neither had a single caller: the settings toggles
    // bound straight to the stored view-model properties, so flipping one updated the UI and
    // nothing else. Both properties now persist in their own setters, so a second persistence
    // path would be exactly the "one rule over two copies" shape that caused the bug.

    /// Persists the interface-mode change. Called from `switchInterfaceMode` on
    /// the VM after the mode has been updated in memory.
    func didChangeInterfaceMode(_ mode: MainApplicationViewModel.InterfaceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: interfaceModeDefaultsKey)
    }

    // MARK: - Web Search

    func toggleWebSearch() {
        guard let vm = viewModel else { return }
        guard vm.isWebSearchEnabled else { return }
        vm.isWebSearchActive.toggle()
        logger.info("Web search active state toggled to: \(vm.isWebSearchActive)")
    }

    func saveAndEnableWebSearch(apiKey: String) {
        guard let vm = viewModel else { return }
        UserDefaults.standard.set(apiKey, forKey: webSearchAPIKeyDefaultsKey)
        vm.webSearchAPIKey = apiKey
        vm.isWebSearchEnabled = true
        vm.isWebSearchActive = true
        logger.info("Successfully saved web search API key to UserDefaults and enabled search.")
    }

    func disableAndRemoveWebSearch() {
        guard let vm = viewModel else { return }
        UserDefaults.standard.removeObject(forKey: webSearchAPIKeyDefaultsKey)
        vm.webSearchAPIKey = nil
        vm.isWebSearchEnabled = false
        vm.isWebSearchActive = false
        logger.info("Successfully removed web search API key from UserDefaults and disabled search.")
    }
}

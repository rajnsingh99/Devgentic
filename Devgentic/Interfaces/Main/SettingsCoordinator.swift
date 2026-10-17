// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SettingsCoordinator.swift
//  Devgentic
//
//  Owns the read/persist paths for every persisted user setting the VM
//  exposes: streaming response toggle, intelligence core toggle and the
//  persisted interface mode (UserDefaults).
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

    /// UserDefaults key for the persisted interface mode. Likewise coordinator-scoped.
    private let interfaceModeDefaultsKey = "devgentic.interfaceMode"

    init(viewModel: MainApplicationViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Load (call once from VM init)

    /// Pulls every persisted setting into the VM in a single pass. Run once
    /// from `MainApplicationViewModel.init` before anything else uses these
    /// values.
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

        logger.info("Loaded 'useStreamingResponse' setting from UserDefaults: \(vm.useStreamingResponse)")
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
}

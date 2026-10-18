// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SettingsCoordinator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Owns the read/persist paths for the persisted user settings the view model exposes: the streaming response toggle,
/// the intelligence core toggle and the interface mode (UserDefaults).
/// State stays on `MainApplicationViewModel`; the coordinator mutates it through a weak back-reference on load.
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
        // Nothing to copy into the view model: its toggles are computed over `UserDefaults`, so assigning them would write back.
        // The seeding above stays for direct `bool(forKey:)` readers, which would read an absent key as false.

        logger.info("Loaded 'useStreamingResponse' setting from UserDefaults: \(vm.useStreamingResponse)")
    }

    // MARK: - Individual-Setting Change Persisters

    // The streaming and intelligence-core toggles persist in their own setters, so this handles interface mode only:
    // a second persistence path would be the "one rule over two copies" shape.

    /// Persists the interface-mode change. Called from `switchInterfaceMode` on
    /// the VM after the mode has been updated in memory.
    func didChangeInterfaceMode(_ mode: MainApplicationViewModel.InterfaceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: interfaceModeDefaultsKey)
    }
}

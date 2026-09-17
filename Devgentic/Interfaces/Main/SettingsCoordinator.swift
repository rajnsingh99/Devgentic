// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SettingsCoordinator.swift
//  Devgentic
//
//  Owns the read/persist paths for every persisted user setting the VM
//  exposes: streaming response toggle, intelligence core toggle, the web
//  search API key (Keychain, via `WebSearchKeyStore` — register KC-2) plus
//  its active state, and the persisted interface mode (UserDefaults).
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

        // Web search: the key lives in the Keychain (register KC-2 — it was the one credential the
        // current design wrote to UserDefaults in plaintext). Presence determines enablement;
        // active state starts off.
        //
        // ⚠️ The plaintext→Keychain migration rewrites the developer's REAL preferences domain, and
        // the XCTest host runs this initializer in full — so it is refused there, like every other
        // launch step `TestHost.permits` guards. The read itself is safe: under XCTest the Keychain
        // is an in-memory stand-in.
        if TestHost.permits("migrate the web-search API key from UserDefaults into the Keychain", logger: logger) {
            WebSearchKeyStore.migrateFromUserDefaults()
        }
        switch WebSearchKeyStore.read() {
        case .found(let key):
            vm.webSearchAPIKey = key
        case .notFound:
            vm.webSearchAPIKey = nil
        case .failed:
            // The store has logged the OSStatus; this line says what the user will see.
            vm.webSearchAPIKey = nil
            logger.error(
                "[SETTINGS] The web-search API key could not be read from the Keychain, so web search "
                + "starts DISABLED this session although a key may well be stored. CONSEQUENCE: the "
                + "feature presents as unconfigured; the key is untouched and comes back on a launch "
                + "where the Keychain is readable (unlock it, or re-grant access after an update)."
            )
        }
        vm.isWebSearchEnabled = !(vm.webSearchAPIKey ?? "").isEmpty
        vm.isWebSearchActive = false

        logger.info("Loaded 'useStreamingResponse' setting from UserDefaults: \(vm.useStreamingResponse)")
        if vm.isWebSearchEnabled {
            logger.info("Web search is enabled (API key found in the Keychain).")
        } else {
            logger.info("Web search is disabled (no API key in the Keychain).")
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

    /// Stores the key in the Keychain and enables web search.
    /// - Returns: false when the key could NOT be stored — in which case nothing is enabled, and
    ///   the caller must tell the user rather than dismiss as though it succeeded (register KC-2).
    ///   The store never falls back to plaintext.
    @discardableResult
    func saveAndEnableWebSearch(apiKey: String) -> Bool {
        guard let vm = viewModel else { return false }
        guard WebSearchKeyStore.save(apiKey) else {
            // The store has logged the OSStatus and its consequence. The feature stays off so the
            // UI cannot claim a credential the app does not hold.
            vm.webSearchAPIKey = nil
            vm.isWebSearchEnabled = false
            vm.isWebSearchActive = false
            return false
        }
        purgeLegacyPlaintextCopy()
        vm.webSearchAPIKey = apiKey
        vm.isWebSearchEnabled = true
        vm.isWebSearchActive = true
        logger.info("Saved the web search API key to the Keychain and enabled search.")
        return true
    }

    func disableAndRemoveWebSearch() {
        guard let vm = viewModel else { return }
        let removed = WebSearchKeyStore.delete()
        purgeLegacyPlaintextCopy()
        vm.webSearchAPIKey = nil
        vm.isWebSearchEnabled = false
        vm.isWebSearchActive = false
        if removed {
            logger.info("Removed the web search API key from the Keychain and disabled search.")
        }
        // A failed delete is logged by the store with its consequence: the feature is off for this
        // session, but the key survives and web search comes back on the next launch.
    }

    /// Removes the plaintext copy an earlier build may have left in UserDefaults.
    ///
    /// Load-bearing after a successful save: `WebSearchKeyStore.migrateFromUserDefaults` lets the
    /// plaintext value WIN, so a stale copy left behind would be migrated over the key just saved
    /// on the next launch. ⚠️ Refused under XCTest — `UserDefaults.standard` is the developer's
    /// real domain there, and the migration that would normally have removed this copy is refused
    /// too, so a test must not be the thing that deletes it.
    private func purgeLegacyPlaintextCopy() {
        guard TestHost.permits("remove the plaintext web-search API key from UserDefaults", logger: logger) else { return }
        UserDefaults.standard.removeObject(forKey: WebSearchKeyStore.legacyDefaultsKey)
    }
}

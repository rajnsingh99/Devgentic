// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  QuickAccessConfigManager.swift
//  Devgentic
//
//  [QA revival P1d] Single source of truth for QuickAccess configuration — the global
//  hotkey, enable flag, and session timeout. Modeled on ChatOpsConfigManager: an
//  @Observable @MainActor singleton over UserDefaults, so it is reachable BOTH from
//  AppDelegate (which registers the Carbon hotkey outside any SwiftUI environment) and from
//  the SwiftUI settings pane. The default profile lives under GlobalConstants.quickAccessProfileID
//  (see QuickAccessSessionViewModel) and is not duplicated here.
//

import Foundation
import Observation
import HotKey

// Not @MainActor (unlike ChatOpsConfigManager): AppDelegate reads it from nonisolated
// lifecycle/hotkey methods. Backing store is thread-safe UserDefaults and all access happens
// on the main thread (AppKit lifecycle + the SwiftUI settings pane), so plain @Observable is
// sufficient. [L10] The Observation `access()`/`withMutation()` machinery is NOT thread-safe,
// so this type is deliberately MAIN-THREAD-CONFINED; the setters assert it in debug builds as a
// tripwire against a future off-main mutation slipping in.
@Observable
final class QuickAccessConfigManager {

    nonisolated(unsafe) static let shared = QuickAccessConfigManager()

    /// [L10] Debug tripwire: all mutation must happen on the main thread (see the type note).
    private func assertMainThread() {
        assert(Thread.isMainThread, "QuickAccessConfigManager must be mutated on the main thread (Observation is not thread-safe).")
    }

    /// Default shortcut: ⌥Space (the app's original hardcoded binding).
    private static let defaultCombo = KeyCombo(key: .space, modifiers: .option)

    private let defaults = UserDefaults.standard

    // MARK: - Enable

    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            // Default ON when never set.
            return defaults.object(forKey: GlobalConstants.quickAccessEnabled) as? Bool ?? true
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.isEnabled) {
                defaults.set(newValue, forKey: GlobalConstants.quickAccessEnabled)
            }
        }
    }

    // MARK: - Hotkey (persisted as two Carbon UInt32s)

    var carbonKeyCode: UInt32 {
        get {
            access(keyPath: \.carbonKeyCode)
            // [L1] `UInt32(exactly:)` — the plain `UInt32(v)` traps on a negative/oversized value,
            // and this is read at launch (applyHotkeyConfig), so a corrupt/externally-written
            // default (`defaults write … -1`) would crash-loop the app with no in-app recovery.
            // Fall back to the default combo instead.
            if let v = defaults.object(forKey: GlobalConstants.quickAccessHotkeyKeyCode) as? Int,
               let code = UInt32(exactly: v) {
                return code
            }
            return Self.defaultCombo.carbonKeyCode
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.carbonKeyCode) {
                defaults.set(Int(newValue), forKey: GlobalConstants.quickAccessHotkeyKeyCode)
            }
        }
    }

    var carbonModifiers: UInt32 {
        get {
            access(keyPath: \.carbonModifiers)
            // [L1] Non-trapping conversion + fallback (see carbonKeyCode).
            if let v = defaults.object(forKey: GlobalConstants.quickAccessHotkeyModifiers) as? Int,
               let mods = UInt32(exactly: v) {
                return mods
            }
            return Self.defaultCombo.carbonModifiers
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.carbonModifiers) {
                defaults.set(Int(newValue), forKey: GlobalConstants.quickAccessHotkeyModifiers)
            }
        }
    }

    var keyCombo: KeyCombo { KeyCombo(carbonKeyCode: carbonKeyCode, carbonModifiers: carbonModifiers) }

    /// Human-readable shortcut, e.g. "⌥Space".
    var shortcutDescription: String { keyCombo.description }

    func setShortcut(carbonKeyCode: UInt32, carbonModifiers: UInt32) {
        self.carbonKeyCode = carbonKeyCode
        self.carbonModifiers = carbonModifiers
    }

    func resetShortcutToDefault() {
        setShortcut(carbonKeyCode: Self.defaultCombo.carbonKeyCode,
                    carbonModifiers: Self.defaultCombo.carbonModifiers)
    }

    // MARK: - Session timeout

    /// How long (in SECONDS) a closed panel session is resumable before a fresh conversation
    /// starts. Default 60s (1 min); configurable 10s–5min in the settings pane.
    var sessionTimeoutSeconds: Int {
        get {
            access(keyPath: \.sessionTimeoutSeconds)
            return defaults.object(forKey: GlobalConstants.quickAccessSessionTimeoutSeconds) as? Int ?? 60
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.sessionTimeoutSeconds) {
                defaults.set(newValue, forKey: GlobalConstants.quickAccessSessionTimeoutSeconds)
            }
        }
    }
}

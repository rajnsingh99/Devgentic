// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  QuickAccessConfigManager.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import Observation
import HotKey

// Not @MainActor (AppDelegate reads it from nonisolated methods) but main-thread-confined: Observation's
// `access()`/`withMutation()` is not thread-safe, and the setters assert the thread in debug builds.
/// Single source of truth for QuickAccess configuration: the global hotkey, enable flag and session timeout.
/// An `@Observable` singleton over UserDefaults, reachable from AppDelegate (which registers the Carbon hotkey outside
/// SwiftUI) and the settings pane. The default profile lives under `GlobalConstants.quickAccessProfileID`.
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
            // Use `UInt32(exactly:)`: `UInt32(v)` traps on a negative or oversized value, and this is read at launch, so a
            // corrupt default would crash-loop the app. Fall back to the default combo instead.
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

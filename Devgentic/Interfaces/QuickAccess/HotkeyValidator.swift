// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  HotkeyValidator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import AppKit

/// Outcome of validating a candidate shortcut. [H4]
enum HotkeyValidation: Equatable {
    /// Safe to bind.
    case ok
    /// Hard-blocked: would break typing or an OS-critical shortcut. Do not bind.
    case rejected(reason: String)
    /// Bindable, but the system is likely to intercept it (so it may not fire). Bind with a
    /// visible caveat rather than silently.
    case discouraged(reason: String)
}

enum HotkeyValidator {

    // Carbon virtual key codes (kVK_*) for the keys we special-case.
    private enum VK {
        static let space: UInt32 = 49
        static let q: UInt32 = 12
        static let w: UInt32 = 13
        static let h: UInt32 = 4
        static let m: UInt32 = 46
        static let tab: UInt32 = 48
        static let grave: UInt32 = 50   // ` / ~ (⌘` app-window cycle)
    }

    /// Validate a candidate combo. `modifiers` is the raw NSEvent set; only ⌘⌥⌃⇧ are considered.
    static func validate(carbonKeyCode: UInt32, modifiers: NSEvent.ModifierFlags) -> HotkeyValidation {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        let nonShift = mods.subtracting(.shift)

        // A "real" modifier (⌘/⌥/⌃) is required — Shift alone would capture a plain letter
        // globally, breaking capitalisation everywhere.
        guard !nonShift.isEmpty else {
            // [M10] String(localized:) so reasons extract into the catalog (plain values, not literals).
            return .rejected(reason: String(localized: "Add ⌘, ⌥, or ⌃ — Shift on its own isn't a valid shortcut."))
        }

        // OS-critical single-⌘ shortcuts: binding these globally would hijack them in every app.
        let onlyCommand = nonShift == .command   // exactly ⌘ (± Shift), no ⌥/⌃
        if onlyCommand {
            switch carbonKeyCode {
            case VK.q: return .rejected(reason: String(localized: "⌘Q is Quit — choose another combo."))
            case VK.w: return .rejected(reason: String(localized: "⌘W is Close Window — choose another combo."))
            case VK.h: return .rejected(reason: String(localized: "⌘H is Hide — choose another combo."))
            case VK.m: return .rejected(reason: String(localized: "⌘M is Minimize — choose another combo."))
            case VK.tab: return .rejected(reason: String(localized: "⌘Tab is the app switcher — choose another combo."))
            case VK.grave: return .rejected(reason: String(localized: "⌘` cycles windows — choose another combo."))
            default: break
            }
        }

        // Spotlight / input-source switching own Space with ⌘ or ⌃; the OS usually wins, so the
        // panel would appear dead. Allow (some users disable Spotlight) but warn. ⌥Space — the
        // app's own default — is deliberately NOT flagged.
        if carbonKeyCode == VK.space, mods.contains(.command) || mods.contains(.control) {
            return .discouraged(reason: String(localized: "macOS uses this for Spotlight / input sources and may intercept it."))
        }

        return .ok
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  HotkeyRegistrationProbe.swift
//  Devgentic
//
//  [M1] The soffes/HotKey package swallows RegisterEventHotKey's OSStatus
//  (HotKeysController.register: `guard registerError == noErr … else { return }`), so
//  constructing a HotKey never signals failure — AppDelegate could only ever log "registered"
//  unconditionally, even when the OS refused the combo. This does an independent best-effort
//  Carbon probe (register → immediately unregister) so the app can log the truth and warn.
//
//  Scope note: many "dead" combos still register fine at the Carbon layer (e.g. ⌘Space, which
//  Spotlight consumes upstream). Those are guarded at record time by HotkeyValidator; this probe
//  only catches a HARD refusal (RegisterEventHotKey returning a non-zero OSStatus).
//

import Carbon.HIToolbox

enum HotkeyRegistrationProbe {

    /// True if the OS accepts a Carbon hotkey registration for this combo. Registers under a
    /// throwaway id and unregisters immediately, so it never leaves a live binding behind.
    /// Call BEFORE the real (package) registration to avoid a self-conflict false negative.
    static func canRegister(carbonKeyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        var ref: EventHotKeyRef?
        // 'DGpb' signature + a high id unlikely to collide with the package's sequential ids.
        let probeID = EventHotKeyID(signature: OSType(0x44477062), id: 0xFFFF)
        let status = RegisterEventHotKey(
            carbonKeyCode, carbonModifiers, probeID, GetEventDispatcherTarget(), 0, &ref
        )
        if status == noErr, let ref { UnregisterEventHotKey(ref) }
        return status == noErr
    }
}

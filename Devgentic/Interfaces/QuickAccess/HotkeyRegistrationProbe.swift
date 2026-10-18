// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  HotkeyRegistrationProbe.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Carbon.HIToolbox

/// Best-effort Carbon probe of whether the OS accepts a hotkey combo (register, then immediately unregister).
/// The HotKey package swallows RegisterEventHotKey's OSStatus, so the app could not otherwise log a refusal.
/// Catches only a hard refusal (non-zero OSStatus); `HotkeyValidator` guards combos consumed upstream (e.g. Cmd-Space).
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

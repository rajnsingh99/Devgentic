// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  HotkeyRecorderView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit
import HotKey

/// A key-capture control: click to arm, then press modifier(s)+key; a local NSEvent monitor captures the keyDown,
/// translates it to the HotKey package's Carbon form and reports `(carbonKeyCode, carbonModifiers)`. Esc cancels.
/// Combos are validated by `HotkeyValidator`; the armed monitor disarms on an outside click, window-key loss or timeout.
struct HotkeyRecorderView: View {
    /// Human-readable current shortcut, e.g. "⌥Space".
    let currentDescription: String
    /// Called with the captured (carbonKeyCode, carbonModifiers) on a valid combo.
    let onRecorded: (UInt32, UInt32) -> Void
    /// [M3] Fired true when recording starts, false when it stops, so the owner can pause/resume
    /// the live global hotkey around recording.
    var onRecordingStateChanged: ((Bool) -> Void)?

    @Environment(\.appTheme) private var theme
    @State private var isRecording = false
    @State private var message: RecorderMessage?

    // [M4] Everything installed while armed, torn down on stop().
    @State private var keyMonitor: Any?
    @State private var mouseMonitor: Any?
    @State private var resignObserver: NSObjectProtocol?
    @State private var timeoutTask: Task<Void, Never>?

    private struct RecorderMessage: Equatable {
        let text: String
        let isError: Bool   // true = hard rejection (stay armed); false = caveat on a bound combo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: isRecording ? "record.circle" : "keyboard")
                        .font(.system(size: 11, weight: .semibold))
                    // [M10] Split the ternary: the prompt is localized, the current shortcut (e.g.
                    // "⌥Space") is verbatim key-combo text. A ternary mixing them forces String.
                    Group {
                        if isRecording {
                            Text("Press shortcut…")
                        } else {
                            Text(verbatim: currentDescription)
                        }
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundColor(isRecording ? theme.warningColor : theme.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minWidth: 130)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.surfaceOverlay.opacity(0.5)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isRecording ? theme.warningColor : theme.dividerColor.opacity(0.4), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("Click, then press a modifier + key (e.g. ⌥Space). Esc to cancel.")
            .accessibilityLabel(isRecording ? "Recording shortcut. Press a modifier and a key." : "Current shortcut \(currentDescription). Activate to change.")

            if let message {
                Text(message.text)
                    .font(.system(size: 11))
                    .foregroundColor(message.isError ? theme.warningColor : theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 220, alignment: .leading)
                    .accessibilityLabel((message.isError ? "Invalid shortcut. " : "Note. ") + message.text)
            }
        }
        .onDisappear { stop() }
    }

    private func toggle() { isRecording ? stop() : start() }

    private func start() {
        isRecording = true
        message = nil
        onRecordingStateChanged?(true) // [M3] pause the live hotkey so we can capture it

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event)
        }
        // [M4] A click anywhere means the user moved on — disarm so we stop swallowing keys and
        // never rebind on the next stray modifier+key (e.g. ⌘C in another settings field).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            DispatchQueue.main.async { stop() } // defer so the click still reaches its target
            return event
        }
        // [M4] Disarm if the hosting window loses key focus (app/window switch).
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { _ in stop() }
        // [M4] Safety net: a forgotten armed recorder disarms itself.
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled, isRecording { stop() }
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 { // Escape cancels without changing the binding.
            stop()
            return nil
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Keep listening (and consume, so stray keys don't type) until a modifier+mappable key.
        guard !mods.isEmpty, let key = Key(carbonKeyCode: UInt32(event.keyCode)) else {
            return nil
        }

        switch HotkeyValidator.validate(carbonKeyCode: UInt32(event.keyCode), modifiers: mods) {
        case .rejected(let reason):
            // [H4] Stay armed and explain, so the user can immediately try a different combo.
            message = RecorderMessage(text: reason, isError: true)
            return nil
        case .discouraged(let reason):
            let combo = KeyCombo(key: key, modifiers: mods)
            onRecorded(combo.carbonKeyCode, combo.carbonModifiers)
            message = RecorderMessage(text: reason, isError: false) // set before stop() so it persists
            stop()
            return nil
        case .ok:
            let combo = KeyCombo(key: key, modifiers: mods)
            onRecorded(combo.carbonKeyCode, combo.carbonModifiers)
            message = nil
            stop()
            return nil
        }
    }

    private func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        mouseMonitor = nil
        resignObserver = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        // Clear a transient rejection, but keep a caveat on a combo we just bound.
        if message?.isError == true { message = nil }
        guard isRecording else { return }
        isRecording = false
        onRecordingStateChanged?(false) // [M3] resume the live hotkey
    }
}

//
//  ComposerKit.swift
//  Devgentic
//
//  Phase 1 of the unified composer: a per-surface capability config + the shared composer
//  button primitives (icon / mic / send-stop), so the main composer and the QuickAccess panel
//  stop evolving two visually-drifting copies of the same controls.
//
//  Deliberately NOT shared here (by design):
//  - State: ChatInputViewModel is app-scoped single-slot (one buffer, one mainDelegate) — each
//    surface keeps its own state holder and passes plain values/closures into these views.
//  - The editor: main keeps CustomTextEditor, the panel keeps its TextField (slot-based
//    unification is a later phase).
//  - DynamicActionButton (main's morphing mic/send/stop): kept as-is after phase-2 review — its
//    single-button morph (mic↔send contentTransition), per-VoiceInputState glyphs, Whisper
//    download-progress ring, and long-press/right-click model picker are main-composer features
//    the shared primitives shouldn't absorb. The shared VOICE BEHAVIOR lives in
//    ComposerVoiceController (phase 2); DynamicActionButton's richer pipeline stays on
//    ChatInputViewModel until the per-instance-VM phase.
//

import SwiftUI
import AppKit

// MARK: - Style constants

/// Single source of truth for composer typography (was hardcoded 14pt in CustomTextEditor,
/// the main composer's typing attributes, and both placeholders — gap 4 of the UI audit).
/// NOTE: full Theme-protocol tokenization needs an NSFont-typed token (3-seam rule) — this
/// centralizes the value so that swap is one edit.
enum ComposerStyle {
    static let editorFontSize: CGFloat = 14
    static var editorNSFont: NSFont { .systemFont(ofSize: editorFontSize) }
}

// MARK: - Capabilities

/// What a given composer surface offers. Drives which buttons render, so a feature like
/// screenshot capture is a flag flip per surface instead of view surgery.
struct ComposerCapabilities {
    var attachments: Bool
    var screenshot: Bool
    var voice: Bool

    /// The main window's composer. Screenshot is off until the capture service is generalized
    /// (QuickAccessScreenCaptureService currently hides the QuickAccess panel specifically
    /// during capture); flipping it on here + providing the callback is then the only change.
    static let mainComposer = ComposerCapabilities(attachments: true, screenshot: false, voice: true)

    /// The QuickAccess floating panel: a chat surface with attach + screenshot + dictation.
    static let quickAccess = ComposerCapabilities(attachments: true, screenshot: true, voice: true)
}

// MARK: - Icon button

/// The standard 28×28 circular composer icon button (attach, screenshot, …). Unifies the
/// panel's static-circle style and the main toolbar's hover-circle style: faint base circle,
/// brighter circle + primary-text icon on hover.
struct ComposerIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    var disabled: Bool = false
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(.body, weight: .medium))
                .foregroundColor(isHovered && !disabled ? theme.primaryText : theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(
                    // [UI audit A] Transparent at rest — auxiliary buttons reveal their circle
                    // only on hover, so they never outweigh the primary (send) action.
                    Circle().fill(isHovered && !disabled ? theme.surfaceOverlay : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1.0)
        .onHover { hover in withAnimation(.easeInOut(duration: 0.15)) { isHovered = hover } }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

// MARK: - Mic button

/// Dictation toggle with the recording pulse ring. Purely visual — the surface supplies the
/// recording/readiness state and the toggle action (main routes through ChatInputViewModel,
/// the panel drives WhisperRecognitionService directly).
struct ComposerMicButton: View {
    let isRecording: Bool
    /// False when no speech model is loaded — the icon dims but stays tappable so the surface
    /// can explain why (e.g. the panel's voice-model popover).
    let isReady: Bool
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    Circle()
                        .fill(Color.red.opacity(0.15)
                            .shadow(.drop(color: Color.red.opacity(0.3), radius: 2)))
                        .frame(width: 28, height: 28)
                        .scaleEffect(pulseScale)
                        .onAppear {
                            // Matches DynamicActionButton, this button's near-identical twin,
                            // which already guarded. A forever-pulse is a vestibular trigger.
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                                pulseScale = 1.25
                            }
                        }
                        .onDisappear { pulseScale = 1.0 }
                }

                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(.body, weight: .medium))
                    .foregroundColor(isRecording ? .red : (isReady ? (isHovered ? theme.primaryText : theme.secondaryText) : theme.secondaryText.opacity(0.3)))
                    .frame(width: 28, height: 28)
                    .background(isHovered ? theme.surfaceOverlay : Color.clear) // [UI audit A] same hover token as ComposerIconButton
                    .clipShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .onHover { hover in isHovered = hover }
        .help(isRecording ? "Stop dictation" : "Dictate")
        .accessibilityLabel(isRecording ? "Stop dictation"
                            : (isReady ? "Start voice dictation"
                               : "Voice dictation unavailable — no speech model downloaded"))
    }
}

// MARK: - Send / stop button

/// Accent-filled send button that flips to a stop control while a response is streaming.
struct ComposerSendStopButton: View {
    let isSending: Bool
    let isDisabled: Bool
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isSending {
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 28, height: 28)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.red)
                } else {
                    // [UI audit A] Disabled = fully transparent with a faded glyph, so the
                    // enabled accent circle is the ONLY filled control in the row (hierarchy).
                    Circle()
                        .fill(!isDisabled ? (isHovered ? theme.accentColor.opacity(0.9) : theme.accentColor) : Color.clear)
                        .frame(width: 28, height: 28)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(!isDisabled ? .white : theme.secondaryText.opacity(0.3))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hover in isHovered = hover }
        .help(isSending ? "Stop" : "Send")
        .accessibilityLabel(isSending ? "Stop generating" : "Send")
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
    /// Standard compact composer action button size (down from 28 to 24 for refined macOS density).
    static let buttonSize: CGFloat = 24
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

/// The standard circular composer icon button (attach, screenshot, …).
/// Adapts between Apple Liquid Glass and Pro Solid Matte via `composerControlSurface`.
struct ComposerIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    var disabled: Bool = false
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            action()
        }) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(isHovered && !disabled ? theme.primaryText : theme.secondaryText.opacity(0.85))
                .frame(width: ComposerStyle.buttonSize, height: ComposerStyle.buttonSize)
                .composerControlSurface(in: Circle(), isHovered: isHovered && !disabled)
                .shadow(color: isHovered && !disabled ? Color.black.opacity(0.2) : .clear, radius: 4, x: 0, y: 1)
                .scaleEffect(isHovered && !disabled ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .pointingHandCursor(enabled: !disabled)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1.0)
        .onHover { hover in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovered = hover } }
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
        Button(action: {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            action()
        }) {
            ZStack {
                if isRecording {
                    Circle()
                        .fill(Color.red.opacity(0.15)
                            .shadow(.drop(color: Color.red.opacity(0.3), radius: 2)))
                        .frame(width: ComposerStyle.buttonSize, height: ComposerStyle.buttonSize)
                        .scaleEffect(pulseScale)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                                pulseScale = 1.25
                            }
                        }
                        .onDisappear { pulseScale = 1.0 }
                }

                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(isRecording ? .red : (isReady ? (isHovered ? theme.primaryText : theme.secondaryText) : theme.secondaryText.opacity(0.3)))
                    .frame(width: ComposerStyle.buttonSize, height: ComposerStyle.buttonSize)
                    .background(isHovered ? theme.surfaceOverlayStrong : Color.clear)
                    .clipShape(Circle())
                    .scaleEffect(isHovered ? 1.06 : 1.0)
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor(enabled: isReady)
        .onHover { hover in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovered = hover } }
        .help(isRecording ? "Stop dictation (⌘⇧V)" : "Start voice dictation (⌘⇧V)")
        .accessibilityLabel(isRecording ? "Stop dictation"
                            : (isReady ? "Start voice dictation"
                               : "Voice dictation unavailable — no speech model downloaded"))
        // Right-click: which microphone dictation records from (shared with the main composer).
        .contextMenu { MicrophoneMenu() }
        .onAppear { MicrophoneSelection.shared.refresh() }
    }
}

// MARK: - Primary action button

/// Tactile circular primary action button (Send, Confirm/Transcribe, etc.) that respects ButtonAccentStyle and SurfaceStyle.
struct ComposerPrimaryButton: View {
    let systemName: String
    let help: LocalizedStringKey
    var isDisabled: Bool = false
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.surfaceStyle) private var surfaceStyle
    @Environment(\.buttonAccentStyle) private var buttonAccentStyle
    @State private var isHovered = false

    private var isThemeContrast: Bool {
        buttonAccentStyle == .themeContrast
    }

    private var foregroundColor: Color {
        if isDisabled {
            return theme.secondaryText.opacity(0.35)
        }
        if isThemeContrast {
            // Dark theme: White button -> Dark icon
            // Light theme: Dark button -> White icon
            return theme.isDark ? Color(red: 0.08, green: 0.08, blue: 0.08) : .white
        }
        return theme.isAccentLight ? Color(red: 0.08, green: 0.08, blue: 0.08) : .white
    }

    private var backgroundColor: Color {
        if isDisabled {
            if surfaceStyle == .solid {
                return theme.isDark ? Color(hex: "#26262B") : theme.tertiaryBackground
            }
            return theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
        }
        if isThemeContrast {
            if surfaceStyle == .solid {
                return theme.isDark
                    ? Color.white.opacity(isHovered ? 1.0 : 0.96)
                    : Color(red: 0.12, green: 0.12, blue: 0.14).opacity(isHovered ? 1.0 : 0.96)
            }
            return theme.isDark
                ? Color.white.opacity(isHovered ? 1.0 : 0.94)
                : Color(red: 0.12, green: 0.12, blue: 0.14).opacity(isHovered ? 1.0 : 0.94)
        }
        return theme.accentColor.opacity(isHovered ? 1.0 : 0.92)
    }

    private var borderColor: Color {
        if isDisabled {
            return surfaceStyle == .solid ? theme.dividerColor.opacity(0.5) : theme.dividerColor.opacity(0.25)
        }
        if surfaceStyle == .solid {
            if isThemeContrast {
                return theme.isDark ? Color.white : Color.black
            }
            return theme.accentColor
        }
        if isThemeContrast {
            return theme.isDark
                ? Color.white.opacity(isHovered ? 0.9 : 0.7)
                : Color.black.opacity(isHovered ? 0.9 : 0.7)
        }
        return theme.accentColor.opacity(isHovered ? 0.8 : 0.4)
    }

    private var shadowColor: Color {
        if isDisabled {
            return .clear
        }
        if surfaceStyle == .solid {
            if isThemeContrast {
                return Color.black.opacity(theme.isDark ? (isHovered ? 0.40 : 0.25) : (isHovered ? 0.20 : 0.10))
            }
            return Color.black.opacity(theme.isDark ? 0.35 : 0.12)
        }
        if isThemeContrast {
            return Color.black.opacity(theme.isDark ? (isHovered ? 0.35 : 0.20) : (isHovered ? 0.15 : 0.08))
        }
        return theme.accentColor.opacity(isHovered ? 0.35 : 0.18)
    }

    var body: some View {
        Button(action: {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            action()
        }) {
            ZStack {
                Circle()
                    .fill(backgroundColor)
                    .frame(width: ComposerStyle.buttonSize, height: ComposerStyle.buttonSize)
                    .overlay(
                        Circle()
                            .strokeBorder(borderColor, lineWidth: 0.5)
                    )
                    .shadow(
                        color: shadowColor,
                        radius: isHovered ? 4 : 2,
                        x: 0,
                        y: 1
                    )
                Image(systemName: systemName)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(foregroundColor)
            }
            .scaleEffect(isHovered && !isDisabled ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .pointingHandCursor(enabled: !isDisabled)
        .disabled(isDisabled)
        .onHover { hover in withAnimation(.easeInOut(duration: 0.15)) { isHovered = hover } }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

// MARK: - Send / stop button

/// Tactile send button that respects ButtonAccentStyle and SurfaceStyle, and flips to a stop control while streaming.
struct ComposerSendStopButton: View {
    let isSending: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        if isSending {
            Button(action: {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                action()
            }) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(isHovered ? 0.18 : 0.10))
                        .frame(width: ComposerStyle.buttonSize, height: ComposerStyle.buttonSize)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.red.opacity(isHovered ? 0.45 : 0.25), lineWidth: 0.5)
                        )
                        .shadow(color: Color.red.opacity(isHovered ? 0.25 : 0.08), radius: 3, x: 0, y: 1)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.red)
                }
                .scaleEffect(isHovered ? 1.06 : 1.0)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .onHover { hover in withAnimation(.easeInOut(duration: 0.15)) { isHovered = hover } }
            .help("Stop generating (⌘.)")
            .accessibilityLabel("Stop generating")
        } else {
            ComposerPrimaryButton(
                systemName: "arrow.up",
                help: "Send message (⏎)",
                isDisabled: isDisabled,
                action: action
            )
        }
    }
}

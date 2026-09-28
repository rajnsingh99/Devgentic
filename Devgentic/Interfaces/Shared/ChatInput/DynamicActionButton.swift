// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DynamicActionButton.swift
//  Devgentic
//
//  Extracted from ChatInputAreaView.swift
//

import SwiftUI
import os
import AppKit

private let logger = DGLogger(category: "DynamicActionButton")

// MARK: - Mode Enum

enum DynamicButtonMode: CustomStringConvertible {
    case mic, stopVoice, send, stopStreaming
    var description: String {
        switch self {
        case .mic: return "Mic"
        case .stopVoice: return "Stop Voice"
        case .send: return "Send"
        case .stopStreaming: return "Stop Streaming"
        }
    }
}

// MARK: - View

struct DynamicActionButton: View {

    let mode: DynamicButtonMode
    let isSending: Bool
    let isStreamingActive: Bool
    let userInput: String
    let voiceInputState: VoiceInputState
    let defaultTypingAttributes: [NSAttributedString.Key: Any]
    let editorTextView: CustomTextEditor.CustomNSTextView?
    let backendProfileSelected: Bool

    @Bindable var inputViewModel: ChatInputViewModel

    let onSend: (NSAttributedString, [NSAttributedString.Key: Any]) -> Void
    let onToggleVoice: () -> Void
    let onStopStreaming: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHovering = false
    /// Set when a long-press opened the model picker so the release-click that
    /// follows doesn't ALSO fire the tap action (e.g. start recording).
    @State private var suppressNextTap = false
    /// [Composer parity] Recording pulse (same look as ComposerMicButton).
    @State private var pulseScale: CGFloat = 1.0

    private let buttonSize: CGFloat = ComposerStyle.buttonSize // matches the ComposerKit buttons (24pt)

    /// Source of determinate progress for the model-download ring. @Observable —
    /// reading downloadProgress in body re-renders as the download advances.
    private var downloadService: WhisperModelDownloadService { .shared }

    var body: some View {
        Button(action: handleTap) {
            if mode == .send && isSending && !isStreamingActive {
                ProgressView().controlSize(.small)
                    .frame(width: buttonSize, height: buttonSize)
            } else {
                buttonContent
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor(enabled: !isDisabled)
        // Hold the mic to open the speech-model picker even when a model is
        // already loaded (a plain tap starts recording in that state).
        .simultaneousGesture(modelPickerLongPress)
        .onHover { hover in withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { isHovering = hover } }
        .disabled(isDisabled)
        .help(helpText)
        .accessibilityLabel(helpText)
        // Right-click: the discoverable macOS-native route to the same picker.
        .contextMenu {
            if mode == .mic {
                Button("Change Speech Model…") {
                    inputViewModel.showModelSelectorPopover = true
                }
                MicrophoneMenu()
            }
        }
        // Reads the input devices and starts following plug/unplug, so the menu is current
        // when it opens.
        .onAppear { MicrophoneSelection.shared.refresh() }
        .popover(isPresented: $inputViewModel.showModelSelectorPopover, arrowEdge: .top) {
            WhisperModelSelectorPopover(
                isPresented: $inputViewModel.showModelSelectorPopover,
                currentModelName: inputViewModel.currentSpeechModelName,
                downloadedModelIds: WhisperModelDownloadService.shared.downloadedModelIds,
                onSelectModel: { modelName in
                    inputViewModel.selectDownloadedModel(modelName)
                },
                onSelectUndownloadedModel: { modelName in
                    inputViewModel.requestDownloadConfirmation(for: modelName)
                },
                onDeleteModel: { modelName in
                    inputViewModel.requestDeleteConfirmation(for: modelName)
                }
            )
        }
        .alert(
            whisperAlertTitle,
            isPresented: $inputViewModel.showWhisperAlert
        ) {
            if inputViewModel.activeWhisperAlert == .delete {
                Button("Delete", role: .destructive) { inputViewModel.confirmWhisperAlert() }
            } else {
                Button("Download") { inputViewModel.confirmWhisperAlert() }
            }
            Button("Cancel", role: .cancel) { inputViewModel.cancelWhisperAlert() }
        } message: {
            Text(whisperAlertMessage)
        }
    }

    // MARK: - Button Content

    @ViewBuilder
    private var buttonContent: some View {
        ZStack {
            // [Composer parity] QuickAccess mic look: clear circle with a hover tint normally,
            // pulsing red ring while recording (was a filled accent/error circle).
            if mode == .stopVoice {
                Circle()
                    .fill(Color.red.opacity(0.18)
                        .shadow(.drop(color: Color.red.opacity(0.4), radius: 3)))
                    .scaleEffect(pulseScale)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                            pulseScale = 1.25
                        }
                    }
                    .onDisappear { pulseScale = 1.0 }
            } else {
                Color.clear
                    .frame(width: buttonSize, height: buttonSize)
                    .composerControlSurface(in: Circle(), isHovered: isHovering && !isDisabled)
            }

            // One persistent Image so mode changes morph glyph-to-glyph via symbol
            // replace instead of cross-fading separately stacked views.
            Image(systemName: symbolName)
                .font(symbolFont)
                .foregroundColor(iconForegroundColor)
                .frame(width: buttonSize, height: buttonSize)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .animation(.easeInOut(duration: 0.18), value: symbolName)

            if voiceInputState == .modelLoading || voiceInputState == .modelPreparing {
                modelProgressOverlay
            }
        }
        .frame(width: buttonSize, height: buttonSize)
        .shadow(color: isHovering && !isDisabled && mode != .stopVoice ? Color.black.opacity(0.2) : .clear, radius: 4, x: 0, y: 1)
        .scaleEffect(isHovering && !isDisabled ? 1.06 : 1.0)
    }

    /// Model-fetch overlay: determinate ring while the Whisper download reports
    /// progress, indeterminate spinner otherwise (preparing/specialization has
    /// no progress metric).
    private var modelProgressOverlay: some View {
        Circle()
            .fill(theme.controlBackground.opacity(0.85))
            .frame(width: buttonSize, height: buttonSize)
            .overlay {
                if voiceInputState == .modelLoading, downloadService.downloadProgress > 0 {
                    ZStack {
                        Circle()
                            .stroke(theme.accentColor.opacity(0.25), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: downloadService.downloadProgress)
                            .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.25), value: downloadService.downloadProgress)
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(theme.accentColor)
                    }
                    .padding(3.5)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                }
            }
            .transition(.opacity.animation(.easeInOut(duration: 0.2)))
    }

    // MARK: - Action

    private var modelPickerLongPress: some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .onEnded { _ in
                guard mode == .mic else { return }
                suppressNextTap = true
                inputViewModel.showModelSelectorPopover = true
                // If AppKit swallows the release-click during popover presentation,
                // the Button action never fires — don't let the suppression leak
                // into the next genuine tap.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    suppressNextTap = false
                }
            }
    }

    private func handleTap() {
        if suppressNextTap {
            suppressNextTap = false
            return
        }
        performAction()
    }

    private func performAction() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        switch mode {
        case .send:
            if let textView = editorTextView {
                let textToSend = textView.attributedString()
                if !textToSend.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onSend(textToSend, defaultTypingAttributes)
                } else {
                    logger.debug("Send ignored: attributed text is empty/whitespace.")
                }
            } else if !trimmedInput.isEmpty {
                onSend(NSAttributedString(string: userInput, attributes: defaultTypingAttributes), defaultTypingAttributes)
            } else {
                logger.debug("Send ignored: no textView ref and input is empty.")
            }
        case .mic, .stopVoice:
            onToggleVoice()
        case .stopStreaming:
            onStopStreaming()
        }
    }

    // MARK: - Computed Helpers

    private var trimmedInput: String {
        userInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var symbolName: String {
        switch mode {
        case .send: return "arrow.up"
        case .stopStreaming: return "square.fill"
        case .stopVoice: return "stop.fill" // [Composer parity] QA recording glyph
        case .mic:
            switch voiceInputState {
            case .processing: return "hourglass"
            case .permissionsDeniedMic, .error: return "mic.slash.fill"
            case .requestingPermissions: return "mic.badge.plus"
            case .modelLoading, .modelPreparing: return "arrow.down.circle"
            default: return "mic.fill" // [Composer parity] QA resting glyph (was waveform)
            }
        }
    }

    /// Font-based sizing (required for symbol content transitions); sizes chosen
    /// to match the previous frame-based glyph sizes optically.
    private var symbolFont: Font {
        switch mode {
        case .send:          return .system(size: 10.5, weight: .semibold)
        case .stopStreaming: return .system(size: 9.5, weight: .regular)
        case .stopVoice:     return .system(size: 11, weight: .medium)
        case .mic:           return .system(size: 11.5, weight: .medium)
        }
    }

    private var iconForegroundColor: Color {
        switch mode {
        case .send, .stopStreaming:
            return .white
        case .stopVoice:
            return .red // [Composer parity] QA recording tint (bg is the pulse ring now)
        case .mic:
            switch voiceInputState {
            case .recording: return .red
            case .processing: return theme.controlAccent
            case .permissionsDeniedMic, .error: return theme.errorColor.opacity(0.8)
            case .requestingPermissions: return theme.controlAccent
            case .modelLoading, .modelPreparing: return theme.accentColor
            default: return isHovering ? theme.primaryText : theme.secondaryText // [Composer parity]
            }
        }
    }

    private var isDisabled: Bool {
        switch mode {
        case .send:
            // Only SENDING needs a backend. Voice capture just fills the text field,
            // so the mic (and stop) stay usable before a backend is picked.
            return !backendProfileSelected || trimmedInput.isEmpty || isSending || voiceInputState == .recording || voiceInputState == .processing || voiceInputState == .finalizingSilence
        case .stopVoice: return isSending
        case .stopStreaming: return false
        case .mic:
            return isSending || voiceInputState == .requestingPermissions || voiceInputState == .processing || voiceInputState == .recording || voiceInputState == .finalizingSilence || voiceInputState == .modelLoading || voiceInputState == .modelPreparing
        }
    }

    private var helpText: String {
        switch mode {
        case .send: return String(localized: "Send message (⏎)")
        case .stopVoice: return String(localized: "Stop dictation (⌘⇧V)")
        case .stopStreaming: return String(localized: "Stop generating (⌘.)")
        case .mic:
            switch voiceInputState {
            case .available:
                return String(localized: "Start voice dictation (⌘⇧V) · \(inputViewModel.currentSpeechModelName) — hold or right-click to change model")
            case .idle:
                return String(localized: "Choose a speech model to enable voice input")
            case .modelLoading:
                return String(localized: "Downloading speech model…")
            case .modelPreparing:
                return String(localized: "Preparing speech model…")
            case .processing:
                return String(localized: "Transcribing…")
            case .requestingPermissions:
                return String(localized: "Requesting microphone access…")
            case .permissionsDeniedMic:
                return String(localized: "Microphone access denied — click to open System Settings")
            case .error:
                return String(localized: "Voice input error — click to choose a speech model")
            default:
                return String(localized: "Voice input")
            }
        }
    }

    // MARK: - Whisper Alert Helpers

    private var whisperAlertTitle: String {
        switch inputViewModel.activeWhisperAlert {
        case .download: return String(localized: "Download Required")
        case .delete: return String(localized: "Delete Model")
        case .none: return ""
        }
    }

    private var whisperAlertMessage: String {
        switch inputViewModel.activeWhisperAlert {
        case .download:
            if let modelId = inputViewModel.pendingDownloadModelId,
               let model = WhisperModelCatalog.availableModels.first(where: { $0.id == modelId }) {
                return String(localized: "The \(model.displayName) model (\(model.size)) needs to be downloaded before use.")
            }
            return String(localized: "This model needs to be downloaded before use.")
        case .delete:
            if let modelId = inputViewModel.pendingDeleteModelId,
               let model = WhisperModelCatalog.availableModels.first(where: { $0.id == modelId }) {
                return String(localized: "Delete the \(model.displayName) model? It will need to be re-downloaded to use again.")
            }
            return String(localized: "Delete this model? It will need to be re-downloaded to use again.")
        case .none:
            return ""
        }
    }
}

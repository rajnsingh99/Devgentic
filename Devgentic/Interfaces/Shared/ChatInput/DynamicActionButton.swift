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

    @State private var isHovering = false

    private let buttonSize: CGFloat = 30

    var body: some View {
        Button(action: performAction) {
            if isSending && !isStreamingActive {
                ProgressView().controlSize(.small)
                    .frame(width: buttonSize, height: buttonSize)
            } else {
                buttonContent
                    .frame(width: buttonSize, height: buttonSize)
                    .scaleEffect(isHovering ? 1.05 : 1.0)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hover in withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { isHovering = hover } }
        .disabled(isDisabled)
        .help(helpText)
        .accessibilityLabel(helpText)
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
        let canSend = mode == .send && !trimmedInput.isEmpty
        let isDisabledBySystem = (mode == .send && (voiceInputState == .processing || voiceInputState == .recording))

        ZStack {
            Circle()
                .fill(backgroundColor(canSend: canSend, isDisabledBySystem: isDisabledBySystem))
                .shadow(color: backgroundColor(canSend: canSend, isDisabledBySystem: isDisabledBySystem).opacity(0.3), radius: 3, x: 0, y: 2)

            ZStack {
                if mode == .mic || mode == .stopVoice {
                    Image(systemName: iconName)
                        .resizable().scaledToFit()
                        .fontWeight(.medium)
                        .frame(width: buttonSize * iconScale, height: buttonSize * iconScale)
                        .foregroundColor(iconForegroundColor)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }

                if mode == .send {
                    Image(systemName: "arrow.up")
                        .resizable().scaledToFit()
                        .fontWeight(.semibold)
                        .frame(width: buttonSize * 0.5, height: buttonSize * 0.5)
                        .foregroundColor(.white)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }

                if mode == .stopStreaming {
                    Image(systemName: "square.fill")
                        .resizable().scaledToFit()
                        .fontWeight(.regular)
                        .frame(width: buttonSize * 0.45, height: buttonSize * 0.45)
                        .foregroundColor(.white)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }

            if voiceInputState == .modelLoading || voiceInputState == .modelPreparing {
                Circle()
                    .fill(theme.controlBackground.opacity(0.85))
                    .frame(width: buttonSize, height: buttonSize)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.8)
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
    }

    // MARK: - Action

    private func performAction() {
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

    private var iconName: String {
        switch mode {
        case .send, .stopStreaming: return ""
        case .stopVoice: return "stop.circle.fill"
        case .mic:
            switch voiceInputState {
            case .processing: return "hourglass"
            case .permissionsDeniedMic, .error: return "mic.slash.fill"
            case .requestingPermissions: return "mic.badge.plus"
            case .modelLoading, .modelPreparing: return "arrow.down.circle"
            default: return "waveform"
            }
        }
    }

    private var iconScale: CGFloat {
        mode == .stopVoice ? 0.55 : 0.5
    }

    private func backgroundColor(canSend: Bool, isDisabledBySystem: Bool) -> Color {
        switch mode {
        case .send:
            return (canSend && !isDisabledBySystem) ? theme.controlAccent : theme.secondaryText.opacity(0.2)
        case .stopVoice:
            return theme.errorColor.opacity(0.9)
        case .stopStreaming:
            return theme.primaryText
        case .mic:
            return (isDisabledBySystem || voiceInputState != .available && voiceInputState != .idle) ? theme.controlAccent : theme.secondaryText.opacity(0.2)
        }
    }

    private var iconForegroundColor: Color {
        switch mode {
        case .send, .stopVoice, .stopStreaming:
            return .white
        case .mic:
            switch voiceInputState {
            case .recording: return .white
            case .processing: return theme.controlAccent
            case .permissionsDeniedMic, .error: return theme.errorColor.opacity(0.8)
            case .requestingPermissions: return theme.controlAccent
            case .modelLoading, .modelPreparing: return theme.accentColor
            default: return theme.primaryText
            }
        }
    }

    private var isDisabled: Bool {
        if !backendProfileSelected { return true }
        switch mode {
        case .send:
            return trimmedInput.isEmpty || isSending || voiceInputState == .recording || voiceInputState == .processing || voiceInputState == .finalizingSilence
        case .stopVoice: return isSending
        case .stopStreaming: return false
        case .mic:
            return isSending || voiceInputState == .requestingPermissions || voiceInputState == .processing || voiceInputState == .recording || voiceInputState == .finalizingSilence || voiceInputState == .modelLoading || voiceInputState == .modelPreparing
        }
    }

    private var helpText: String {
        switch mode {
        case .send: return "Send message (Enter)"
        case .stopVoice: return "Stop Voice Input"
        case .stopStreaming: return "Stop generating response"
        case .mic: return "Voice Input"
        }
    }

    // MARK: - Whisper Alert Helpers

    private var whisperAlertTitle: String {
        switch inputViewModel.activeWhisperAlert {
        case .download: return "Download Required"
        case .delete: return "Delete Model"
        case .none: return ""
        }
    }

    private var whisperAlertMessage: String {
        switch inputViewModel.activeWhisperAlert {
        case .download:
            if let modelId = inputViewModel.pendingDownloadModelId,
               let model = WhisperModelCatalog.availableModels.first(where: { $0.id == modelId }) {
                return "The \(model.displayName) model (\(model.size)) needs to be downloaded before use."
            }
            return "This model needs to be downloaded before use."
        case .delete:
            if let modelId = inputViewModel.pendingDeleteModelId,
               let model = WhisperModelCatalog.availableModels.first(where: { $0.id == modelId }) {
                return "Delete the \(model.displayName) model? It will need to be re-downloaded to use again."
            }
            return "Delete this model? It will need to be re-downloaded to use again."
        case .none:
            return ""
        }
    }
}

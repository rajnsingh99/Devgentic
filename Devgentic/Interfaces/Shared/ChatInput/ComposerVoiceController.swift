// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ComposerVoiceController.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AVFoundation

/// Dictation behaviour behind ComposerMicButton: owns the Whisper session lifecycle, permission, live transcript
/// and VAD auto-stop. One instance per surface; it drives the shared WhisperRecognitionService and holds no global
/// state.
@MainActor @Observable
final class ComposerVoiceController {

    /// True while a dictation session is active (drives ComposerMicButton's pulse).
    private(set) var isRecording = false

    /// True when a speech model is downloaded + loaded. False = the surface should explain how
    /// to get one (the button stays tappable for exactly that).
    var isModelReady: Bool {
        if case .loaded = WhisperRecognitionService.shared.loadingState { return true }
        return false
    }

    // MARK: - Surface callbacks (set once by the owning view)

    /// Live + final transcript, already prefixed with the base text passed to `start`.
    /// The surface mirrors this into its input field.
    var onTextChange: ((String) -> Void)?
    /// Mic permission denied — surface explains (e.g. a System Settings popover).
    var onPermissionDenied: (() -> Void)?
    /// A user-initiated stop finished applying the final transcript (surface refocuses input).
    var onFinished: (() -> Void)?

    @ObservationIgnored private var baseText = ""
    @ObservationIgnored private var sessionTask: Task<Void, Never>?

    // MARK: - Session

    /// Toggle dictation. `baseText` is the text already in the field when starting — the live
    /// transcript is appended to it (pass `""` or `existing + " "` as the surface prefers).
    func toggle(baseText: String) {
        if isRecording { stop() } else { start(baseText: baseText) }
    }

    func start(baseText: String) {
        let svc = WhisperRecognitionService.shared
        // Re-entry guard: flips isRecording synchronously (callers are MainActor) so a rapid second tap stops instead of
        // starting a second session.
        guard isModelReady, !isRecording else { return }
        isRecording = true
        self.baseText = baseText

        // One task owns the whole session (permission → stream), all on the MainActor.
        sessionTask = Task { @MainActor [weak self] in
            guard await AVAudioApplication.requestRecordPermission() else {
                self?.isRecording = false
                self?.sessionTask = nil
                self?.onPermissionDenied?()
                return
            }
            guard let self, !Task.isCancelled else {
                // [C9] A stop() during the permission prompt cancels us before the mic opens.
                self?.isRecording = false
                return
            }
            // startStreaming blocks until stopStreaming() or VAD auto-stop; throws (slot busy, engine force-closed) are
            // absorbed and reset below.
            try? await svc.startStreaming(owner: .quickAccess) { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.onTextChange?(self.baseText + state.fullText)
                }
            }
            // VAD auto-stop path: startStreaming returned on its own; live mirroring has
            // already delivered the text.
            self.isRecording = false
            self.sessionTask = nil
        }
    }

    func stop() {
        guard isRecording else { return }
        sessionTask?.cancel() // bail if we're still awaiting the mic-permission prompt
        sessionTask = nil
        isRecording = false
        let base = baseText
        Task { @MainActor [weak self] in
            let final = await WhisperRecognitionService.shared.stopStreaming()
            if let final, !final.isEmpty { self?.onTextChange?(base + final) }
            self?.onFinished?()
        }
    }

    /// [C4] Surface teardown (e.g. the QuickAccess panel closing mid-dictation): stop so the
    /// shared Whisper service doesn't keep the mic hot after the view is gone.
    func stopIfRecording() {
        if isRecording { stop() }
    }
}

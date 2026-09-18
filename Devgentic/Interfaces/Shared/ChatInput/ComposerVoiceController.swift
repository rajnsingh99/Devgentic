// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ComposerVoiceController.swift
//  Devgentic
//
//  Phase 2 of the unified composer: the reusable dictation behavior behind ComposerMicButton.
//  Owns the Whisper session lifecycle — synchronous re-entry guard, mic-permission request,
//  live transcript mirroring, VAD auto-stop, and teardown — so a surface gets voice input by
//  pairing this controller with ComposerMicButton and three callbacks, instead of embedding
//  ~80 lines of session logic in its view (which is where the QuickAccess panel's lived).
//
//  Per-instance BY DESIGN: create one per surface (@State in the owning view). It drives the
//  shared WhisperRecognitionService directly — the same engine the main composer uses — but
//  holds no global state itself. The main composer's ChatInputViewModel keeps its own richer
//  voice pipeline (VoiceInputState machine, model download/selection UX in DynamicActionButton);
//  migrating it onto this controller is the later per-instance-VM phase.
//
//  Provenance: extracted verbatim-in-behavior from QuickAccessContentView's
//  startDictation/stopDictation, preserving the C9 fix (sync re-entry guard; one @MainActor
//  task; cancellation covers a stop during the permission prompt) and supporting the C4 fix
//  (stopIfRecording() on view disappear so the mic never stays hot).
//

import SwiftUI
import AVFoundation

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
        // [C9] Re-entry guard: flip isRecording SYNCHRONOUSLY (callers are MainActor button
        // actions) so a rapid second tap toggles to Stop instead of launching a second
        // concurrent Whisper session on the shared service.
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
            // startStreaming BLOCKS until stopStreaming() or VAD auto-stop. Throws are
            // deliberately absorbed here — [V2] busy (another surface holds the slot)
            // and [V1] unexpected-end (the service already forced the engine closed)
            // both land in the same reset below; the service logs the specifics.
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

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbVoiceOutput.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import AVFoundation

// Why: a long-lived AVSpeechSynthesizer holds a CoreAudio output context whose teardown races the mic start.
/// Private text-to-speech for the Orb HUD's short spoken phrases, independent of `SpeechService.shared`.
/// Honors the user's persisted voice and rate; one synthesizer per utterance, with `releaseAudio()` to force release.
@MainActor
final class OrbVoiceOutput: NSObject, AVSpeechSynthesizerDelegate {

    private var synthesizer: AVSpeechSynthesizer?

    /// When this output last let go of a synthesizer that had been speaking.
    /// The session controller reads it to wait longer before opening a Bluetooth microphone right after speech,
    /// since the headset must switch from playback to microphone mode first.
    private(set) var lastAudioReleasedAt: Date?
    private var completion: (() -> Void)?
    // Why: short phrases and answer narration must both use it: one plain synthesizer leaves an async teardown racing the mic.
    /// Used instead of `synthesizer` while the panel-scoped duplex engine is up and cancelling echo.
    private lazy var duplexSpeaker = OrbDuplexSpeaker()

    /// Correlation tag for the duplex log lines; the owner must set it (`OrbStreamingSpeaker` sets it on its speaker).
    /// An empty tag leaves those lines unattributable to a session.
    var correlationTag: String = "" {
        didSet { duplexSpeaker.correlationTag = correlationTag }
    }

    var isSpeaking: Bool { (synthesizer?.isSpeaking ?? false) || duplexSpeaker.isSpeaking }

    /// Speaks a short phrase; `completion` fires on the main actor when playback
    /// finishes naturally. A new `speak` or a `stop` cancels the pending completion
    /// (it will never fire for the interrupted phrase).
    func speak(_ text: String, completion: (() -> Void)? = nil) {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion?()
            return
        }
        self.completion = completion

        if let target = OrbDuplexAudio.shared.playbackTarget {
            duplexSpeaker.enqueue(trimmed, on: target.player, engineFormat: target.format) { [weak self] in
                guard let self else { return }
                let pending = self.completion
                self.completion = nil
                pending?()
            }
            return
        }

        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        self.synthesizer = synthesizer

        let utterance = AVSpeechUtterance(string: trimmed)
        Self.applyVoiceSettings(to: utterance)
        synthesizer.speak(utterance)
    }

    // Why: an empty Orb voice falls back to the Read-Aloud voice; keep it for users who never choose an Orb voice.
    /// Applies the user's Orb voice and rate to an utterance.
    /// Shared with `OrbStreamingSpeaker` so the greeting, the answer and the completion phrase never drift apart.
    static func applyVoiceSettings(to utterance: AVSpeechUtterance) {
        let config = OrbConfigManager.shared
        let readAloudRate = TestHost.defaults.float(forKey: AppSettings.speechPlaybackRateKey)
        let multiplier = config.narratorRate > 0
            ? config.narratorRate
            : (readAloudRate > 0 ? readAloudRate : 1.0)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * multiplier

        let voiceID: String? = config.usesReadAloudVoice
            ? TestHost.defaults.string(forKey: AppSettings.speechPlaybackVoiceKey)
            : config.narratorVoiceID
        if let voiceID, let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        }
    }

    /// Stops any in-flight phrase and drops the pending completion.
    func stop() {
        completion = nil
        if let synthesizer, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        duplexSpeaker.cancel()
        releaseAudio()
    }

    /// Drops the synthesizer so its audio unit is deallocated. Called before opening
    /// the microphone so the two never hold CoreAudio at the same time.
    func releaseAudio() {
        if synthesizer != nil { lastAudioReleasedAt = Date() }
        synthesizer?.delegate = nil
        synthesizer = nil
        // Releases the duplex synthesizer only: the engine is panel-scoped and shared with capture, so tearing it down here
        // would rebuild voice processing before every turn.
        duplexSpeaker.releaseAudio()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let pending = self.completion
            self.completion = nil
            // Release BEFORE handing control back: the completion typically starts the
            // listening loop, and the synthesizer must be gone by then.
            self.releaseAudio()
            pending?()
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbVoiceOutput.swift
//  Devgentic
//
//  [Orb MVP] Private text-to-speech for the HUD's short spoken phrases.
//
//  Deliberately NOT SpeechService.shared: the shared singleton drives chat-side UI
//  (SpeechControlIsland appears over the chat history, spacebar/arrow shortcuts arm
//  while it is active) and any chat "Read Aloud" would hard-cancel an Orb phrase
//  mid-sentence. A private synthesizer keeps the overlay acoustically independent
//  while still honoring the user's persisted voice + rate preferences.
//
//  ⚠️ The synthesizer is created PER UTTERANCE and released as soon as it finishes.
//  A long-lived AVSpeechSynthesizer holds a CoreAudio output context open, and its
//  asynchronous teardown then races the microphone's AVAudioEngine start — which the
//  HAL rejects (`throwing -10877`, `_StartIO ... error 35`), leaving a silently dead
//  mic. Holding it only for the duration of a phrase keeps that window as small as
//  possible; `releaseAudio()` lets the caller force the release before recording.
//

import AVFoundation

@MainActor
final class OrbVoiceOutput: NSObject, AVSpeechSynthesizerDelegate {

    private var synthesizer: AVSpeechSynthesizer?

    /// When this output last let go of a synthesizer that had been speaking. The session controller
    /// reads it to wait longer before opening a BLUETOOTH microphone right after speech: the headset
    /// has to switch from its playback mode to its microphone mode first (device test 2026-10-10).
    private(set) var lastAudioReleasedAt: Date?
    private var completion: (() -> Void)?
    /// [Phase 4b] Used INSTEAD of `synthesizer` while the panel-scoped duplex engine is up and
    /// cancelling echo. ⚠️ Both short phrases and the answer narration must go through it: leave
    /// ONE plain synthesizer in the session and its asynchronous audio-unit teardown still races
    /// the microphone, so `audioSettleDelay` could never be removed.
    private lazy var duplexSpeaker = OrbDuplexSpeaker()

    /// ⚠️ Must be set by the owner. `OrbStreamingSpeaker` sets it on its speaker and this one
    /// did not, so every duplex line for the greeting, the approval prompt, the completion phrase
    /// and "Starting fresh" printed with an EMPTY correlation tag — unattributable to a session in
    /// exactly the log a device test reads.
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

    /// Applies the user's Orb voice and rate to an utterance.
    ///
    /// Shared with `OrbStreamingSpeaker` so the greeting, the answer and the completion phrase
    /// cannot drift apart — a narration that changes voice halfway through an answer is worse
    /// than one that never speaks.
    ///
    /// ⚠️ The Read-Aloud fallback IS the pre-settings behaviour and must stay. Orb used to read
    /// the Read-Aloud keys directly, so picking a voice for reading a chat message silently
    /// changed the assistant's voice too. The empty-string sentinel keeps that coupling for
    /// anyone who never chooses an Orb voice, and breaks it the moment they do.
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
        // ⚠️ Releases the duplex SYNTHESIZER only. The engine itself is panel-scoped and shared
        // with capture — tearing it down here would rebuild voice processing before every turn,
        // which is precisely the failure this phase removed.
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

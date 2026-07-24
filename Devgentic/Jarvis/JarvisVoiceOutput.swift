//
//  JarvisVoiceOutput.swift
//  Devgentic
//
//  [Jarvis MVP] Private text-to-speech for the HUD's short spoken phrases.
//
//  Deliberately NOT SpeechService.shared: the shared singleton drives chat-side UI
//  (SpeechControlIsland appears over the chat history, spacebar/arrow shortcuts arm
//  while it is active) and any chat "Read Aloud" would hard-cancel a Jarvis phrase
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
final class JarvisVoiceOutput: NSObject, AVSpeechSynthesizerDelegate {

    private var synthesizer: AVSpeechSynthesizer?
    private var completion: (() -> Void)?

    var isSpeaking: Bool { synthesizer?.isSpeaking ?? false }

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

        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        self.synthesizer = synthesizer

        let utterance = AVSpeechUtterance(string: trimmed)
        // Match the chat Read-Aloud preferences so Jarvis speaks with the same voice.
        let multiplier = UserDefaults.standard.float(forKey: AppSettings.speechPlaybackRateKey)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * (multiplier > 0 ? multiplier : 1.0)
        if let voiceID = UserDefaults.standard.string(forKey: AppSettings.speechPlaybackVoiceKey),
           let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    /// Stops any in-flight phrase and drops the pending completion.
    func stop() {
        completion = nil
        if let synthesizer, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        releaseAudio()
    }

    /// Drops the synthesizer so its audio unit is deallocated. Called before opening
    /// the microphone so the two never hold CoreAudio at the same time.
    func releaseAudio() {
        synthesizer?.delegate = nil
        synthesizer = nil
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

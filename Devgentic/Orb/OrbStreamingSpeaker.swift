// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbStreamingSpeaker.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import AVFoundation
import Observation

// Why: one synthesizer per answer, not per phrase: a per-sentence audio-graph build leaves audible gaps;
// it is released once when the answer drains.
/// Speaks the assistant's answer as it streams, through one synthesizer for the whole answer.
/// Consumption is tracked as a UTF-16 offset plus a text carry, so an incomplete sentence is never spoken half-formed.
/// Agent (ReAct) profiles emit the whole answer as one `.content` event, so they speak on completion.
@MainActor
final class OrbStreamingSpeaker: NSObject, AVSpeechSynthesizerDelegate {

    /// Spoken in place of a code block. A voice assistant must never read a fence aloud.
    static let codeAnnouncement = "There's a code block in the chat window."
    /// Spoken when `.automatic` stops early because the answer is long.
    static let truncationNotice = "There's more in the chat window."

    private let logger = DGLogger(category: "OrbSpeaker")
    /// Correlation prefix handed over by the session controller so speaker lines interleave
    /// readably with the rest of a turn in the log.
    var correlationTag: String = ""

    private var synthesizer: AVSpeechSynthesizer?

    /// When this output last let go of a synthesizer that had been speaking.
    /// Read by the session controller to wait longer before opening a Bluetooth mic after speech (headset mode switch).
    private(set) var lastAudioReleasedAt: Date?
    /// Used INSTEAD of `synthesizer` whenever the duplex engine is up and actually cancelling
    /// echo. Routing the answer through the app's own engine is what gives echo cancellation a
    /// reference signal to subtract — the prerequisite for hearing the user over Orb's voice.
    private lazy var duplexSpeaker = OrbDuplexSpeaker()
    private var observedMessageID: UUID?

    /// How much of the cumulative `content` has been ingested.
    private var consumedUTF16 = 0
    /// Ingested text not yet spoken — an unterminated sentence, or the body of an open fence.
    private var carry = ""
    private var fenceOpen = false

    private var enqueuedCount = 0
    private var finishedCount = 0
    /// Sentences spoken by the current narration pass; drives the sentence cap and the completion log.
    /// Private and named for the pass, not the answer: it is not the offset for "tell me more" (see `sentencesHeard`).
    private var sentencesThisPass = 0

    // Why: using the per-pass counter as the drop offset re-cuts the second "tell me more" from the middle.
    /// Sentences of the current answer the user has heard, across the narration and every "tell me more".
    /// The offset "tell me more" cuts from: an index into `cut(answer).segments`, so closing phrases are not counted.
    /// Separate from `sentencesThisPass`, which `reset()` zeroes before each remainder.
    private(set) var sentencesHeard = 0
    private var truncated = false
    /// Set while speaking a remainder, so the cap that held the text back cannot hold it back
    /// again — the user has explicitly asked for the rest.
    private var capBypass = false
    /// True once the run is over and no more text will arrive.
    private var sourceFinished = false
    private var cancelled = false
    /// False when spoken responses are off. Checked on every ingest, not just at `begin`:
    /// without it, silent mode still reached `enqueue`, hit the zero sentence cap, and spoke
    /// the truncation notice — the one phrase the user explicitly asked not to hear.
    private var narrationEnabled = false
    /// Suppresses the drain check while `finish` is still assembling the final utterances —
    /// otherwise flushing the tail could hand back before the closing phrase is even queued.
    private var readyToDrain = false
    /// Deadlock breaker: the same hazard `speakWithWatchdog` fixed for the fixed phrases.
    /// A synthesizer that never fires `didFinish` would park the stage machine with the
    /// microphone closed and no in-UI recovery.
    private var drainWatchdog: Task<Void, Never>?
    private static let utteranceTimeout: TimeInterval = 30

    /// Fires on the main actor when the last queued utterance finishes AND no more text is
    /// coming. Nil until `sourceDidFinish()` decides a hand-back is owed.
    var onDrained: (() -> Void)?

    /// Whether anything is queued or playing.
    var isSpeaking: Bool { enqueuedCount > finishedCount }
    /// Whether this speaker ever produced audio for the current answer.
    var didSpeak: Bool { enqueuedCount > 0 }

    // MARK: - Lifecycle

    /// Starts narrating `message` as it streams.
    func begin(for message: ChatMessage) {
        reset()
        // The one place this is cleared: `reset()` preserves it so a remainder keeps counting; only a new answer zeroes it.
        sentencesHeard = 0
        narrationEnabled = OrbConfigManager.shared.spokenResponses.speaksAnswer
        guard narrationEnabled else {
            logger.info("[ORB_TTS]\(self.correlationTag) Spoken responses are off — the answer will not be narrated. CONSEQUENCE: the run still announces its outcome, and the text is in the chat window.")
            return
        }
        // Whether barge-in is reachable: interrupting Orb needs the microphone open while it speaks, which needs echo
        // cancellation with its voice as reference, which needs the answer rendered through the shared engine.
        if OrbDuplexAudio.shared.isEchoCancelling {
            logger.notice("[ORB_TTS]\(self.correlationTag) Narrating through the SHARED echo-cancelling engine — Orb's voice is now an AEC reference signal, so the microphone no longer has to close while he speaks.")
        } else {
            logger.info("[ORB_TTS]\(self.correlationTag) Narrating through a private synthesiser (no echo cancellation). CONSEQUENCE: the microphone stays closed until the answer finishes; barge-in is unavailable.")
        }
        // Two synthesizers must never hold CoreAudio at once: the chat Read-Aloud island owns a long-lived one, and
        // its teardown racing this engine causes the dead-mic condition.
        SpeechService.shared.stop()
        // The converse of `stop()`, which takes the floor from Read Aloud: this is how Read Aloud takes it back, so this
        // driver stops ingesting the answer and queueing utterances.
        SpeechService.shared.registerExternalNarration(owner: self) { [weak self] in self?.cancel() }
        observedMessageID = message.id
        logger.info("[ORB_TTS]\(self.correlationTag) Narrating message \(message.id.uuidString.prefix(8)) — mode \(OrbConfigManager.shared.spokenResponses.rawValue).")
        observe(message)
        ingest(message)
    }

    /// The run is over: flushes remaining text, optionally appends a closing phrase, then calls `onDrained` when played.
    /// Returns false when there is nothing to narrate (silent mode, empty answer or all code); the caller then announces the
    /// outcome itself so a voice-only user is never left with silence.
    @discardableResult
    func finish(for message: ChatMessage?,
                appending closing: String?,
                onDrained: @escaping () -> Void) -> Bool {
        guard narrationEnabled, !cancelled else { return false }
        sourceFinished = true
        readyToDrain = false
        if let message { ingest(message) }
        guard didSpeak else {
            readyToDrain = true
            return false
        }
        // `enqueueAside`, not `enqueue`: the caveat is about the run, not part of the answer.
        if let closing { enqueueAside(closing) }
        self.onDrained = onDrained
        readyToDrain = true
        armDrainWatchdog()
        drainIfComplete()
        return true
    }

    /// Whether the cap held anything back from the last answer — i.e. whether "tell me more" has
    /// anything to say.
    var heldSomethingBack: Bool { truncated }

    /// Speaks the part of `message` the cap held back; returns false when nothing is left.
    /// Re-segments the finished answer and drops already-spoken sentences; narration consumed the streamed text.
    @discardableResult
    func speakRemainder(of message: ChatMessage, onDrained: @escaping () -> Void) -> Bool {
        let full = message.currentAgentContent?.textContent ?? ""
        // `sentencesHeard`, never `sentencesThisPass`: the per-pass counter is zeroed by the `reset()` below, so after one
        // remainder it describes that remainder and cutting from it replays the middle of the answer.
        let alreadyHeard = sentencesHeard
        let remaining = Self.remainingSentences(of: full, alreadyHeard: alreadyHeard)
        guard !remaining.isEmpty else {
            logger.info("[ORB_TTS]\(self.correlationTag) Nothing held back — all \(alreadyHeard) sentence(s) of this answer were already spoken. CONSEQUENCE: the caller says so rather than replaying the answer.")
            return false
        }

        // `reset()` preserves `sentencesHeard`, so the count keeps accumulating across this pass and every later one.
        reset()
        narrationEnabled = true
        capBypass = true
        sourceFinished = true
        readyToDrain = false
        for segment in remaining { enqueue(segment) }
        self.onDrained = onDrained
        readyToDrain = true
        logger.notice("[ORB_TTS]\(self.correlationTag) Speaking the remaining \(remaining.count) sentence(s) on request (\(alreadyHeard) already heard, \(self.sentencesHeard) of this answer once this pass drains). CONSEQUENCE: the cap is bypassed for this narration only, and a further \"tell me more\" will correctly find nothing left.")
        armDrainWatchdog()
        drainIfComplete()
        return true
    }

    /// Stops immediately and drops the hand-back. Used for barge-in and for a failed run,
    /// where narrating a partial answer would be worse than saying what happened.
    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        // Release the floor claim so a stale closure cannot make the next Read Aloud cancel a speaker that already finished.
        SpeechService.shared.releaseExternalNarrationCanceller(ifOwnedBy: self)
        observedMessageID = nil
        onDrained = nil
        drainWatchdog?.cancel()
        drainWatchdog = nil
        if let synthesizer, synthesizer.isSpeaking {
            // `.word` rather than `.immediate`: it finishes the syllable in flight, which sounds
            // like an interruption rather than a fault.
            synthesizer.stopSpeaking(at: .word)
        }
        duplexSpeaker.cancel()
        releaseAudio()
        // Only log if there was something to cancel: `cancel()` runs on every teardown, profile switch and stop, so an
        // unconditional line is noise in the log.
        if didSpeak {
            logger.info("[ORB_TTS]\(self.correlationTag) Narration cancelled after \(self.sentencesThisPass) sentence(s).")
        }
    }

    /// Drops the synthesizer so its audio unit is deallocated before the microphone opens.
    func releaseAudio() {
        SpeechService.shared.releaseExternalNarrationCanceller(ifOwnedBy: self)
        if synthesizer != nil { lastAudioReleasedAt = Date() }
        synthesizer?.delegate = nil
        synthesizer = nil
        // Release only the synthesizer, never the engine: the engine is panel-scoped and shared with capture, and rebuilding
        // voice processing on every turn is the failure to avoid.
        duplexSpeaker.releaseAudio()
    }

    private func reset() {
        cancelled = false
        narrationEnabled = false
        sourceFinished = false
        truncated = false
        consumedUTF16 = 0
        carry = ""
        fenceOpen = false
        enqueuedCount = 0
        finishedCount = 0
        sentencesThisPass = 0
        // `sentencesHeard` is not cleared here: `speakRemainder` calls this between passes over the same answer, so only
        // `begin(for:)` clears it, because only a new answer resets what has been heard.
        onDrained = nil
        readyToDrain = false
        capBypass = false
        drainWatchdog?.cancel()
        drainWatchdog = nil
    }

    /// Restarted on every utterance boundary: a stalled synthesizer hands back rather than
    /// parking the stage machine forever.
    private func armDrainWatchdog() {
        drainWatchdog?.cancel()
        drainWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.utteranceTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled, self.onDrained != nil else { return }
            // Report the real counts: forcing them equal would print "6 of 6" and mask a defect where only the first
            // sentence was spoken.
            self.logger.error("[ORB_TTS]\(self.correlationTag) Narration STALLED — only \(self.finishedCount) of \(self.enqueuedCount) utterance(s) reached the speakers within \(Int(Self.utteranceTimeout))s. Handing back anyway. CONSEQUENCE: the rest of the answer is NOT spoken (it is still in the chat window); without this hand-back the orb would stay on COMPLETE with the microphone closed until the panel is closed.")
            self.finishedCount = self.enqueuedCount
            self.drainIfComplete()
        }
    }

    // MARK: - Observation

    /// Re-arms `withObservationTracking`, structurally copied from RemoteMirrorService.
    /// Re-arms before doing the work: tracking is one-shot, so text landing mid-work would wait for the next change.
    private func observe(_ message: ChatMessage) {
        withObservationTracking {
            _ = message.content
            _ = message.isStreaming
        } onChange: {
            Task { @MainActor [weak self, weak message] in
                guard let self, let message, !self.cancelled else { return }
                guard self.observedMessageID == message.id else { return }
                self.observe(message)
                self.ingest(message)
            }
        }
    }

    // MARK: - Ingest

    private func ingest(_ message: ChatMessage) {
        guard narrationEnabled, !cancelled, !truncated else { return }
        let text = message.content.textContent ?? ""

        // Content can shrink: a mid-run error replaces the accumulated answer with the error chunk; without this check
        // `remainder` would return the whole new text and re-speak from the top.
        if text.utf16.count < consumedUTF16 {
            logger.warning("[ORB_TTS]\(self.correlationTag) Answer text shrank (\(self.consumedUTF16) → \(text.utf16.count) UTF-16 units) — resetting the read cursor. CONSEQUENCE: the replacement text is narrated once, not appended to what was already spoken.")
            consumedUTF16 = text.utf16.count
            carry = ""
            return
        }

        let delta = SpeechService.remainder(of: text, spokenUpTo: consumedUTF16)
        consumedUTF16 = text.utf16.count
        guard !delta.isEmpty || sourceFinished else { return }

        carry += delta
        let isFinal = sourceFinished || !message.isStreaming
        let result = Self.cut(carry, fenceOpen: fenceOpen, isFinal: isFinal)
        carry = result.remainder
        fenceOpen = result.fenceOpen

        for segment in result.segments {
            guard !truncated else { break }
            enqueue(segment)
        }
        if isFinal { drainIfComplete() }
    }

    // MARK: - Speaking

    private func enqueue(_ phrase: String) {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !capBypass, let cap = OrbConfigManager.shared.spokenResponses.sentenceCap, sentencesThisPass >= cap {
            // A zero cap means "say nothing at all" — the hand-off notice would itself be speech
            // the user turned off.
            guard cap > 0 else { truncated = true; return }
            // Say so rather than trailing off — a narration that just stops sounds like a fault.
            truncated = true
            logger.info("[ORB_TTS]\(self.correlationTag) Sentence cap (\(cap)) reached — narrating the hand-off instead of the rest.")
            speak(Self.truncationNotice)
            return
        }

        sentencesThisPass += 1
        // Both counters advance together for answer text; only this one survives `reset()`.
        sentencesHeard += 1
        speak(trimmed)
    }

    /// Speaks a phrase that is not part of the answer, such as the closing outcome caveat.
    /// Bypasses the sentence cap (the caveat must not be suppressed by it) and `sentencesHeard` (which indexes the answer's
    /// own segments, so counting an appended phrase would make "tell me more" skip a real sentence).
    private func enqueueAside(_ phrase: String) {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speak(trimmed)
    }

    private func speak(_ text: String) {
        // Decided per sentence, not per answer: the engine can downgrade itself mid-answer
        // (`OrbAudioProcessor.recoverIfTapIsDead`), and a narrator pinned to a vanished path would go silent.
        if let target = OrbDuplexAudio.shared.playbackTarget {
            duplexSpeaker.correlationTag = correlationTag
            enqueuedCount += 1
            duplexSpeaker.enqueue(text, on: target.player, engineFormat: target.format) { [weak self] in
                guard let self else { return }
                self.finishedCount += 1
                if self.onDrained != nil { self.armDrainWatchdog() }
                self.drainIfComplete()
            }
            return
        }

        // The engine went away mid-answer: queued duplex renders would play over the private synthesizer, so abandon them
        // and credit them here, since their completions never arrive and the drain could not otherwise balance.
        if duplexSpeaker.isSpeaking {
            let abandoned = enqueuedCount - finishedCount
            logger.error("[ORB_TTS]\(self.correlationTag) The shared audio engine stopped cancelling echo mid-answer — falling back to a private synthesiser with \(abandoned) sentence(s) still queued on the old path. CONSEQUENCE: those \(abandoned) sentence(s) are DROPPED rather than played over the top of what follows; the rest of the answer is spoken without echo cancellation, so barge-in is unavailable for the remainder of this turn.")
            duplexSpeaker.cancel()
            finishedCount = enqueuedCount
        }

        let synth: AVSpeechSynthesizer
        if let existing = synthesizer {
            synth = existing
        } else {
            synth = AVSpeechSynthesizer()
            synth.delegate = self
            synthesizer = synth
        }
        let utterance = AVSpeechUtterance(string: text)
        OrbVoiceOutput.applyVoiceSettings(to: utterance)
        // A little air between sentences: AVFoundation's queue otherwise runs them together.
        utterance.postUtteranceDelay = 0.12
        enqueuedCount += 1
        synth.speak(utterance)
    }

    private func drainIfComplete() {
        guard sourceFinished, readyToDrain, !cancelled, enqueuedCount == finishedCount else { return }
        drainWatchdog?.cancel()
        drainWatchdog = nil
        let handBack = onDrained
        onDrained = nil
        releaseAudio()
        // Log both counts: `sentencesThisPass` increments at enqueue and may overstate what reached the speakers, while
        // `finishedCount` tracks what was heard. A remainder pass is shorter than the total heard, so name the difference.
        let heardSuffix = sentencesHeard == sentencesThisPass ? "" : " (\(sentencesHeard) of this answer heard in total)"
        logger.info("[ORB_TTS]\(self.correlationTag) Narration complete — \(self.finishedCount) of \(self.enqueuedCount) utterance(s) reached the speakers across \(self.sentencesThisPass) sentence(s)\(heardSuffix)\(self.truncated ? ", truncated" : "").")
        handBack?()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finishedCount += 1
            if self.onDrained != nil { self.armDrainWatchdog() }
            self.drainIfComplete()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // Cancelled utterances still have to be counted, or a later drain check never balances
            // and the stage machine waits forever for audio that will never play.
            self.finishedCount += 1
        }
    }
}

// MARK: - Segmentation (pure)

extension OrbStreamingSpeaker {

    /// The sentences of a finished `answer` that have not been read to the user yet.
    /// Pure; re-segments the completed answer with the same `cut` the narration used and drops what was already heard.
    /// `alreadyHeard` must count answer segments only; a per-pass count or a closing phrase yields the wrong slice.
    static func remainingSentences(of answer: String, alreadyHeard: Int) -> [String] {
        guard alreadyHeard >= 0 else { return [] }
        let segments = cut(answer, fenceOpen: false, isFinal: true).segments
        guard alreadyHeard < segments.count else { return [] }
        return Array(segments.dropFirst(alreadyHeard))
    }

    /// Cuts streaming text into speakable sentences, returning ready segments, the carry to re-offer and the fence state.
    /// Lines inside a ``` fence are consumed and replaced by one spoken announcement.
    /// Prose is emitted only up to its last complete sentence unless `isFinal`, so nothing is spoken twice or half-formed.
    static func cut(_ text: String,
                    fenceOpen: Bool,
                    isFinal: Bool) -> (segments: [String], remainder: String, fenceOpen: Bool) {
        var segments: [String] = []
        var fence = fenceOpen
        var prose = ""
        var sawCode = false
        var cursor = text.startIndex

        func flushProse(force: Bool) {
            let cutIndex = force ? prose.endIndex : lastSentenceBoundary(in: prose)
            guard cutIndex > prose.startIndex else { return }
            let speakable = String(prose[..<cutIndex])
            prose = String(prose[cutIndex...])
            for sentence in sentences(in: speakable) {
                let cleaned = cleanForSpeech(sentence)
                if !cleaned.isEmpty { segments.append(cleaned) }
            }
        }

        while cursor < text.endIndex {
            let newline = text[cursor...].firstIndex(of: "\n")
            // An unterminated last line might still be growing — leave it for the next pass.
            if newline == nil && !isFinal { break }
            let lineEnd = newline ?? text.endIndex
            let line = String(text[cursor..<lineEnd])
            cursor = newline.map { text.index(after: $0) } ?? text.endIndex

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushProse(force: true)
                if fence {
                    fence = false
                    if sawCode { segments.append(codeAnnouncement) }
                    sawCode = false
                } else {
                    fence = true
                }
                continue
            }
            if fence {
                if !trimmed.isEmpty { sawCode = true }
                continue
            }
            prose += line + " "
            flushProse(force: false)
        }

        if isFinal {
            flushProse(force: true)
            // An answer that ends mid-fence still owes the announcement.
            if fence && sawCode { segments.append(codeAnnouncement) }
        }

        let tail = String(text[cursor...])
        let leftover = prose.trimmingCharacters(in: .whitespaces)
        let remainder: String
        if leftover.isEmpty {
            remainder = tail
        } else if tail.isEmpty {
            remainder = leftover
        } else {
            remainder = leftover + "\n" + tail
        }
        return (segments, remainder, fence)
    }

    /// Index just past the last sentence terminator followed by whitespace or end-of-string.
    static func lastSentenceBoundary(in text: String) -> String.Index {
        var boundary = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "." || character == "!" || character == "?" {
                let next = text.index(after: index)
                if next == text.endIndex || text[next].isWhitespace {
                    boundary = next
                }
            }
            index = text.index(after: index)
        }
        return boundary
    }

    /// Splits already-terminated text into sentences.
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { substring, _, _, _ in
            if let substring {
                let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
            }
        }
        return result.isEmpty ? [text.trimmingCharacters(in: .whitespacesAndNewlines)] : result
    }

    // Why: SpeechService's cleaner collapses `_…_` as emphasis and corrupts identifiers;
    // under-stripping is far cheaper than corrupting a symbol.
    /// Strips the markdown a voice must not pronounce.
    /// Leaves underscores alone, so identifiers like `spotlight_search` are pronounced intact.
    static func cleanForSpeech(_ line: String) -> String {
        var cleaned = line.trimmingCharacters(in: .whitespaces)
        // Headings, blockquotes and list bullets are structure, not words.
        cleaned = cleaned.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^>\\s*", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^[-*+]\\s+", with: "", options: .regularExpression)
        // Emphasis and inline code: keep the words, drop the punctuation carrying them.
        cleaned = cleaned.replacingOccurrences(of: "\\*{1,3}([^*]+)\\*{1,3}", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        // A spoken URL is noise; the link text is the meaning.
        cleaned = cleaned.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}

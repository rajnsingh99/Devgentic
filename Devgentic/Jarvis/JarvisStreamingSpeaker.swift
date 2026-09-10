// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  JarvisStreamingSpeaker.swift
//  Devgentic
//
//  [Phase 1] Speaks the assistant's answer as it streams. This is the piece that makes Jarvis
//  a voice ASSISTANT rather than a hands-free way to type: before it, the reply existed as a
//  live ChatMessage the controller already held and simply never read aloud.
//
//  Design notes that are load-bearing:
//
//  • ONE synthesizer for a whole answer, not one per phrase. JarvisVoiceOutput creates and
//    destroys a synthesizer per utterance to keep the CoreAudio window small (see its header
//    and the -10877 / _StartIO race). That is right for two short phrases and wrong for a
//    twenty-sentence answer: it would pay a full audio-graph build per sentence and leave
//    audible gaps. Instead this owns one synthesizer for the answer, uses AVFoundation's own
//    utterance queue, and releases it ONCE when the answer drains — so the existing
//    releaseAudio() + audioSettleDelay handshake runs once per turn instead of once per phrase.
//
//  • Consumption is tracked as a UTF-16 offset plus a text CARRY, not by re-parsing the answer.
//    `content` is cumulative (resolveStreamedChunkMerge writes the whole string back), so each
//    pass takes only the new tail. Text that is not yet a complete sentence stays in `carry`
//    and is re-offered next pass — that is what stops a sentence being spoken half-formed.
//
//  • ⚠️ Agent (ReAct) profiles emit their entire answer as ONE `.content` event, so for them
//    this degrades to speak-on-completion rather than speak-as-it-generates. That is correct
//    behaviour, not a bug here — the fix belongs in ReActAgentExecutor, which does not stream
//    its final synthesized answer.
//

import Foundation
import AVFoundation
import Observation

@MainActor
final class JarvisStreamingSpeaker: NSObject, AVSpeechSynthesizerDelegate {

    /// Spoken in place of a code block. A voice assistant must never read a fence aloud.
    static let codeAnnouncement = "There's a code block in the chat window."
    /// Spoken when `.automatic` stops early because the answer is long.
    static let truncationNotice = "There's more in the chat window."

    private let logger = DGLogger(category: "JarvisSpeaker")
    /// Correlation prefix handed over by the session controller so speaker lines interleave
    /// readably with the rest of a turn in the log.
    var correlationTag: String = ""

    private var synthesizer: AVSpeechSynthesizer?
    /// Used INSTEAD of `synthesizer` whenever the duplex engine is up and actually cancelling
    /// echo. Routing the answer through the app's own engine is what gives echo cancellation a
    /// reference signal to subtract — the prerequisite for hearing the user over Jarvis's voice.
    private lazy var duplexSpeaker = JarvisDuplexSpeaker()
    private var observedMessageID: UUID?

    /// How much of the cumulative `content` has been ingested.
    private var consumedUTF16 = 0
    /// Ingested text not yet spoken — an unterminated sentence, or the body of an open fence.
    private var carry = ""
    private var fenceOpen = false

    private var enqueuedCount = 0
    private var finishedCount = 0
    /// Sentences spoken by the CURRENT narration pass. Drives the sentence cap and the completion
    /// log — both of which are per-pass questions.
    ///
    /// ⚠️ `private`, and named for the pass rather than for the answer, ON PURPOSE. Read as
    /// "sentences spoken" it looks like the right offset for "tell me more"; it is not, and that
    /// misreading is exactly the defect `sentencesHeard` below was added to fix. The name is the
    /// guard the tests cannot be: `let alreadyHeard = sentencesThisPass` reads as wrong.
    private var sentencesThisPass = 0

    /// Sentences of the current ANSWER the user has actually heard, across the original narration
    /// and every "tell me more" after it. This is the offset "tell me more" cuts from.
    ///
    /// ⚠️⚠️ SEPARATE FROM `sentencesThisPass`, AND THE SEPARATION IS THE ENTIRE POINT.
    /// `speakRemainder` calls `reset()` before re-enqueueing, so once one remainder has played the
    /// per-pass counter holds the length of *that remainder*, not of everything heard. Using it as
    /// the drop-offset made the SECOND "tell me more" re-cut from the middle: on a ten-sentence
    /// answer in gist mode the user heard 1–2, then 3–10, then **9–10 again** — and was never told
    /// the answer had finished, because the "nothing left" branch became unreachable for any
    /// answer longer than its own remainder.
    ///
    /// ⚠️ It counts ONLY segments of the answer, which is why an appended closing phrase goes
    /// through `enqueueAside`. It is an index into `cut(answer).segments`; anything counted here
    /// that is not in that list makes the remainder skip a real sentence.
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
        // ⚠️ The ONE place this is cleared — `reset()` deliberately preserves it so a remainder can
        // keep counting. A new answer is the only thing that makes "what has been heard" zero again.
        sentencesHeard = 0
        narrationEnabled = JarvisConfigManager.shared.spokenResponses.speaksAnswer
        guard narrationEnabled else {
            logger.info("[JARVIS_TTS]\(self.correlationTag) Spoken responses are off — the answer will not be narrated. CONSEQUENCE: the run still announces its outcome, and the text is in the chat window.")
            return
        }
        // ⚠️ THE LINE THAT SAYS WHETHER BARGE-IN IS REACHABLE. Interrupting Jarvis requires the
        // microphone to stay open while he speaks, which requires echo cancellation to have his
        // voice as a reference signal — which requires this answer to render through the shared
        // engine. Anything else and the microphone must stay closed.
        if JarvisDuplexAudio.shared.isEchoCancelling {
            logger.notice("[JARVIS_TTS]\(self.correlationTag) Narrating through the SHARED echo-cancelling engine — Jarvis's voice is now an AEC reference signal, so the microphone no longer has to close while he speaks.")
        } else {
            logger.info("[JARVIS_TTS]\(self.correlationTag) Narrating through a private synthesiser (no echo cancellation). CONSEQUENCE: the microphone stays closed until the answer finishes; barge-in is unavailable.")
        }
        // ⚠️ Two synthesizers must never hold CoreAudio at once: the chat Read-Aloud island owns
        // a long-lived one, and its teardown racing our engine is the documented dead-mic bug.
        SpeechService.shared.stop()
        observedMessageID = message.id
        logger.info("[JARVIS_TTS]\(self.correlationTag) Narrating message \(message.id.uuidString.prefix(8)) — mode \(JarvisConfigManager.shared.spokenResponses.rawValue).")
        observe(message)
        ingest(message)
    }

    /// The run is over. Flushes whatever text is left, optionally appends a closing phrase, and
    /// calls `onDrained` once the last utterance has played.
    ///
    /// Returns FALSE when there is nothing to narrate — a silent mode, an empty answer, or an
    /// answer that was all code. The caller must then announce the outcome itself, so a
    /// voice-only user is never left with silence at the end of a run.
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
        // ⚠️ `enqueueAside`, not `enqueue` — the caveat is about the RUN, not part of the answer.
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

    /// Speaks the part of `message` the cap held back. Returns false when there is nothing left.
    ///
    /// ⚠️ Re-segments the FINISHED answer rather than replaying a buffer: the narration consumed
    /// the text while it was still streaming, so the only reliable way to name the remainder is to
    /// cut the completed text the same way and drop the sentences already spoken.
    @discardableResult
    func speakRemainder(of message: ChatMessage, onDrained: @escaping () -> Void) -> Bool {
        let full = message.currentAgentContent?.textContent ?? ""
        // ⚠️ `sentencesHeard`, NEVER `sentencesThisPass` — see the note on the property. The per-pass
        // counter is zeroed by the `reset()` below, so after one remainder it describes that
        // remainder rather than the answer, and cutting from it replays the middle of the answer.
        let alreadyHeard = sentencesHeard
        let remaining = Self.remainingSentences(of: full, alreadyHeard: alreadyHeard)
        guard !remaining.isEmpty else {
            logger.info("[JARVIS_TTS]\(self.correlationTag) Nothing held back — all \(alreadyHeard) sentence(s) of this answer were already spoken. CONSEQUENCE: the caller says so rather than replaying the answer.")
            return false
        }

        // ⚠️ `reset()` deliberately preserves `sentencesHeard`, so the count keeps accumulating
        // across this pass and every later one.
        reset()
        narrationEnabled = true
        capBypass = true
        sourceFinished = true
        readyToDrain = false
        for segment in remaining { enqueue(segment) }
        self.onDrained = onDrained
        readyToDrain = true
        logger.notice("[JARVIS_TTS]\(self.correlationTag) Speaking the remaining \(remaining.count) sentence(s) on request (\(alreadyHeard) already heard, \(self.sentencesHeard) of this answer once this pass drains). CONSEQUENCE: the cap is bypassed for this narration only, and a further \"tell me more\" will correctly find nothing left.")
        armDrainWatchdog()
        drainIfComplete()
        return true
    }

    /// Stops immediately and drops the hand-back. Used for barge-in and for a failed run,
    /// where narrating a partial answer would be worse than saying what happened.
    func cancel() {
        guard !cancelled else { return }
        cancelled = true
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
        // Only worth a line if there was something to cancel. `cancel()` runs on every teardown,
        // profile switch and stop, so logging unconditionally put a "Narration cancelled after 0
        // sentence(s)" in the log every time the panel closed — noise in the one surface that
        // exists for diagnosis.
        if didSpeak {
            logger.info("[JARVIS_TTS]\(self.correlationTag) Narration cancelled after \(self.sentencesThisPass) sentence(s).")
        }
    }

    /// Drops the synthesizer so its audio unit is deallocated before the microphone opens.
    func releaseAudio() {
        synthesizer?.delegate = nil
        synthesizer = nil
        // ⚠️ Only the SYNTHESIZER is released here, never the engine: the engine is panel-scoped
        // now and shared with capture. Tearing it down between answers would rebuild voice
        // processing on every turn, which is the exact failure this phase removed.
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
        // ⚠️ `sentencesHeard` is NOT cleared here, and that is deliberate. `speakRemainder` calls
        // this between passes over the SAME answer, so clearing it would lose the offset the next
        // "tell me more" cuts from — which is the defect this separation exists to fix. Only
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
            // ⚠️ Report the REAL counts. The old wording claimed nothing had completed, and then
            // forcing the counts equal made the completion line print "6 of 6" — which masked a
            // live defect where only the FIRST sentence was ever spoken. A watchdog that lies
            // about what it recovered from is worse than no watchdog.
            self.logger.error("[JARVIS_TTS]\(self.correlationTag) Narration STALLED — only \(self.finishedCount) of \(self.enqueuedCount) utterance(s) reached the speakers within \(Int(Self.utteranceTimeout))s. Handing back anyway. CONSEQUENCE: the rest of the answer is NOT spoken (it is still in the chat window); without this hand-back the orb would stay on COMPLETE with the microphone closed until the panel is closed.")
            self.finishedCount = self.enqueuedCount
            self.drainIfComplete()
        }
    }

    // MARK: - Observation

    /// Re-arming `withObservationTracking`, structurally copied from RemoteMirrorService.
    /// ⚠️ Re-arm BEFORE doing the work: tracking is one-shot, and text that lands during the
    /// work window would otherwise be observed only when the NEXT change happened to arrive.
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

        // ⚠️ Content can SHRINK: a mid-run error replaces the accumulated answer with the error
        // chunk. Without this, `remainder` would return the whole new text and the answer would
        // be re-spoken from the top.
        if text.utf16.count < consumedUTF16 {
            logger.warning("[JARVIS_TTS]\(self.correlationTag) Answer text shrank (\(self.consumedUTF16) → \(text.utf16.count) UTF-16 units) — resetting the read cursor. CONSEQUENCE: the replacement text is narrated once, not appended to what was already spoken.")
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

        if !capBypass, let cap = JarvisConfigManager.shared.spokenResponses.sentenceCap, sentencesThisPass >= cap {
            // A zero cap means "say nothing at all" — the hand-off notice would itself be speech
            // the user turned off.
            guard cap > 0 else { truncated = true; return }
            // Say so rather than trailing off — a narration that just stops sounds like a fault.
            truncated = true
            logger.info("[JARVIS_TTS]\(self.correlationTag) Sentence cap (\(cap)) reached — narrating the hand-off instead of the rest.")
            speak(Self.truncationNotice)
            return
        }

        sentencesThisPass += 1
        // Both counters advance together for answer text; only this one survives `reset()`.
        sentencesHeard += 1
        speak(trimmed)
    }

    /// Speaks a phrase that is NOT part of the answer — the closing outcome caveat, for instance.
    ///
    /// ⚠️ Bypasses BOTH the sentence cap and `sentencesHeard`, and needs to bypass each for its own
    /// reason. The cap bounds how much of the ANSWER is read, so a caveat about the run's outcome
    /// must not be suppressed by it — routed through `enqueue`, a capped run spoke the truncation
    /// notice a SECOND time in place of the caveat, so a `completedWithWarnings` run never told the
    /// user it had finished badly. And `sentencesHeard` indexes into the answer's own segments, so
    /// counting an appended phrase there made "tell me more" skip one real sentence.
    private func enqueueAside(_ phrase: String) {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speak(trimmed)
    }

    private func speak(_ text: String) {
        // ⚠️ Decided per sentence, not per answer. The engine can downgrade itself mid-answer
        // (see `JarvisAudioProcessor.recoverIfTapIsDead`), and a narrator pinned to a path that
        // stopped existing would go silent with no explanation.
        if let target = JarvisDuplexAudio.shared.playbackTarget {
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

        // ⚠️ [#12] THE ENGINE WENT AWAY MID-ANSWER. `playbackTarget` is re-read per sentence
        // precisely because the processor can rebuild itself without voice processing
        // (`recoverIfTapIsDead`), but nil-ing it only redirects the sentences that come AFTER:
        // whatever is already queued on the duplex speaker keeps playing on the shared engine
        // while this private synthesizer starts talking over it. Two voices, out of order, with
        // `drainIfComplete` reporting a clean finish because both paths increment the same counts.
        //
        // The queued renders are abandoned rather than awaited — their engine is the one that just
        // stopped, so their completions are never coming, and without crediting them here the
        // drain could never balance and the 30 s watchdog would end the turn.
        if duplexSpeaker.isSpeaking {
            let abandoned = enqueuedCount - finishedCount
            logger.error("[JARVIS_TTS]\(self.correlationTag) The shared audio engine stopped cancelling echo mid-answer — falling back to a private synthesiser with \(abandoned) sentence(s) still queued on the old path. CONSEQUENCE: those \(abandoned) sentence(s) are DROPPED rather than played over the top of what follows; the rest of the answer is spoken without echo cancellation, so barge-in is unavailable for the remainder of this turn.")
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
        JarvisVoiceOutput.applyVoiceSettings(to: utterance)
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
        // ⚠️ BOTH counts. `sentencesThisPass` is incremented at ENQUEUE, so on its own it claims
        // sentences were spoken that may never have reached the speakers; `finishedCount` is the
        // only number that tracks what was actually heard. A gap between them is the signature of
        // a synthesiser that stopped mid-answer.
        // A remainder pass speaks fewer sentences than the user has now heard of the answer, and
        // the difference is exactly the state "tell me more" depends on — so name it rather than
        // leaving a reader to wonder why a 4-sentence pass followed a 6-sentence one.
        let heardSuffix = sentencesHeard == sentencesThisPass ? "" : " (\(sentencesHeard) of this answer heard in total)"
        logger.info("[JARVIS_TTS]\(self.correlationTag) Narration complete — \(self.finishedCount) of \(self.enqueuedCount) utterance(s) reached the speakers across \(self.sentencesThisPass) sentence(s)\(heardSuffix)\(self.truncated ? ", truncated" : "").")
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

extension JarvisStreamingSpeaker {

    /// The sentences of a finished `answer` that have not been read to the user yet.
    ///
    /// Pure, because the arithmetic is the whole of "tell me more" and the live path cannot be
    /// exercised without a speech synthesiser. Re-segments the COMPLETED answer with the same
    /// `cut` the narration used and drops what was already heard — the narration consumed the text
    /// while it was still streaming, so there is no buffer to replay, and counting sentences is
    /// what makes the boundary exact.
    ///
    /// ⚠️ `alreadyHeard` must be a count of ANSWER segments only. Feeding it a per-pass counter, or
    /// one inflated by an appended closing phrase, silently returns the wrong slice: too small and
    /// the user hears sentences twice, too large and a real sentence is skipped.
    static func remainingSentences(of answer: String, alreadyHeard: Int) -> [String] {
        guard alreadyHeard >= 0 else { return [] }
        let segments = cut(answer, fenceOpen: false, isFinal: true).segments
        guard alreadyHeard < segments.count else { return [] }
        return Array(segments.dropFirst(alreadyHeard))
    }

    /// Cuts streaming text into speakable sentences.
    ///
    /// Returns the segments ready to speak, the text to re-offer on the next pass, and the
    /// carried fence state. Pure and unit-tested — the streaming behaviour that is hardest to
    /// verify on a device is the part that needs tests most.
    ///
    /// Rules: a line opening or closing a ``` fence flushes prose and toggles the fence; lines
    /// inside a fence are consumed and replaced by ONE spoken announcement; prose is emitted
    /// only up to its last complete sentence unless `isFinal`, so nothing is ever spoken twice
    /// or spoken half-formed.
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

    /// Strips the markdown a voice must not pronounce.
    ///
    /// ⚠️ Deliberately does NOT touch underscores. SpeechService's private cleaner collapses
    /// `_…_` as emphasis, which silently corrupts any identifier with two or more underscores
    /// (`fs_smart_search` → `fssmartsearch`) — in a developer tool that is the exact text most
    /// worth pronouncing correctly. Under-stripping is far cheaper than corrupting a symbol.
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

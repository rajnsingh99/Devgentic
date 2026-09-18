// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbDuplexSpeaker.swift
//  Devgentic
//
//  [Phase 4b] Renders Orb's speech through the app's OWN AVAudioEngine instead of letting
//  AVFoundation play it on a private audio unit.
//
//  WHY THIS IS THE WHOLE POINT OF PHASE 4. VoiceProcessingIO cancels the audio the app plays
//  through the SAME engine that carries the microphone. While speech goes out through
//  `AVSpeechSynthesizer.speak`, there is no reference signal, so echo cancellation has nothing to
//  subtract and the microphone must stay closed while Orb talks. Routing synthesis through
//  `write(_:toBufferCallback:)` into an `AVAudioPlayerNode` on the shared engine is what makes
//  real barge-in possible — and what lets `audioSettleDelay` finally go.
//
//  ⚠️ THE UNDOCUMENTED PART, AND HOW THIS HANDLES IT. `AVSpeechSynthesis.h:238-250` says nothing
//  about how `write` signals that an utterance is fully rendered, and the delegate protocol
//  (:296-309) never mentions `write` at all. The "final buffer has frameLength == 0" belief has
//  no basis in the header. Rather than guess, this treats BOTH candidate signals as valid —
//  a zero-frame buffer OR `didFinishSpeechUtterance` — takes whichever arrives first, and LOGS
//  WHICH ONE FIRED. The first device run therefore answers the question as a side effect of
//  working, instead of needing a separate experiment.
//
//  VERIFIED AGAINST THE INSTALLED SDK:
//   • `AVSpeechSynthesizerBufferCallback` delivers `AVAudioBuffer` (AVSpeechSynthesis.h:56) —
//     NOT `AVAudioPCMBuffer`. It must be downcast, and a failed downcast is a real possibility
//     worth logging rather than silently dropping.
//   • `AVSpeechSynthesisVoice.audioFileSettings` (:149) documents that buffers arrive in the
//     VOICE's format, so a converter to the engine format is mandatory, not optional.
//   • `scheduleBuffer(_:completionCallbackType:completionHandler:)` (AVAudioPlayerNode.h:186).
//     ⚠️ The plain `scheduleBuffer(_:completionHandler:)` is equivalent to `.dataConsumed`
//     (:67-69) — consumed by the player, NOT heard by the user. `.dataPlayedBack` (:53) is the
//     only one that accounts for device latency, so it is the only correct hand-back signal.
//   • ⚠️ "the callbacks arrive on a non-main thread" (:71) — every one of them hops to the main
//     actor here.
//   • ⚠️ `playerNode.stop()` fires EVERY pending completion handler. Without the generation
//     stamp below, a barge-in would false-complete the turn and hand the microphone back twice.
//

import Foundation
import AVFoundation

@MainActor
final class OrbDuplexSpeaker: NSObject, AVSpeechSynthesizerDelegate {

    /// What the first real run teaches us about `write`'s undocumented contract.
    struct RenderReport {
        var bufferCount = 0
        var totalFrames: AVAudioFrameCount = 0
        var sourceFormat: String = "unknown"
        var sawZeroFrameTerminator = false
        var sawDelegateDidFinish = false
        var downcastFailures = 0
        var renderSeconds: Double = 0
    }

    private let logger = DGLogger(category: "OrbDuplex")
    var correlationTag: String = ""

    private var synthesizer: AVSpeechSynthesizer?
    /// Which utterance each synthesizer belongs to. A synthesizer outlives its sentence — `speak`
    /// installs a new one without unhooking the previous — so identity is the only reliable way
    /// to attribute a delegate callback.
    private var utteranceGenerations: [ObjectIdentifier: Int] = [:]
    /// Fires if a render never terminates — the engine being stopped mid-sentence is the case.
    private var renderWatchdog: Task<Void, Never>?
    /// Long enough that a slow render is not cut short, short enough that the orb does not sit in
    /// ANNOUNCING for the streaming speaker's full 30 s drain timeout on top of it.
    private static let renderTimeout: TimeInterval = 8
    private var converter: AVAudioConverter?
    private var player: AVAudioPlayerNode?

    /// Bumped on every new utterance and on barge-in. A completion handler whose generation no
    /// longer matches is from a cancelled utterance and must be ignored — `stop()` fires them all.
    private var generation = 0
    private var scheduled = 0
    private var playedBack = 0
    private var renderComplete = false
    private var onPlayed: (() -> Void)?
    private var report = RenderReport()
    private var startedAt = Date()

    /// Sentences waiting their turn. `AVSpeechSynthesizer.speak` has an internal queue;
    /// `write(_:toBufferCallback:)` does NOT, so a narrator that hands over a sentence at a time
    /// needs one here or the second sentence cancels the first mid-word.
    private var queue: [(text: String, onPlayed: () -> Void)] = []
    private var isBusy = false

    private(set) var lastReport: RenderReport?
    var isSpeaking: Bool { onPlayed != nil || isBusy || !queue.isEmpty }

    // MARK: - Queue

    /// Speaks `text` after everything already queued. `onPlayed` fires when THIS sentence has
    /// actually reached the speakers, so a caller counting sentences stays in step.
    func enqueue(_ text: String,
                 on player: AVAudioPlayerNode,
                 engineFormat: AVAudioFormat,
                 onPlayed: @escaping () -> Void) {
        queue.append((text, onPlayed))
        pump(on: player, engineFormat: engineFormat)
    }

    private func pump(on player: AVAudioPlayerNode, engineFormat: AVAudioFormat) {
        guard !isBusy, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        isBusy = true
        speak(item.text, on: player, engineFormat: engineFormat) { [weak self] in
            item.onPlayed()
            guard let self else { return }
            self.isBusy = false
            self.pump(on: player, engineFormat: engineFormat)
        }
    }

    // MARK: - Speaking

    /// Renders `text` and plays it through `player`, calling `onPlayed` once the audio has
    /// actually reached the speakers.
    func speak(_ text: String,
               on player: AVAudioPlayerNode,
               engineFormat: AVAudioFormat,
               onPlayed: @escaping () -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onPlayed(); return }

        generation &+= 1
        let thisGeneration = generation
        scheduled = 0
        playedBack = 0
        renderComplete = false
        report = RenderReport()
        startedAt = Date()
        self.onPlayed = onPlayed
        self.player = player

        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        self.synthesizer = synthesizer

        let utterance = AVSpeechUtterance(string: trimmed)
        OrbVoiceOutput.applyVoiceSettings(to: utterance)

        if !player.isPlaying { player.play() }

        logger.info("[ORB_DUPLEX]\(self.correlationTag) Rendering \(trimmed.count) character(s) through the app's engine (gen \(thisGeneration)).")

        utteranceGenerations[ObjectIdentifier(synthesizer)] = thisGeneration

        // ⚠️ `renderComplete` is only ever set by a terminator, and no terminator arrives once the
        // audio unit is gone — while `playerNode.stop()` fires every pending `.dataPlayedBack`
        // completion, so `playedBack` races up to `scheduled` and the drain condition is half-met
        // forever. Releasing the engine mid-sentence therefore stranded the hand-back and left the
        // rest of the queue unpumped, with no exit but the caller's 30 s timeout.
        renderWatchdog?.cancel()
        renderWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.renderTimeout))
            guard let self, !Task.isCancelled, thisGeneration == self.generation, !self.renderComplete else { return }
            self.logger.error("[ORB_DUPLEX]\(self.correlationTag) Render never terminated within \(Int(Self.renderTimeout))s (\(self.report.bufferCount) buffer(s) in). The audio engine was most likely stopped mid-sentence. CONSEQUENCE: handing back now so the rest of the answer can continue on whatever path is available; this sentence is incomplete.")
            self.finishRendering(reason: "render watchdog — engine stopped mid-sentence", generation: thisGeneration)
        }

        synthesizer.write(utterance) { [weak self] buffer in
            // ⚠️ Off the main thread by contract — hop before touching any state.
            Task { @MainActor [weak self] in
                self?.handleRendered(buffer, engineFormat: engineFormat, generation: thisGeneration)
            }
        }
    }

    /// Stops immediately and drops the hand-back — barge-in, or a failed run.
    func cancel() {
        renderWatchdog?.cancel()
        renderWatchdog = nil
        utteranceGenerations.removeAll()
        // ⚠️ Drop queued sentences WITHOUT calling their hand-backs. The narrator counts
        // sentences spoken; firing them here would make a cancelled answer look complete.
        let dropped = queue.count
        queue.removeAll()
        isBusy = false
        if dropped > 0 {
            logger.info("[ORB_DUPLEX]\(self.correlationTag) Dropped \(dropped) queued sentence(s) on cancel. CONSEQUENCE: the rest of the answer is not spoken — it stays visible in the chat window.")
        }
        guard onPlayed != nil || synthesizer != nil else { return }
        generation &+= 1          // orphan every pending completion before stopping
        onPlayed = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer?.delegate = nil
        synthesizer = nil
        player?.stop()
        converter = nil
        logger.info("[ORB_DUPLEX]\(self.correlationTag) Playback cancelled after \(self.playedBack)/\(self.scheduled) buffer(s).")
    }

    /// Full teardown — drops anything still queued. For panel teardown and barge-in only.
    ///
    /// ⚠️⚠️ NEVER call this from a per-utterance completion. `finishIfDrained` used to, and
    /// `queue.removeAll()` therefore discarded the REST OF THE ANSWER the moment the first
    /// sentence finished playing: Orb spoke one sentence of every reply and then went silent.
    /// Use `releaseUtterance()` between sentences.
    func releaseAudio() {
        queue.removeAll()
        isBusy = false
        releaseUtterance()
    }

    /// Releases the synthesizer for ONE finished sentence, leaving the queue intact.
    ///
    /// `speak` builds a fresh `AVSpeechSynthesizer` per utterance, so dropping it here is correct
    /// and keeps its audio unit from outliving the sentence — but the pending sentences are not
    /// this method's business.
    func releaseUtterance() {
        renderWatchdog?.cancel()
        renderWatchdog = nil
        if let synthesizer { utteranceGenerations.removeValue(forKey: ObjectIdentifier(synthesizer)) }
        synthesizer?.delegate = nil
        synthesizer = nil
        converter = nil
    }

    // MARK: - Rendering

    private func handleRendered(_ buffer: AVAudioBuffer, engineFormat: AVAudioFormat, generation: Int) {
        guard generation == self.generation else { return }

        guard let pcm = buffer as? AVAudioPCMBuffer else {
            // Documented as AVAudioBuffer, so a non-PCM buffer is legal in principle. Count it
            // rather than dropping it silently — silence with no explanation is the failure mode
            // this whole file is trying to avoid.
            report.downcastFailures += 1
            logger.warning("[ORB_DUPLEX]\(self.correlationTag) Rendered buffer was \(String(describing: type(of: buffer))), not AVAudioPCMBuffer — skipped. CONSEQUENCE: that fragment of speech is silent.")
            return
        }

        if report.bufferCount == 0 {
            report.sourceFormat = "\(Int(pcm.format.sampleRate)) Hz / \(pcm.format.channelCount) ch"
            logger.info("[ORB_DUPLEX]\(self.correlationTag) First buffer: \(self.report.sourceFormat), engine wants \(Int(engineFormat.sampleRate)) Hz / \(engineFormat.channelCount) ch.")
        }
        report.bufferCount += 1
        report.totalFrames += pcm.frameLength

        // ⚠️ Candidate terminator #1. Recorded whether or not it is the one we act on, because
        // this is the observation that settles the undocumented contract.
        if pcm.frameLength == 0 {
            report.sawZeroFrameTerminator = true
            finishRendering(reason: "zero-frame buffer", generation: generation)
            return
        }

        guard let converted = convert(pcm, to: engineFormat) else { return }
        schedule(converted, generation: generation)
    }

    private func convert(_ pcm: AVAudioPCMBuffer, to engineFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if pcm.format == engineFormat { return pcm }
        if converter == nil || converter?.inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: engineFormat)
        }
        guard let converter else {
            logger.error("[ORB_DUPLEX]\(self.correlationTag) No converter from \(Int(pcm.format.sampleRate)) Hz to \(Int(engineFormat.sampleRate)) Hz. CONSEQUENCE: this utterance is silent; the caller's watchdog ends the turn.")
            return nil
        }
        let ratio = engineFormat.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return pcm
        }
        if let error {
            logger.error("[ORB_DUPLEX]\(self.correlationTag) Buffer conversion failed: \(error.localizedDescription). CONSEQUENCE: a fragment of speech is silent.")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, generation: Int) {
        guard let player else { return }
        scheduled += 1
        // ⚠️ `.dataPlayedBack`, never the plain overload: the plain one means "consumed by the
        // player", which fires before the user has heard it. Handing the microphone back then
        // would open it over the tail of Orb's own voice.
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == self.generation else { return }
                self.playedBack += 1
                self.finishIfDrained(generation: generation)
            }
        }
    }

    private func finishRendering(reason: String, generation: Int) {
        guard generation == self.generation, !renderComplete else { return }
        renderComplete = true
        renderWatchdog?.cancel()
        renderWatchdog = nil
        report.renderSeconds = Date().timeIntervalSince(startedAt)
        logger.notice("[ORB_DUPLEX]\(self.correlationTag) Render complete via \(reason) — \(self.report.bufferCount) buffer(s), \(self.report.totalFrames) frame(s), source \(self.report.sourceFormat), in \(String(format: "%.2f", self.report.renderSeconds))s.")
        lastReport = report
        finishIfDrained(generation: generation)
    }

    private func finishIfDrained(generation: Int) {
        guard generation == self.generation, renderComplete, playedBack >= scheduled else { return }
        guard let handBack = onPlayed else { return }
        onPlayed = nil
        logger.info("[ORB_DUPLEX]\(self.correlationTag) Sentence played — \(self.playedBack) buffer(s) heard, \(self.queue.count) still queued. Terminator: zeroFrame=\(self.report.sawZeroFrameTerminator), didFinish=\(self.report.sawDelegateDidFinish).")
        // ⚠️ NOT releaseAudio() — that clears the queue and silences the rest of the answer.
        releaseUtterance()
        handBack()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    // ⚠️⚠️ BOTH callbacks carry the generation of the utterance that PRODUCED them, taken from
    // `utteranceGenerations` at delivery time. Reading `self.generation` inside the hopped task
    // read whatever was current when the task finally ran — so the guard in `finishRendering`
    // could never reject a stale callback, and a `didFinish` from sentence N could complete
    // sentence N+1 before it had rendered a single buffer. `speak()` installs a new synthesizer
    // per sentence without unhooking the old one, so that ordering is not hypothetical.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard let generation = self.utteranceGenerations[ObjectIdentifier(synthesizer)] else { return }
            guard generation == self.generation else {
                self.logger.info("[ORB_DUPLEX]\(self.correlationTag) Ignored a didFinish from utterance \(generation) while \(self.generation) is speaking. CONSEQUENCE: none — without this it would have completed the CURRENT sentence before it rendered.")
                return
            }
            self.report.sawDelegateDidFinish = true
            self.finishRendering(reason: "delegate didFinish", generation: generation)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard let generation = self.utteranceGenerations[ObjectIdentifier(synthesizer)] else { return }
            self.finishRendering(reason: "delegate didCancel", generation: generation)
        }
    }
}

// MARK: - Probe

@MainActor
enum OrbDuplexProbe {

    static let sample = "This is a duplex audio test. Orb is rendering this sentence through the app's own audio engine. If you can hear all three sentences, playback works."

    /// Runs one utterance end to end on a throwaway engine and logs what `write` actually does.
    ///
    /// This exists because the completion contract is undocumented and the whole turn hand-back
    /// depends on it: guessing wrong is either a permanently parked turn or a microphone that
    /// opens over Orb's own voice.
    static func run(logger: DGLogger) async -> String {
        await OrbAudioEngineBuilder.awaitDeviceRelease(logger: logger)
        do {
            let graph = try OrbAudioEngineBuilder.make(voiceProcessing: false, logger: logger)
            try OrbAudioEngineBuilder.start(graph, logger: logger)
            defer {
                graph.player.stop()
                graph.engine.stop()
                // Whatever opens the device next must wait for this one to let go of it.
                OrbAudioEngineBuilder.noteTeardown()
            }

            let speaker = OrbDuplexSpeaker()
            speaker.correlationTag = "[probe]"
            let engineFormat = graph.player.outputFormat(forBus: 0)
            logger.notice("[ORB_DUPLEX][probe] Starting — engine output \(Int(engineFormat.sampleRate)) Hz / \(engineFormat.channelCount) ch.")

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var resumed = false
                speaker.speak(sample, on: graph.player, engineFormat: engineFormat) {
                    if !resumed { resumed = true; continuation.resume() }
                }
                // Never hang the settings pane on an API whose contract is the thing under test.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if !resumed {
                        resumed = true
                        logger.error("[ORB_DUPLEX][probe] No playback completion within 30s. CONSEQUENCE: `write` did not signal completion in either form — Phase 4b cannot use this path as written.")
                        speaker.cancel()
                        continuation.resume()
                    }
                }
            }

            guard let report = speaker.lastReport else {
                return String(localized: "No audio was rendered — see the OrbDuplex log.")
            }
            return String(localized: """
                \(report.bufferCount) buffers, \(Int(report.totalFrames)) frames, source \(report.sourceFormat).
                Terminator: \(report.sawZeroFrameTerminator ? "zero-frame buffer" : "none")\(report.sawDelegateDidFinish ? " + delegate didFinish" : "").
                """)
        } catch {
            logger.error("[ORB_DUPLEX][probe] Could not start an engine: \(error.localizedDescription).")
            return String(localized: "Couldn't start the audio engine: \(error.localizedDescription)")
        }
    }
}

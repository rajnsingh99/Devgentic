// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbDuplexSpeaker.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import AVFoundation

/// Renders Orb's speech through the app's own `AVAudioEngine` instead of a private AVFoundation audio unit.
/// VoiceProcessingIO cancels only audio played through the engine that carries the microphone, which makes barge-in
/// possible. Synthesis goes through `write(_:toBufferCallback:)` into an `AVAudioPlayerNode`.
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

        // No terminator arrives once the audio unit is gone, so `renderComplete` is never set and the drain is half-met;
        // this exit keeps the hand-back from stranding until the caller's 30 s timeout.
        renderWatchdog?.cancel()
        renderWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.renderTimeout))
            guard let self, !Task.isCancelled, thisGeneration == self.generation, !self.renderComplete else { return }
            self.logger.error("[ORB_DUPLEX]\(self.correlationTag) Render never terminated within \(Int(Self.renderTimeout))s (\(self.report.bufferCount) buffer(s) in). The audio engine was most likely stopped mid-sentence. CONSEQUENCE: handing back now so the rest of the answer can continue on whatever path is available; this sentence is incomplete.")
            self.finishRendering(reason: "render watchdog — engine stopped mid-sentence", generation: thisGeneration)
        }

        synthesizer.write(utterance) { [weak self] buffer in
            // Called off the main thread by contract; hop before touching any state.
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
        // Drops queued sentences without calling their hand-backs: the narrator counts spoken sentences,
        // so firing them here would make a cancelled answer look complete.
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

    // Why: never call from a per-utterance completion: `queue.removeAll()` drops the rest of the answer; use
    // `releaseUtterance()`.
    /// Full teardown that drops anything still queued; for panel teardown and barge-in only.
    func releaseAudio() {
        queue.removeAll()
        isBusy = false
        releaseUtterance()
    }

    /// Releases the synthesizer for one finished sentence, leaving the queue intact.
    /// `speak` builds a fresh `AVSpeechSynthesizer` per utterance, so dropping it keeps its audio unit from outliving
    /// the sentence.
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
            // Documented as AVAudioBuffer, so a non-PCM buffer is legal in principle; count it rather than dropping it silently.
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

        // Candidate terminator 1 (zero-frame buffer): recorded whether or not it is the one acted on, to settle the contract.
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
        // `.dataPlayedBack`, never the plain overload: the plain one fires when the player consumes the buffer, before it
        // is heard, and handing the microphone back then would open it over the tail of Orb's own voice.
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
        // Not `releaseAudio()`: that clears the queue and silences the rest of the answer.
        releaseUtterance()
        handBack()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    // Both callbacks carry the generation of their own utterance, taken from `utteranceGenerations` at delivery;
    // reading `self.generation` in the hopped task would let a stale `didFinish` complete the next sentence.
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
    /// The completion contract is undocumented and the hand-back depends on it: a wrong guess parks the turn or opens
    /// the mic early.
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

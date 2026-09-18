// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbAudioProcessor.swift
//  Devgentic
//
//  [Phase 4a] A Devgentic-owned `AVAudioEngine` with VoiceProcessingIO (acoustic echo
//  cancellation) enabled, injected into WhisperKit through its public `AudioProcessing`
//  protocol — no fork, no patch.
//
//  WHY: today Orb closes the microphone whenever it speaks, because two independent
//  CoreAudio clients (WhisperKit's engine and a bare AVSpeechSynthesizer) fight over the device
//  — the documented `-10877` / `_StartIO error 35` dead-mic race. One engine carrying both
//  directions is what VoiceProcessingIO exists for, and it is the prerequisite for barge-in.
//
//  ⚠️ SCOPE OF THIS FILE (4a): the INPUT half only. It gives WhisperKit an AEC-enabled capture
//  path and exposes `playerNode` for the output half. Until Orb's speech is actually rendered
//  through that player node (4b), there is no AEC *reference signal*, so this does not yet cancel
//  Orb's own voice and does NOT yet enable barge-in. Do not delete `audioSettleDelay` or open
//  the microphone during `.announcing` on the strength of this file alone.
//
//  ⚠️ DEFAULT OFF. Gated by `OrbConfigManager.duplexAudioEnabled` (Developer mode). The
//  failure mode of this subsystem is a microphone that reports a healthy session and hears
//  nothing, and none of this has been exercised on a real audio device.
//
//  VERIFIED FACTS THIS FILE DEPENDS ON (re-checked against the installed SDK and WhisperKit
//  v0.15.0; the numbers are header lines, not folklore):
//   • `setVoiceProcessingEnabled(_:)` THROWS in Swift and reports failure loudly — the earlier
//     plan's "silently disables with no error" was wrong. Documented preconditions
//     (AVAudioIONode.h:141-153): engine STOPPED at toggle time, no manual-rendering mode,
//     toggling one IO node toggles both, and the input node's output format must equal the
//     output node's input format.
//   • Per AVAudioEngine.h, do NOT set an explicit format on the mainMixer→output connection;
//     connect only player→mainMixer and let the mixer convert.
//   • WhisperKit calls only `startRecordingLive`, `stopRecording`, `relativeEnergy`,
//     `audioSamples` … PLUS `padOrTrim`, which is on the transcription hot path
//     (TranscribeTask.swift:136) and throws if it returns nil.
//   • `purgeAudioSamples` is never called by WhisperKit, so this type bounds its own buffer.
//   • ⚠️⚠️ The protocol extension's `startRecordingLive` / `startStreamingRecordingLive` /
//     `resumeRecordingLive` "defaults" (AudioProcessor.swift:139-149) are SELF-CALLING
//     trampolines that exist only to attach default arguments. Omitting or mislabelling any of
//     the three still COMPILES and then infinitely recurses — verified by an isolated repro that
//     died with SIGSEGV. All three are therefore declared explicitly below and log on entry;
//     the absence of that entry line is the cheapest possible detector.
//

import Foundation
import AVFoundation
import CoreML
import WhisperKit

/// Builds the duplex graph. Extracted so BOTH recognizers (WhisperKit via `OrbAudioProcessor`
/// and Apple Speech via `OrbSpeechRecognizer`) construct the engine through one audited path —
/// a second, drifting copy of CoreAudio setup is exactly how one of them ends up silently deaf.
enum OrbAudioEngineBuilder {

    struct Graph {
        let engine: AVAudioEngine
        let player: AVAudioPlayerNode
        /// The input format READ AFTER voice processing was toggled. A tap installed in the
        /// pre-toggle format compiles cleanly and produces silence.
        let tapFormat: AVAudioFormat
        let voiceProcessingEnabled: Bool
    }

    // MARK: Device settling
    //
    // ⚠️⚠️ PROVEN ON DEVICE 2026-09-05, and it explains every duplex failure so far. Voice
    // processing is NOT broken on this Mac: as the FIRST engine in the process it captured 20
    // buffers in 2 s. What fails is the engine that follows another engine's teardown.
    //
    //   round 1: plain engine → probe → VP engine  ⇒ VP got 0 buffers
    //   round 2: probe        → VP engine          ⇒ VP got 0 buffers
    //   round 3: VP engine first                   ⇒ 20 buffers, healthy
    //
    // And building a plain engine immediately after tearing a VP engine down is worse still — the
    // aggregate is destroyed while the HAL still references it (`AudioObjectGetPropertyData: no
    // object with given ID 158`), the input node reports a stale 6 ch / 48 kHz hardware format,
    // and the engine fails to initialize with `-10868`.
    //
    // CoreAudio publishes no "device released" signal, so this is a bounded wait: at most
    // `deviceSettleWindow`, and only when an engine was actually torn down that recently.

    private static let deviceSettleWindow: TimeInterval = 0.4
    private static let settleLock = NSLock()
    nonisolated(unsafe) private static var lastTeardown: Date?

    /// Call from EVERY path that stops an Orb-built engine. Missing one reintroduces the race.
    static func noteTeardown() {
        settleLock.lock(); lastTeardown = Date(); settleLock.unlock()
    }

    /// Seconds still owed, or nil if the device is already free.
    private static func remainingSettle() -> TimeInterval? {
        settleLock.lock()
        let last = lastTeardown
        settleLock.unlock()
        guard let last else { return nil }
        let remaining = deviceSettleWindow - Date().timeIntervalSince(last)
        return remaining > 0 ? remaining : nil
    }

    /// ✅ PREFER THIS. Every async caller must await it before `make(...)`, which then finds the
    /// debt already paid and returns immediately.
    static func awaitDeviceRelease(logger: DGLogger) async {
        guard let remaining = remainingSettle() else { return }
        logger.info("[ORB_AUDIO] Waiting \(String(format: "%.0f", remaining * 1000)) ms for the previous engine to release the device. CONSEQUENCE: without this the new engine reports healthy and captures nothing, or fails to initialize with -10868.")
        try? await Task.sleep(for: .seconds(remaining))
    }

    /// Synchronous last resort for `AudioProcessing.startRecordingLive`, which the protocol
    /// declares non-async. Bounded by `deviceSettleWindow`.
    private static func waitForDeviceRelease(logger: DGLogger) {
        guard let remaining = remainingSettle() else { return }
        // ⚠️ Up to `deviceSettleWindow` of main-thread stall. Async callers must use
        // `awaitDeviceRelease` instead; this line is how we find out if one forgot.
        if Thread.isMainThread {
            logger.warning("[ORB_AUDIO] Settling \(String(format: "%.0f", remaining * 1000)) ms ON THE MAIN THREAD. CONSEQUENCE: the UI stalls for that long — this caller should await OrbAudioEngineBuilder.awaitDeviceRelease() before building the engine.")
        } else {
            logger.info("[ORB_AUDIO] Waiting \(String(format: "%.0f", remaining * 1000)) ms for the previous engine to release the device. CONSEQUENCE: without this the new engine reports healthy and captures nothing, or fails to initialize with -10868.")
        }
        Thread.sleep(forTimeInterval: remaining)
    }

    /// - Parameter voiceProcessing: when false the engine is built without AEC, which is the
    ///   safe path while the duplex flag is off.
    static func make(voiceProcessing: Bool, logger: DGLogger) throws -> Graph {
        waitForDeviceRelease(logger: logger)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let player = AVAudioPlayerNode()

        engine.attach(player)
        // ⚠️ nil format: per AVAudioEngine.h an explicit format on a connection into the main
        // mixer makes the app responsible for re-deriving it on every configuration change. The
        // mixer converts for us, so no AVAudioConverter is needed on playback.
        engine.connect(player, to: engine.mainMixerNode, format: nil)

        var vpEnabled = false
        if voiceProcessing {
            // Documented precondition (AVAudioIONode.h:150): the engine must be STOPPED when
            // toggling. It is — nothing has started it yet.
            do {
                try input.setVoiceProcessingEnabled(true)
                vpEnabled = input.isVoiceProcessingEnabled
            } catch {
                // Loud, not silent — the API reports failure through an NSError, contrary to the
                // earlier plan's claim. A caller that believes AEC is on will open the microphone
                // over the speaker and transcribe Orb's own voice.
                logger.error("[ORB_AUDIO] setVoiceProcessingEnabled FAILED: \(error.localizedDescription). CONSEQUENCE: no echo cancellation; the caller must keep closing the microphone while Orb speaks.")
                throw error
            }
        }

        let tapFormat = input.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            logger.error("[ORB_AUDIO] Input format is degenerate (\(tapFormat.sampleRate) Hz, \(tapFormat.channelCount) ch). CONSEQUENCE: no audio could ever arrive; refusing to start.")
            throw OrbAudioError.degenerateInputFormat
        }
        return Graph(engine: engine, player: player, tapFormat: tapFormat, voiceProcessingEnabled: vpEnabled)
    }

    /// Installs the tap and starts the engine, retrying ONCE if the hardware format moves between
    /// the two.
    ///
    /// ⚠️ Why the retry exists. `installTap(format: nil)` resolves the bus format **at install
    /// time** and bakes it in. If the hardware then re-negotiates before `start()`, the engine
    /// refuses to initialize:
    ///
    ///     Error, formats don't match! Input HW format: 6 ch, 48000 Hz, tap format: 1 ch, 16000 Hz
    ///     AVAudioEngine: could not initialize, error = -10868
    ///
    /// Observed for real while a destroyed aggregate was still being cleaned up. The settle window
    /// above should prevent it; this makes the outcome a lost tap rather than a dead session.
    static func installTapAndStart(_ graph: Graph,
                                   tapSeconds: Double,
                                   logger: DGLogger,
                                   onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let input = graph.engine.inputNode
        func install() -> AVAudioFormat {
            let current = input.outputFormat(forBus: 0)
            let frames = AVAudioFrameCount(max(current.sampleRate, 8_000) * tapSeconds)
            // `format: nil` — the bus supplies its own. An EXPLICIT format that no longer matches
            // the node installs cleanly and then delivers silence.
            input.installTap(onBus: 0, bufferSize: frames, format: nil) { buffer, _ in
                onBuffer(buffer)
            }
            return current
        }

        var installed = install()
        do {
            try start(graph, logger: logger)
        } catch where (error as NSError).code == -10868 {
            let now = input.outputFormat(forBus: 0)
            logger.error("[ORB_AUDIO] Engine refused to initialize (-10868): the tap was installed at \(Int(installed.sampleRate)) Hz / \(installed.channelCount) ch but the hardware is now \(Int(now.sampleRate)) Hz / \(now.channelCount) ch. Reinstalling the tap and retrying ONCE. CONSEQUENCE if the retry also fails: this recognizer cannot capture and the caller must fall back.")
            input.removeTap(onBus: 0)
            installed = install()
            try start(graph, logger: logger)
        }
        logger.info("[ORB_AUDIO] Tap installed at \(Int(installed.sampleRate)) Hz / \(installed.channelCount) ch and engine started.")
    }

    /// Starts the engine, naming the one macOS-specific failure that surfaces here rather than at
    /// the toggle.
    ///
    /// ⚠️ Re-reads the input format AFTER starting. Voice processing renegotiates the device while
    /// the engine comes up — the first device run logged `AUVPAggregate: Timeout waiting for
    /// streams` followed by the channel count flapping 3 → 2 → 1 — so the format captured in
    /// `make(voiceProcessing:logger:)` can already be stale by the time audio flows. Nothing here
    /// depends on the pre-start value any more (`OrbTapAdapter` works from the real buffers),
    /// but a divergence is worth one line in the log.
    static func start(_ graph: Graph, logger: DGLogger) throws {
        graph.engine.prepare()
        do {
            try graph.engine.start()
            let post = graph.engine.inputNode.outputFormat(forBus: 0)
            if post.sampleRate != graph.tapFormat.sampleRate || post.channelCount != graph.tapFormat.channelCount {
                logger.notice("[ORB_AUDIO] Input format changed across engine start: \(Int(graph.tapFormat.sampleRate)) Hz / \(graph.tapFormat.channelCount) ch → \(Int(post.sampleRate)) Hz / \(post.channelCount) ch. CONSEQUENCE: none — the tap is untyped and the converter is built from the first real buffer.")
            }
        } catch {
            let code = (error as NSError).code
            let hint = code == -66784
                ? " (kAUVoiceIOErr_UnexpectedNumberOfInputChannels — the input device has a channel count voice processing will not accept; common on aggregate devices and USB interfaces)"
                : ""
            logger.error("[ORB_AUDIO] Engine start FAILED, OSStatus \(code)\(hint): \(error.localizedDescription). CONSEQUENCE: this recognizer cannot capture; the caller must fall back.")
            graph.engine.inputNode.removeTap(onBus: 0)
            throw error
        }
    }
}

final class OrbAudioProcessor: NSObject, AudioProcessing {

    // MARK: Tunables

    /// Target tap duration. AVAudioNode.h documents the supported range as [100, 400] ms, and
    /// WhisperKit's own 1600-frame tap is BELOW that at 48 kHz — so the buffer size is derived
    /// from the real post-VP sample rate here rather than copied as a frame count.
    private static let targetTapSeconds: Double = 0.1
    /// WhisperKit's model rate. Everything handed onward is mono Float at this rate.
    private static let whisperSampleRate: Double = 16_000
    /// Rolling window for the relative-energy reference, matching WhisperKit's own.
    private static let energyWindow = 20
    /// Hard bound on retained samples (~10 min at 16 kHz). WhisperKit never purges, and an
    /// unbounded buffer degrades every decode pass for the rest of the session.
    private static let maxRetainedSamples = 16_000 * 600
    /// How long a voice-processing engine gets to deliver its FIRST buffer before it is judged
    /// dead. Generous next to the 100 ms tap — a healthy device delivers within one or two of
    /// them — and comfortably inside the session's own 3 s dead-audio warning, so the downgrade
    /// happens before the user is ever told the microphone is broken.
    private static let voiceProcessingFirstBufferDeadline: Duration = .seconds(2)
    /// Extra settle before a recovery rebuild, on top of the builder's own window. Longer because
    /// the thing being recovered from is very likely a device that had not finished letting go.
    private static let recoverySettleSeconds: Double = 1.0

    private let logger = DGLogger(category: "OrbAudio")
    /// Set by whoever owns this processor, so tap and engine lines attribute to a session.
    var correlationTag: String = ""

    // MARK: Shared engine

    // ⚠️ These three are written by `startEngine`/`stopEngine` on the caller's thread AND by the
    // dead-tap watchdog on its own. A bare `var` would be a torn reference-count update, not a
    // theoretical race — so every access goes through `lock`. Read-only from outside; mutation is
    // `set…` below so no caller can bypass the lock.
    private var _engine: AVAudioEngine?
    private var _playerNode: AVAudioPlayerNode?
    private var _voiceProcessingEnabled = false

    /// The one engine carrying both directions.
    var engine: AVAudioEngine? {
        lock.lock(); defer { lock.unlock() }
        return _engine
    }
    /// Orb's own speech is scheduled here once the duplex speaker is wired in. Attached and
    /// connected NOW so the graph shape — and therefore the AEC reference path — is established
    /// before it matters.
    var playerNode: AVAudioPlayerNode? {
        lock.lock(); defer { lock.unlock() }
        return _playerNode
    }
    /// ⚠️ Can go from true to FALSE mid-session: see `downgradeIfTapIsDead`.
    var voiceProcessingEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _voiceProcessingEnabled
    }

    /// ⚠️ Never call while holding `lock` — it is not recursive.
    private func setGraph(engine: AVAudioEngine?, player: AVAudioPlayerNode?, voiceProcessing: Bool) {
        lock.lock()
        _engine = engine
        _playerNode = player
        _voiceProcessingEnabled = voiceProcessing
        lock.unlock()
    }

    // MARK: AudioProcessing state

    private let lock = NSLock()
    private var _audioSamples = ContiguousArray<Float>()
    private var _relativeEnergy: [Float] = []
    private var energyHistory: [Float] = []
    /// Owns format discovery, downmixing and drop accounting. Nil until the engine is up.
    private var tapAdapter: OrbTapAdapter?
    private var sampleCallback: (([Float]) -> Void)?
    /// Whether samples should currently be delivered. `stopRecording()` clears this; it must
    /// NEVER tear the engine down — see the note on that method.
    private var isDelivering = false
    /// Fires once if a voice-processing engine reports healthy and then delivers nothing.
    ///
    /// ⚠️ Written from THREE contexts — `startEngine` (main actor via `OrbDuplexAudio.build`,
    /// AND WhisperKit's `AudioStreamTranscriber` actor via `startRecordingLive`), `recoverIfTapIsDead`
    /// (cooperative pool) and `stopEngine` (main actor) — so it obeys the same `lock` rule this
    /// file's header states for every other shared property. A bare `var` here is a torn
    /// reference-count update, not a theoretical race.
    private var deadTapWatchdog: Task<Void, Never>?
    /// ⚠️ Set by `stopEngine` and never cleared: a stopped processor must never build another
    /// engine. `WhisperRecognitionService` borrows this object on the main actor and only then
    /// hops to WhisperKit's actor and awaits permission — two suspension points in which the owner
    /// can release it. Without this latch, `startRecordingLive` would happily build an engine
    /// nobody owns, and the one place allowed to stop it has already run.
    private var disowned = false
    /// ⚠️ Counts EVERY tap callback, before the `isDelivering` guard.
    ///
    /// The adapter's own counter cannot answer "did the tap fire?", because `handleTap` only
    /// reaches the adapter once WhisperKit has attached a consumer via `startRecordingLive`.
    /// Using it as the liveness test conflates "CoreAudio delivered nothing" with "nobody was
    /// listening yet" — two failures with opposite fixes, and the second one would tear down a
    /// perfectly healthy voice-processing engine.
    private var rawTapCallbacks = 0
    /// Buffers the adapter converted successfully that still yielded no samples. Counted because
    /// the adapter has already recorded them as delivered by then.
    private var emptySampleDrops = 0
    /// How far recovery has escalated. Bounds it at two rebuilds, so a device that simply never
    /// delivers cannot put this in a loop.
    private var recoveryStage: RecoveryStage = .none

    private enum RecoveryStage {
        case none
        case retriedWithVoiceProcessing
        case exhausted
    }

    var audioSamples: ContiguousArray<Float> {
        lock.lock(); defer { lock.unlock() }
        return _audioSamples
    }

    var relativeEnergy: [Float] {
        lock.lock(); defer { lock.unlock() }
        return _relativeEnergy
    }

    /// Declared because the protocol requires it. ⚠️ Inert by design: WhisperKit's own energy
    /// calculation uses a literal window, so changing this tunes nothing — kept so the shape
    /// matches and nobody "fixes" it into a false knob.
    var relativeEnergyWindow: Int = OrbAudioProcessor.energyWindow

    // MARK: - Engine lifecycle

    /// Builds the duplex graph and starts it. Throws with a specific, loggable reason.
    ///
    /// Ordering here is engineering judgment, NOT an Apple-documented rule: no AVFAudio header
    /// ties voice processing to node-connection order. The documented constraints are the ones
    /// enforced below — engine stopped at toggle time, and formats read AFTER the toggle.
    func startEngine(inputDeviceID: DeviceID? = nil) throws {
        lock.lock(); let alreadyDisowned = disowned; lock.unlock()
        guard !alreadyDisowned else {
            logger.notice("[ORB_AUDIO]\(self.correlationTag) Refusing to build an engine on a RELEASED processor. CONSEQUENCE: this session falls back to WhisperKit's own engine — correct, because the owner let this one go and nothing is left that could stop it again.")
            throw OrbAudioError.processorReleased
        }
        if engine != nil { return }

        let graph = try OrbAudioEngineBuilder.make(voiceProcessing: true, logger: logger)

        guard let whisperFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.whisperSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            logger.error("[ORB_AUDIO]\(self.correlationTag) Could not describe WhisperKit's own 16 kHz mono format. CONSEQUENCE: nothing could be converted; refusing to start the duplex engine.")
            throw OrbAudioError.converterUnavailable
        }
        // ⚠️ NOT built from `graph.tapFormat`: that format is read before the engine starts and
        // voice processing may still renegotiate the device afterwards. The adapter builds its
        // converter from the first real buffer instead. `graph.tapFormat` is passed only so a
        // divergence gets logged.
        let adapter = OrbTapAdapter(predicted: graph.tapFormat, target: whisperFormat, tag: "[ORB_AUDIO]", logger: logger)
        // Same rule as `deadTapWatchdog`: `handleTap` reads this from the real-time audio thread
        // and the recovery path swaps it from the cooperative pool.
        lock.lock(); self.tapAdapter = adapter; lock.unlock()

        try OrbAudioEngineBuilder.installTapAndStart(graph, tapSeconds: Self.targetTapSeconds, logger: logger) { [weak self] buffer in
            self?.handleTap(buffer)
        }

        setGraph(engine: graph.engine, player: graph.player, voiceProcessing: graph.voiceProcessingEnabled)
        if graph.voiceProcessingEnabled { armDeadTapWatchdog(for: graph.engine) }
        logger.notice("[ORB_AUDIO]\(self.correlationTag) Duplex engine STARTED for WhisperKit — voiceProcessing: \(graph.voiceProcessingEnabled), bypassed: \(graph.engine.inputNode.isVoiceProcessingBypassed).")
    }

    /// Voice processing can report a healthy engine and then deliver nothing.
    ///
    /// PROVEN ON DEVICE (2026-09-05): `voiceProcessing: true, bypassed: false`, no throw from
    /// `setVoiceProcessingEnabled`, engine started — and `tap fired 0 times`. The CoreAudio log
    /// showed VP failing to build its aggregate underneath (`AUVPAggregate: Timeout waiting for
    /// streams`, `_StartIO error 35`). Nothing in the AVFAudio API surfaces that.
    ///
    /// A dead microphone is strictly worse than a live one without echo cancellation, so this
    /// rebuilds WITHOUT voice processing rather than leaving the user deaf. Barge-in is lost for
    /// the session; capture is not. The downgrade is logged loudly because it silently changes
    /// what the duplex flag actually delivers.
    private func armDeadTapWatchdog(for startedEngine: AVAudioEngine) {
        lock.lock()
        deadTapWatchdog?.cancel()
        deadTapWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.voiceProcessingFirstBufferDeadline)
            guard !Task.isCancelled else { return }
            await self?.recoverIfTapIsDead(startedEngine)
        }
        lock.unlock()
    }

    /// Escalating recovery, one step per watchdog firing.
    ///
    /// ⚠️ WHY A RETRY *WITH* VOICE PROCESSING COMES FIRST. Voice processing is not broken on this
    /// hardware — `OrbMicProbe` captures 20 buffers in 2 s with it enabled, and reports a
    /// **2-channel** tap. It only fails inside a live Orb session, where the tap comes up
    /// **3-channel** (the raw mic-array format the input node falls back to when the voice
    /// processing aggregate never finishes configuring) and delivers nothing.
    ///
    /// The difference is what the session does immediately beforehand: it speaks. The engine is
    /// rebuilt per stream session, so every turn constructs voice processing seconds after
    /// `AVSpeechSynthesizer` released its own audio unit. Dropping straight to no-AEC would give
    /// up echo cancellation permanently for what may just be a device that needed longer.
    ///
    /// So: retry once with voice processing after a longer settle, and only then downgrade. The
    /// log says which step succeeded, which is the measurement that decides whether the permanent
    /// fix is a longer wait or an engine whose lifetime spans the whole panel session.
    private func recoverIfTapIsDead(_ startedEngine: AVAudioEngine) async {
        lock.lock()
        let adapter = tapAdapter
        let stage = recoveryStage
        let rawCallbacks = rawTapCallbacks
        lock.unlock()

        // Identity, not just non-nil: the session may have torn this engine down and started
        // another while the watchdog slept. Resurrecting a dead one would leak a live input.
        guard self.engine === startedEngine, stage != .exhausted else { return }
        // ⚠️ The RAW counter, not the adapter's. See `rawTapCallbacks`: the adapter only sees
        // buffers after WhisperKit attaches, so a slow attach would look identical to a dead
        // device and cost us a healthy engine.
        guard rawCallbacks == 0 else {
            if adapter?.snapshot.callbacks == 0 {
                logger.info("[ORB_AUDIO]\(self.correlationTag) Tap is alive (\(rawCallbacks) callback(s)) but no consumer is attached yet. CONSEQUENCE: none — recovery correctly stands down; this would have been a false downgrade of a healthy engine.")
            }
            return
        }
        guard adapter != nil else { return }

        let next: RecoveryStage = stage == .none ? .retriedWithVoiceProcessing : .exhausted
        let keepVoiceProcessing = next == .retriedWithVoiceProcessing

        if keepVoiceProcessing {
            logger.error("[ORB_AUDIO]\(self.correlationTag) Voice processing delivered NO buffers within \(Self.voiceProcessingFirstBufferDeadline). Rebuilding WITH voice processing after a longer settle (\(String(format: "%.1f", Self.recoverySettleSeconds))s) — it works standing alone on this Mac, so contention with the speech synthesiser is the likelier cause. CONSEQUENCE if this retry also comes up empty: echo cancellation is dropped for the session.")
        } else {
            logger.error("[ORB_AUDIO]\(self.correlationTag) The retry WITH voice processing also delivered no buffers. CONSEQUENCE: rebuilding without echo cancellation — the microphone will work, but Orb must keep closing it while speaking and barge-in is unavailable for this session.")
        }

        lock.lock(); recoveryStage = next; lock.unlock()

        guard let whisperFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.whisperSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            // The escalation decision was already logged at error level above, so returning
            // silently here left a promise in the log that nothing kept.
            logger.error("[ORB_AUDIO]\(self.correlationTag) Recovery ABORTED — could not describe WhisperKit's own 16 kHz mono format. CONSEQUENCE: the announced rebuild never happens and this session stays deaf; disregard the recovery line above it.")
            return
        }

        // The tap comes off first: after this no callback can fire, so the pointer swap below
        // needs no lock around the CoreAudio calls themselves.
        startedEngine.inputNode.removeTap(onBus: 0)
        startedEngine.stop()
        OrbAudioEngineBuilder.noteTeardown()

        // ⚠️ Longer than the standard settle window ON PURPOSE. Rebuilding straight after tearing
        // a voice-processing engine down is what destroyed the aggregate mid-flight and produced
        // -10868; this is also the variable under test.
        try? await Task.sleep(for: .seconds(Self.recoverySettleSeconds))
        await OrbAudioEngineBuilder.awaitDeviceRelease(logger: logger)

        // ⚠️ Re-check AFTER the waits. Both sleeps are `try?`, so they collapse instantly under
        // cancellation, and `stopEngine` may have run during that ~1.4 s. Without this the code
        // below would build and start a SECOND engine on a device the session already released.
        // ⚠️ IDENTITY ONLY. `engine == nil` is EXACTLY the released state — admitting it here
        // inverted the guard and let recovery build a fresh engine on a processor the owner had
        // already dropped, with no release path left that could reach it. That is the
        // coreaudiod-wedge shape this check exists to prevent.
        guard self.engine === startedEngine else {
            logger.notice("[ORB_AUDIO]\(self.correlationTag) Recovery ABANDONED — the engine was released or replaced during the settle. CONSEQUENCE: none, and this is the correct outcome: the owner is in control and no orphan engine was started.")
            return
        }

        do {
            let graph = try OrbAudioEngineBuilder.make(voiceProcessing: keepVoiceProcessing, logger: logger)
            let newAdapter = OrbTapAdapter(predicted: graph.tapFormat, target: whisperFormat, tag: "[ORB_AUDIO]", logger: logger)

            lock.lock(); tapAdapter = newAdapter; lock.unlock()

            try OrbAudioEngineBuilder.installTapAndStart(graph, tapSeconds: Self.targetTapSeconds, logger: logger) { [weak self] buffer in
                self?.handleTap(buffer)
            }

            setGraph(engine: graph.engine, player: graph.player, voiceProcessing: graph.voiceProcessingEnabled)
            if keepVoiceProcessing {
                logger.notice("[ORB_AUDIO]\(self.correlationTag) Engine rebuilt WITH voice processing (enabled: \(graph.voiceProcessingEnabled)). Watching again — if buffers arrive now, the original failure was purely contention and echo cancellation survives.")
                // One more chance to prove itself before the downgrade.
                armDeadTapWatchdog(for: graph.engine)
            } else {
                logger.notice("[ORB_AUDIO]\(self.correlationTag) Engine rebuilt WITHOUT voice processing — capture restored, echo cancellation unavailable for this session.")
            }
        } catch {
            logger.error("[ORB_AUDIO]\(self.correlationTag) Rebuild (voiceProcessing: \(keepVoiceProcessing)) FAILED: \(error.localizedDescription). CONSEQUENCE: this session has no microphone at all; the orb's Repair Audio action is the remaining option.")
        }
    }

    /// Tears the engine down completely. Only the OWNER calls this — never WhisperKit.
    func stopEngine(reason: String) {
        lock.lock()
        deadTapWatchdog?.cancel()
        deadTapWatchdog = nil
        // ⚠️ Latched BEFORE the guard below, so even a stop on an engine that never started
        // disowns the processor — the borrow/`startRecordingLive` window is exactly that case.
        disowned = true
        lock.unlock()
        guard let engine else { return }
        // Before anything is released: say what the tap actually did. A session that heard nothing
        // must name the stage that ate the audio, not just report silence.
        lock.lock(); let raw = rawTapCallbacks; lock.unlock()
        if let tapAdapter {
            // Both numbers, because their DIFFERENCE is the diagnosis: raw 0 is device-level,
            // raw > 0 with 0 delivered means the tap ran while nothing was consuming it.
            let empties = { lock.lock(); defer { lock.unlock() }; return emptySampleDrops }()
            logger.notice("[ORB_AUDIO]\(self.correlationTag) Tap summary — \(raw) raw callback(s); \(tapAdapter.summary())\(empties > 0 ? "; \(empties) converted buffer(s) held no samples" : "").")
        }
        engine.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        engine.stop()
        OrbAudioEngineBuilder.noteTeardown()
        setGraph(engine: nil, player: nil, voiceProcessing: false)
        lock.lock(); tapAdapter = nil; recoveryStage = .none; rawTapCallbacks = 0; lock.unlock()
        lock.lock(); isDelivering = false; lock.unlock()
        logger.notice("[ORB_AUDIO]\(self.correlationTag) Duplex engine STOPPED (\(reason)). CONSEQUENCE: the input device is released; a live engine at process death is what wedges coreaudiod into _StartIO error 35.")
    }

    /// ⚠️ The class had no `deinit`. If the owner ever drops its reference without calling
    /// `stopEngine`, a running `AVAudioEngine` is leaked onto the device — and a live engine at
    /// process death is what wedges `coreaudiod` into `_StartIO error 35`, an app-wide dead
    /// microphone that survives relaunch.
    deinit {
        if _engine != nil {
            logger.error("[ORB_AUDIO]\(self.correlationTag) Processor deallocated with a LIVE engine — stopEngine was never called. CONSEQUENCE: stopping it here, but the owner has a lifetime bug; a live engine at process death wedges coreaudiod app-wide.")
            _engine?.inputNode.removeTap(onBus: 0)
            _playerNode?.stop()
            _engine?.stop()
            OrbAudioEngineBuilder.noteTeardown()
        }
    }

    // MARK: - Tap

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        rawTapCallbacks += 1
        let delivering = isDelivering
        // ⚠️ Read under the lock: the dead-tap downgrade can swap this out from another thread.
        let tapAdapter = self.tapAdapter
        lock.unlock()
        guard let tapAdapter else { return }
        // Not a drop worth reporting: `stopRecording()` sets this while the engine stays up, which
        // is the normal state between turns.
        guard delivering else { return }

        // The adapter downmixes, converts, and NAMES every failure. WhisperKit's own energy math
        // still runs below, deliberately: `relativeEnergy` is not just an ASR detail, it is the
        // signal three independent dead-mic detectors key on. Computing it differently here would
        // make every duplex session look dead while transcribing fine.
        guard let resampled = tapAdapter.adapt(buffer) else { return }
        let samples = AudioProcessor.convertBufferToArray(buffer: resampled)
        guard !samples.isEmpty else {
            // ⚠️ Counted as DELIVERED by the adapter one line earlier, so without this the tap
            // summary can report "no drops" on a session that heard nothing.
            lock.lock(); emptySampleDrops += 1; let n = emptySampleDrops; lock.unlock()
            if n == 1 {
                logger.error("[ORB_AUDIO]\(self.correlationTag) A converted buffer produced ZERO samples. CONSEQUENCE: it never reaches the recogniser, and the tap summary still counts it as delivered — if this repeats the session is deaf despite a healthy-looking summary.")
            }
            return
        }

        let energy = AudioProcessor.calculateEnergy(of: samples).avg
        lock.lock()
        energyHistory.append(energy)
        if energyHistory.count > Self.energyWindow { energyHistory.removeFirst() }
        let reference = energyHistory.min()
        let relative = AudioProcessor.calculateRelativeEnergy(of: samples, relativeTo: reference)
        _relativeEnergy.append(relative)
        _audioSamples.append(contentsOf: samples)
        if _audioSamples.count > Self.maxRetainedSamples {
            _audioSamples.removeFirst(_audioSamples.count - Self.maxRetainedSamples)
        }
        let callback = sampleCallback
        lock.unlock()

        callback?(samples)
    }

    // MARK: - AudioProcessing: live capture
    //
    // ⚠️ All three are declared EXPLICITLY. See the trampoline note in the file header: omitting
    // one satisfies the protocol at compile time and infinitely recurses at runtime.

    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        logger.info("[ORB_AUDIO]\(self.correlationTag) startRecordingLive — the duplex processor is live (this line's ABSENCE means the protocol trampoline is recursing).")
        try startEngine(inputDeviceID: inputDeviceID)
        lock.lock()
        sampleCallback = callback
        _audioSamples.removeAll(keepingCapacity: true)
        _relativeEnergy.removeAll(keepingCapacity: true)
        energyHistory.removeAll(keepingCapacity: true)
        isDelivering = true
        lock.unlock()
    }

    func startStreamingRecordingLive(inputDeviceID: DeviceID?) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        logger.info("[ORB_AUDIO]\(self.correlationTag) startStreamingRecordingLive — streaming variant entered.")
        var continuation: AsyncThrowingStream<[Float], Error>.Continuation!
        let stream = AsyncThrowingStream<[Float], Error> { continuation = $0 }
        do {
            try startRecordingLive(inputDeviceID: inputDeviceID) { samples in
                continuation.yield(samples)
            }
        } catch {
            continuation.finish(throwing: error)
        }
        return (stream, continuation)
    }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        logger.info("[ORB_AUDIO]\(self.correlationTag) resumeRecordingLive — resuming delivery without clearing the buffer.")
        try startEngine(inputDeviceID: inputDeviceID)
        lock.lock()
        if let callback { sampleCallback = callback }
        isDelivering = true
        lock.unlock()
    }

    func pauseRecording() {
        lock.lock(); isDelivering = false; lock.unlock()
        logger.info("[ORB_AUDIO]\(self.correlationTag) pauseRecording — sample delivery paused; the engine stays up.")
    }

    /// ⚠️ Means "stop delivering samples", NEVER "tear down the engine".
    ///
    /// WhisperKit calls this from `clearState()` and `deinit`, which Devgentic triggers on every
    /// normal model load, unload and switch. WhisperKit's own implementation strips taps from
    /// EVERY attached node and nils the engine — copied verbatim it would rip the tap off our
    /// player node and kill Orb's audio every time the user changes speech model. Engine
    /// teardown belongs to `stopEngine(reason:)` and its owner alone.
    func stopRecording() {
        lock.lock()
        isDelivering = false
        sampleCallback = nil
        lock.unlock()
        logger.info("[ORB_AUDIO]\(self.correlationTag) stopRecording — delivery stopped, engine deliberately LEFT RUNNING (teardown belongs to stopEngine).")
    }

    func purgeAudioSamples(keepingLast keep: Int) {
        lock.lock(); defer { lock.unlock() }
        guard _audioSamples.count > keep else { return }
        _audioSamples.removeFirst(_audioSamples.count - keep)
    }

    // MARK: - AudioProcessing: forwarded utilities
    //
    // Pure file/array helpers with no engine involvement. Forwarded to WhisperKit's own public
    // statics so this type cannot drift from the implementation the decoder expects.
    // ⚠️ `padOrTrim` is on the transcription HOT PATH (TranscribeTask throws if it returns nil):
    // a stub here yields a live microphone, a moving energy meter and zero transcripts.

    func padOrTrim(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int) -> (any AudioProcessorOutputType)? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex, toLength: frameLength, saveSegment: false)
    }

    static func loadAudio(fromPath audioFilePath: String, channelMode: ChannelMode, startTime: Double?, endTime: Double?, maxReadFrameSize: AVAudioFrameCount?) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(fromPath: audioFilePath, channelMode: channelMode, startTime: startTime, endTime: endTime, maxReadFrameSize: maxReadFrameSize)
    }

    static func loadAudio(at audioPaths: [String], channelMode: ChannelMode) async -> [Result<[Float], Swift.Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }

    static func padOrTrimAudio(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int, saveSegment: Bool) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex, toLength: frameLength, saveSegment: saveSegment)
    }
}

// MARK: - Errors

enum OrbAudioError: LocalizedError {
    case degenerateInputFormat
    case converterUnavailable
    /// The owner released this processor; it must never build another engine.
    case processorReleased

    var errorDescription: String? {
        switch self {
        case .degenerateInputFormat:
            return String(localized: "The microphone reported an unusable format after enabling echo cancellation.")
        case .converterUnavailable:
            return String(localized: "Could not convert microphone audio to the speech model's format.")
        case .processorReleased:
            return String(localized: "The echo-cancelling audio engine was released while starting.")
        }
    }
}

// MARK: - Microphone probe

/// Answers the one question the session logs cannot: **is voice processing itself the reason the
/// microphone delivers nothing, or is it contention with whatever ran before it?**
///
/// Every duplex failure so far has followed another audio engine in the same process, so the two
/// explanations were never separable. This runs both arms back to back and reports each — a
/// within-run control. Voice processing goes FIRST so it gets the cleanest shot at the device.
@MainActor
enum OrbMicProbe {

    /// Long enough that a healthy device delivers ~20 buffers, short enough to sit in a settings
    /// pane without feeling hung.
    private static let listenSeconds: Double = 2.0

    struct Arm {
        let voiceProcessing: Bool
        var buffers = 0
        var format = "—"
        var error: String?
    }

    /// Counts tap callbacks from the audio thread.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var format = "—"
        func record(_ buffer: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            if count == 0 { format = "\(Int(buffer.format.sampleRate)) Hz / \(buffer.format.channelCount) ch" }
            count += 1
        }
        var snapshot: (Int, String) {
            lock.lock(); defer { lock.unlock() }
            return (count, format)
        }
    }

    static func run(logger: DGLogger) async -> String {
        logger.notice("[ORB_MIC_PROBE] Starting — voice processing first, then a plain engine as the control. Speak normally; buffers arrive whether or not you do.")
        let withVP = await listen(voiceProcessing: true, logger: logger)
        let withoutVP = await listen(voiceProcessing: false, logger: logger)

        let verdict: String
        switch (withVP.buffers > 0, withoutVP.buffers > 0) {
        case (true, _):
            verdict = String(localized: "Echo cancellation works on this Mac.")
            logger.notice("[ORB_MIC_PROBE] VERDICT: voice processing captures normally. Duplex audio is viable here.")
        case (false, true):
            verdict = String(localized: "Echo cancellation is broken on this Mac — plain capture works. Orb will fall back automatically.")
            logger.error("[ORB_MIC_PROBE] VERDICT: voice processing delivered NOTHING while a plain engine on the same device delivered \(withoutVP.buffers) buffer(s). CONSEQUENCE: this is a voice-processing failure, NOT contention — barge-in is unavailable on this hardware and the session downgrades automatically.")
        case (false, false):
            verdict = String(localized: "No microphone input at all — try Repair Audio.")
            logger.error("[ORB_MIC_PROBE] VERDICT: NEITHER engine captured. CONSEQUENCE: this is device-level, not voice processing — coreaudiod is likely wedged; use Repair Audio.")
        }

        func describe(_ arm: Arm) -> String {
            if let error = arm.error { return String(localized: "failed (\(error))") }
            return arm.buffers > 0
                ? String(localized: "\(arm.buffers) buffers, \(arm.format)")
                : String(localized: "nothing")
        }
        return String(localized: """
            With echo cancellation: \(describe(withVP)).
            Without: \(describe(withoutVP)).
            \(verdict)
            """)
    }

    private static func listen(voiceProcessing: Bool, logger: DGLogger) async -> Arm {
        var arm = Arm(voiceProcessing: voiceProcessing)
        let label = voiceProcessing ? "with VP" : "without VP"
        // This type is @MainActor: settle by awaiting, never by blocking the UI.
        await OrbAudioEngineBuilder.awaitDeviceRelease(logger: logger)
        do {
            let graph = try OrbAudioEngineBuilder.make(voiceProcessing: voiceProcessing, logger: logger)
            let counter = Counter()
            try OrbAudioEngineBuilder.installTapAndStart(graph, tapSeconds: 0.1, logger: logger) { buffer in
                counter.record(buffer)
            }
            try? await Task.sleep(for: .seconds(listenSeconds))
            graph.engine.inputNode.removeTap(onBus: 0)
            graph.engine.stop()
            // ⚠️ Mandatory between arms. Building the second engine straight after tearing the
            // first one down is what destroyed the aggregate mid-flight and produced -10868.
            OrbAudioEngineBuilder.noteTeardown()

            let (count, format) = counter.snapshot
            arm.buffers = count
            arm.format = format
            logger.notice("[ORB_MIC_PROBE] \(label): \(count) buffer(s) in \(String(format: "%.0f", listenSeconds))s, first buffer \(format), voiceProcessing actually enabled: \(graph.voiceProcessingEnabled).")
        } catch {
            arm.error = error.localizedDescription
            logger.error("[ORB_MIC_PROBE] \(label): engine could not start — \(error.localizedDescription). CONSEQUENCE: this arm proves nothing; treat the other one as the only result.")
        }
        return arm
    }
}

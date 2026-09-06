//
//  JarvisDuplexAudio.swift
//  Devgentic
//
//  [Phase 4b] Owns the duplex audio engine for the lifetime of a PANEL session, rather than a
//  single stream session.
//
//  WHY THE LIFETIME HAD TO MOVE. Measured on device 2026-09-05: VoiceProcessingIO captures
//  perfectly when its engine is the first audio client (`JarvisMicProbe` — 20 buffers in 2 s, a
//  2-channel tap), and captures NOTHING inside a live Jarvis session, where the tap comes up
//  3-channel — the raw mic-array format the input node falls back to when the VP aggregate never
//  finishes configuring. The difference is what happens immediately before: the engine used to be
//  built per stream session, so every turn constructed voice processing seconds after
//  `AVSpeechSynthesizer` released its own audio unit. A 1 s `audioSettleDelay` and explicit
//  `releaseAudio()` on both synthesizers were not enough.
//
//  So the engine is now built ONCE, at panel open, BEFORE Jarvis speaks — the condition it is
//  proven healthy under — and survives every turn until the panel closes.
//
//  ⚠️⚠️ THIS WIDENS A KNOWN HAZARD. A live `AVAudioEngine` at process death wedges `coreaudiod`
//  into `_StartIO error 35`: an app-wide dead microphone that survives relaunch and needs an admin
//  `killall coreaudiod` to clear. It has happened twice (2026-07-18, 2026-09-04). Previously an
//  engine existed only for the seconds of an active turn; now it spans the session. Every graceful
//  release path is therefore wired explicitly, and `releaseWhenIdle()` gives the exposure back on
//  long idles. Crash / force-quit / SIGKILL remain structurally uncoverable — `JarvisAudioRepair`
//  is the remedy and stays reachable from Settings without the orb.
//
//  ⚠️ THE ADMISSION GATES ARE NOT OPTIONAL. Each one exists because of something that broke:
//   • `activeVoiceOwner == nil` — the duplex processor used to be built AFTER
//     `VoiceSessionLedger.begin(owner:)`, which is the app's only capture-serialisation
//     mechanism. Warming at panel open happens BEFORE the ledger, so without this gate opening the
//     orb during composer dictation would put two live input engines on one device — one of them
//     voice-processing, which is plausibly the very thing that kills VP.
//   • `activationMode.listensContinuously` — hold-to-talk exists to keep the microphone CLOSED at
//     rest. A panel-scoped engine holds the input device, and macOS's orange indicator, for as
//     long as the orb is open. Warming in that mode would break the promise the mode is named for.
//   • `recognizer == .whisperKit` — the Apple Speech path builds its OWN engine through the same
//     builder. `AVAudioNode` allows one tap per bus, so sharing is not a small change; not warming
//     is the correct first answer.
//

import Foundation
import AVFoundation

@MainActor
final class JarvisDuplexAudio {

    static let shared = JarvisDuplexAudio()

    private let logger = DGLogger(category: "JarvisDuplexAudio")
    /// ⚠️ Set by the session controller. This type is panel-session-scoped but its lines carried no
    /// `[s:…]`, so across several orb open/close cycles in one device test there was no way to
    /// attribute an engine line to the session that produced it — which is exactly the question
    /// asked when one of several attempts misbehaves.
    var correlationTag: String = ""
    private var processor: JarvisAudioProcessor?
    private var warmingTask: Task<Bool, Never>?
    /// ⚠️ Set by `release`, cleared by `warm`. `Task.cancel()` is cooperative: a build already past
    /// its last suspension point runs to completion regardless, so the latch — not cancellation —
    /// is what stops an engine being installed onto a torn-down panel.
    private var released = false

    private var configurationObserver: NSObjectProtocol?

    private init() {
        // ⚠️ Nothing in the app observed this. The notification is the ONLY signal that macOS has
        // stopped the engine out from under us; without it a device change is silent and every
        // later turn is deaf with no line in the log saying why.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    /// The audio device changed. macOS has already stopped the engine by the time this arrives.
    private func handleConfigurationChange() {
        guard let processor, processor.engine != nil else { return }
        let stillRunning = processor.engine?.isRunning == true
        logger.notice("[JARVIS_DUPLEX_AUDIO]\(self.correlationTag) Audio configuration changed — an input or output device was swapped. Engine still running: \(stillRunning). CONSEQUENCE: \(stillRunning ? "no action needed" : "the system stopped the engine; rebuilding now, because otherwise every later turn opens a microphone that delivers nothing").")
        guard !stillRunning else { return }
        Task { await rebuild(reason: "audio device changed") }
    }

    /// True when an engine is up AND RUNNING.
    ///
    /// ⚠️ `processor != nil` is not enough. macOS STOPS an `AVAudioEngine` and posts
    /// `.AVAudioEngineConfigurationChange` whenever the input or output device changes — connect
    /// AirPods, unplug an interface — and the object survives. Reporting warmth on identity alone
    /// meant `warm()` short-circuited, `borrow()` handed a DEAD engine to WhisperKit, and the
    /// settle was skipped: every turn afterwards opened a microphone that delivered nothing, which
    /// is indistinguishable from the dead-mic bug this subsystem spent six device rounds chasing.
    var isWarm: Bool { processor?.engine?.isRunning == true }

    /// ⚠️ The only honest basis for enabling barge-in. Voice processing can be requested, report
    /// success, and still be inert; this reflects what the engine ACTUALLY has after any
    /// mid-session downgrade.
    var isEchoCancelling: Bool { isWarm && processor?.voiceProcessingEnabled == true }

    // MARK: - Lifecycle

    /// Builds the engine if every gate allows it. Safe to call repeatedly; concurrent callers
    /// await the same attempt rather than racing two engines onto one device.
    @discardableResult
    func warm(reason: String) async -> Bool {
        if let warmingTask { return await warmingTask.value }
        if processor != nil { return true }

        guard let refusal = refusalReason() else {
            let task = Task<Bool, Never> { [weak self] in
                guard let self else { return false }
                return await self.build(reason: reason)
            }
            warmingTask = task
            let result = await task.value
            warmingTask = nil
            return result
        }
        logger.info("[JARVIS_DUPLEX_AUDIO]\(self.correlationTag) Not warming (\(reason)) — \(refusal). CONSEQUENCE: this session runs on WhisperKit's own engine; capture works, there is no echo cancellation, and Jarvis keeps closing the microphone while it speaks.")
        return false
    }

    /// The reason warming is refused, or nil if it may proceed.
    private func refusalReason() -> String? {
        let config = JarvisConfigManager.shared
        return Self.refusal(
            duplexEnabled: config.duplexAudioEnabled,
            recognizer: config.recognizer,
            activationMode: config.activationMode,
            activeVoiceOwner: WhisperRecognitionService.shared.activeVoiceOwner
        )
    }

    /// Pure so the policy can be pinned by tests without an audio device or a live panel.
    /// ⚠️ Each clause is a bug that already happened; see the admission-gate note in the header.
    nonisolated static func refusal(duplexEnabled: Bool,
                        recognizer: JarvisRecognizer,
                        activationMode: JarvisActivationMode,
                        activeVoiceOwner: VoiceSurface?) -> String? {
        guard duplexEnabled else { return "duplex audio is off in Settings" }
        guard !recognizer.isAppleSpeech else {
            return "the Apple Speech recognizer builds its own engine"
        }
        guard activationMode.listensContinuously else {
            return "hold-to-talk keeps the microphone closed at rest, and a warm engine would hold the device (and the orange indicator) for the whole session"
        }
        if let activeVoiceOwner {
            return "\(activeVoiceOwner.rawValue) already holds the microphone — a second input engine on one device is what breaks capture"
        }
        return nil
    }

    private func build(reason: String) async -> Bool {
        released = false
        guard await AVAudioApplication.requestRecordPermission() else {
            logger.info("[JARVIS_DUPLEX_AUDIO]\(self.correlationTag) Not warming (\(reason)) — microphone permission denied. CONSEQUENCE: none here; the listening loop surfaces the permission error itself.")
            return false
        }
        // Await rather than block: `make(...)`'s synchronous wait exists only for the non-async
        // `AudioProcessing.startRecordingLive`, and stalls the main thread when it fires.
        await JarvisAudioEngineBuilder.awaitDeviceRelease(logger: logger)

        // ⚠️ The ADMISSION GATE is re-checked here too, not just `released`. Another surface can
        // claim the microphone during the permission prompt or the 0.4 s settle — the ledger only
        // checks `active == nil` — and a VoiceProcessingIO engine started on top of WhisperKit's
        // own is the two-engines-on-one-device condition that breaks capture outright.
        if let refusal = refusalReason() {
            logger.notice("[JARVIS_DUPLEX_AUDIO]\(self.correlationTag) Warm (\(reason)) abandoned after waiting — \(refusal). CONSEQUENCE: no engine was started; this session runs without echo cancellation rather than putting a second input engine on the device.")
            return false
        }

        // Re-checked after BOTH awaits above: the panel can close during a permission prompt or a
        // 400 ms device settle, and starting here would strand a live engine.
        guard !released else {
            logger.info("[JARVIS_DUPLEX_AUDIO]\(self.correlationTag) Warm (\(reason)) abandoned — released while waiting. CONSEQUENCE: no engine was started; the device stays free.")
            return false
        }

        let processor = JarvisAudioProcessor()
        processor.correlationTag = correlationTag
        do {
            try processor.startEngine()
            guard !released else {
                // Lost the race by a hair. Stop what we just started rather than leak it.
                processor.stopEngine(reason: "released during engine start")
                logger.notice("[JARVIS_DUPLEX_AUDIO]\(self.correlationTag) Warm (\(reason)) completed into a released panel — the engine was stopped immediately. CONSEQUENCE: none; without this it would have outlived the panel and could wedge coreaudiod at process death.")
                return false
            }
            self.processor = processor
            logger.notice("[JARVIS_DUPLEX_AUDIO]\(self.correlationTag) Engine WARMED (\(reason)) — echo cancellation: \(processor.voiceProcessingEnabled). It now survives every turn until the panel closes.")
            return true
        } catch {
            logger.error("[JARVIS_DUPLEX_AUDIO]\(self.correlationTag) Could not warm the engine (\(reason)): \(error.localizedDescription). CONSEQUENCE: turns fall back to WhisperKit's own engine — capture still works, without echo cancellation.")
            return false
        }
    }

    /// Hands the warm engine to a stream session. Never starts anything: a cold engine means the
    /// caller uses WhisperKit's own, which is the documented fallback.
    func borrow(for owner: VoiceSurface) -> JarvisAudioProcessor? {
        guard owner == .jarvis else { return nil }
        guard JarvisConfigManager.shared.duplexAudioEnabled else {
            // Toggled off mid-session. Releasing here matters: WhisperKit would otherwise build
            // its own engine on a device this one still holds.
            if processor != nil { release(reason: "duplex audio switched off mid-session") }
            return nil
        }
        guard let processor else {
            logger.info("[JARVIS_DUPLEX_AUDIO]\(self.correlationTag) Duplex is ON but the engine is cold — this turn runs without echo cancellation. CONSEQUENCE: Jarvis still closes the microphone while it speaks; barge-in is unavailable this turn.")
            return nil
        }
        return processor
    }

    /// Synchronous and idempotent, because every caller is a teardown path that must not be
    /// allowed to return before the device is released.
    func release(reason: String) {
        // ⚠️ CANCEL FIRST, AND UNCONDITIONALLY. `processor` is still nil while `warm()` is in
        // flight, so guarding on it made every teardown path a silent no-op during exactly the
        // window that matters — `build()` would then finish and install an engine on a panel that
        // no longer exists, reachable only by the app-termination hook. That is the
        // coreaudiod-wedge shape, and it also defeated repairAudio's release-before-killall order.
        warmingTask?.cancel()
        warmingTask = nil
        released = true

        guard let processor else {
            logger.info("[JARVIS_DUPLEX_AUDIO]\(self.correlationTag) Release (\(reason)) with no engine up — any in-flight warm is cancelled and will not install one. CONSEQUENCE: none; the device is free.")
            return
        }
        self.processor = nil
        processor.stopEngine(reason: "panel-scoped release (\(reason))")
        logger.notice("[JARVIS_DUPLEX_AUDIO]\(self.correlationTag) Engine RELEASED (\(reason)).")
    }

    /// Release then warm — for repair and for settings changes that invalidate the current engine.
    func rebuild(reason: String) async {
        release(reason: reason)
        await warm(reason: reason)
    }

    /// ⚠️ The only lever that shrinks the crash-wedge window back toward the old stream-scoped
    /// exposure. Called when the session parks somewhere it will not listen from for a while.
    func releaseWhenIdle(reason: String) {
        // ⚠️⚠️ NO `guard processor != nil`. This method HAD one, which is exactly the mistake
        // `release(reason:)` documents fixing eight lines above: `processor` is still nil while
        // `warm()` is in flight, so guarding on it made this a silent no-op during precisely the
        // window that matters — the in-flight `build()` would then finish and install a live engine
        // into the idle park this call exists to prevent, reachable only by the app-termination
        // hook. That is the coreaudiod-wedge shape.
        //
        // It is reachable: a park can arrive inside the 0.4 s device settle of a warm started
        // moments earlier. `release` is idempotent and cancels the warm unconditionally, so
        // delegating without a pre-check is both simpler and the only correct form.
        let wasUp = processor != nil
        logger.info("[JARVIS_DUPLEX_AUDIO]\(self.correlationTag) Releasing while idle (\(reason)) — engine was \(wasUp ? "up" : "cold or still warming"). CONSEQUENCE: the next turn pays one engine rebuild; in exchange the microphone and its indicator are not held, any in-flight warm is cancelled rather than completing into an idle session, and a crash here cannot wedge coreaudiod.")
        release(reason: "idle — \(reason)")
    }

    // MARK: - Playback target

    /// The node Jarvis's speech must be rendered into for echo cancellation to have anything to
    /// subtract. Nil unless the engine is up AND actually cancelling — routing speech through a
    /// non-VP engine buys nothing and costs a conversion.
    var playbackTarget: (player: AVAudioPlayerNode, format: AVAudioFormat)? {
        // ⚠️ `isEchoCancelling` (not the raw flag) so a stopped engine is never handed a sentence:
        // `player.play()` on a stopped engine is a crash, not a silent no-op.
        guard isEchoCancelling, let processor, let player = processor.playerNode else { return nil }
        return (player, player.outputFormat(forBus: 0))
    }
}

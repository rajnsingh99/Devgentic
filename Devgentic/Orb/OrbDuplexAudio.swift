// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbDuplexAudio.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import AVFoundation

// Why: a live AVAudioEngine at process death wedges coreaudiod (_StartIO error 35),
// leaving the microphone dead app-wide until `killall coreaudiod`.
/// Owns the duplex audio engine for the lifetime of a panel session rather than a single stream session.
/// Built once at panel open, before Orb speaks, and kept across turns; `releaseWhenIdle()` returns it on long idles.
@MainActor
final class OrbDuplexAudio {

    static let shared = OrbDuplexAudio()

    private let logger = DGLogger(category: "OrbDuplexAudio")
    /// Set by the session controller; tags this type's log lines with the session that produced them (`[s:…]`).
    var correlationTag: String = "" {
        // Propagated on every change, not only at warm time: the engine can be warmed between panel sessions, so a
        // processor tagged only when built would carry the previous session's tag.
        didSet { processor?.correlationTag = correlationTag }
    }
    private var processor: OrbAudioProcessor?
    private var warmingTask: Task<Bool, Never>?
    // Why: Task.cancel() is cooperative: a build past its last suspension point completes regardless.
    /// Latch set by `release` and cleared by `warm`, preventing an engine from being installed on a torn-down panel.
    private var released = false

    private var configurationObserver: NSObjectProtocol?

    private init() {
        // The configuration-change notification is the only signal that macOS has stopped the engine;
        // without it a device change leaves every later turn deaf with nothing in the log.
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
        logger.notice("[ORB_DUPLEX_AUDIO]\(self.correlationTag) Audio configuration changed — an input or output device was swapped. Engine still running: \(stillRunning). CONSEQUENCE: \(stillRunning ? "no action needed" : "the system stopped the engine; rebuilding now, because otherwise every later turn opens a microphone that delivers nothing").")
        guard !stillRunning else { return }
        Task { await rebuild(reason: "audio device changed") }
    }

    /// True when an engine is up and running.
    /// `processor != nil` is not enough: macOS stops the engine on any device change while the object survives.
    /// Reporting warmth on identity alone would hand a dead engine to WhisperKit.
    var isWarm: Bool { processor?.engine?.isRunning == true }

    /// The only honest basis for enabling barge-in.
    /// Voice processing can be requested, report success and still be inert; this reflects what the engine actually has.
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
        logger.info("[ORB_DUPLEX_AUDIO]\(self.correlationTag) Not warming (\(reason)) — \(refusal). CONSEQUENCE: this session runs on WhisperKit's own engine; capture works, there is no echo cancellation, and Orb keeps closing the microphone while it speaks.")
        return false
    }

    /// The reason warming is refused, or nil if it may proceed.
    private func refusalReason() -> String? {
        let config = OrbConfigManager.shared
        return Self.refusal(
            duplexEnabled: config.duplexAudioEnabled,
            recognizer: config.recognizer,
            activationMode: config.activationMode,
            activeVoiceOwner: WhisperRecognitionService.shared.activeVoiceOwner
        )
    }

    /// Pure so the policy can be tested without an audio device or a live panel.
    /// Each clause guards a condition that breaks audio capture.
    nonisolated static func refusal(duplexEnabled: Bool,
                        recognizer: OrbRecognizer,
                        activationMode: OrbActivationMode,
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
            logger.info("[ORB_DUPLEX_AUDIO]\(self.correlationTag) Not warming (\(reason)) — microphone permission denied. CONSEQUENCE: none here; the listening loop surfaces the permission error itself.")
            return false
        }
        // Await rather than block: `make(...)`'s synchronous wait exists only for the non-async
        // `AudioProcessing.startRecordingLive`, and stalls the main thread when it fires.
        await OrbAudioEngineBuilder.awaitDeviceRelease(logger: logger)

        // The admission gate is re-checked here too, not just `released`: another surface can claim the microphone during
        // the permission prompt or the settle, and two engines on one device break capture outright.
        if let refusal = refusalReason() {
            logger.notice("[ORB_DUPLEX_AUDIO]\(self.correlationTag) Warm (\(reason)) abandoned after waiting — \(refusal). CONSEQUENCE: no engine was started; this session runs without echo cancellation rather than putting a second input engine on the device.")
            return false
        }

        // Re-checked after BOTH awaits above: the panel can close during a permission prompt or a
        // 400 ms device settle, and starting here would strand a live engine.
        guard !released else {
            logger.info("[ORB_DUPLEX_AUDIO]\(self.correlationTag) Warm (\(reason)) abandoned — released while waiting. CONSEQUENCE: no engine was started; the device stays free.")
            return false
        }

        let processor = OrbAudioProcessor()
        processor.correlationTag = correlationTag
        do {
            try processor.startEngine()
            guard !released else {
                // Lost the race by a hair. Stop what we just started rather than leak it.
                processor.stopEngine(reason: "released during engine start")
                logger.notice("[ORB_DUPLEX_AUDIO]\(self.correlationTag) Warm (\(reason)) completed into a released panel — the engine was stopped immediately. CONSEQUENCE: none; without this it would have outlived the panel and could wedge coreaudiod at process death.")
                return false
            }
            self.processor = processor
            logger.notice("[ORB_DUPLEX_AUDIO]\(self.correlationTag) Engine WARMED (\(reason)) — echo cancellation: \(processor.voiceProcessingEnabled). It now survives every turn until the panel closes.")
            return true
        } catch {
            logger.error("[ORB_DUPLEX_AUDIO]\(self.correlationTag) Could not warm the engine (\(reason)): \(error.localizedDescription). CONSEQUENCE: turns fall back to WhisperKit's own engine — capture still works, without echo cancellation.")
            return false
        }
    }

    /// Hands the warm engine to a stream session. Never starts anything: a cold engine means the
    /// caller uses WhisperKit's own, which is the documented fallback.
    func borrow(for owner: VoiceSurface) -> OrbAudioProcessor? {
        guard owner == .orb else { return nil }
        guard OrbConfigManager.shared.duplexAudioEnabled else {
            // Toggled off mid-session. Releasing here matters: WhisperKit would otherwise build
            // its own engine on a device this one still holds.
            if processor != nil { release(reason: "duplex audio switched off mid-session") }
            return nil
        }
        guard let processor else {
            logger.info("[ORB_DUPLEX_AUDIO]\(self.correlationTag) Duplex is ON but the engine is cold — this turn runs without echo cancellation. CONSEQUENCE: Orb still closes the microphone while it speaks; barge-in is unavailable this turn.")
            return nil
        }
        return processor
    }

    /// Synchronous and idempotent, because every caller is a teardown path that must not be
    /// allowed to return before the device is released.
    func release(reason: String) {
        // Cancel first and unconditionally: `processor` is still nil while `warm()` is in flight, so guarding on it
        // would make teardown a no-op and let `build()` install an engine on a panel that is already gone.
        warmingTask?.cancel()
        warmingTask = nil
        released = true

        guard let processor else {
            logger.info("[ORB_DUPLEX_AUDIO]\(self.correlationTag) Release (\(reason)) with no engine up — any in-flight warm is cancelled and will not install one. CONSEQUENCE: none; the device is free.")
            return
        }
        self.processor = nil
        processor.stopEngine(reason: "panel-scoped release (\(reason))")
        logger.notice("[ORB_DUPLEX_AUDIO]\(self.correlationTag) Engine RELEASED (\(reason)).")
    }

    /// Release then warm — for repair and for settings changes that invalidate the current engine.
    func rebuild(reason: String) async {
        release(reason: reason)
        await warm(reason: reason)
    }

    /// Releases the engine when the session parks somewhere it will not listen from for a while.
    /// The only lever that shrinks the crash-wedge window back toward stream-scoped exposure.
    func releaseWhenIdle(reason: String) {
        // No `guard processor != nil`: it is still nil while `warm()` is in flight, so a guard would make this a no-op
        // and the in-flight `build()` would install a live engine. `release` is idempotent and cancels the warm itself.
        let wasUp = processor != nil
        logger.info("[ORB_DUPLEX_AUDIO]\(self.correlationTag) Releasing while idle (\(reason)) — engine was \(wasUp ? "up" : "cold or still warming"). CONSEQUENCE: the next turn pays one engine rebuild; in exchange the microphone and its indicator are not held, any in-flight warm is cancelled rather than completing into an idle session, and a crash here cannot wedge coreaudiod.")
        release(reason: "idle — \(reason)")
    }

    // MARK: - Playback target

    /// The node Orb's speech must be rendered into for echo cancellation to have anything to
    /// subtract. Nil unless the engine is up AND actually cancelling — routing speech through a
    /// non-VP engine buys nothing and costs a conversion.
    var playbackTarget: (player: AVAudioPlayerNode, format: AVAudioFormat)? {
        // `isEchoCancelling` (not the raw flag) so a stopped engine is never handed a sentence: `player.play()` on a
        // stopped engine crashes.
        guard isEchoCancelling, let processor, let player = processor.playerNode else { return nil }
        return (player, player.outputFormat(forBus: 0))
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbSpeechRecognizer.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import AVFoundation
import Speech

/// An alternative Orb recognizer built on Apple's macOS 26 `SpeechAnalyzer`.
/// A long-lived actor with an explicit `isFinal` per result, so a send can fire the instant the transcriber finalizes.
@available(macOS 26.0, *)
final class OrbSpeechRecognizer {

    /// Whether this machine can run the Apple recognizer at all.
    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// Whether the audio tap has delivered any buffer this session.
    /// The honest liveness signal here: `handle(_:)` emits no per-buffer energy, so text cannot tell a dead mic from silence.
    /// A healthy engine delivers buffers within ~100 ms whether or not anyone is talking.
    var hasReceivedAudio: Bool {
        if tapDeliveredAudio { return true }
        return tapAdapter?.snapshot.sawAudio ?? false
    }

    private let logger = DGLogger(category: "OrbAppleSpeech")
    /// Set by the session controller so Apple Speech lines carry the same `[s:…]` as the rest.
    var correlationTag: String = ""

    private var engine: AVAudioEngine?
    /// Owns format discovery, downmixing and drop accounting for this session's tap.
    private var tapAdapter: OrbTapAdapter?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var detector: SpeechDetector?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var detectorTask: Task<Void, Never>?

    /// Text finalized so far this session plus the volatile hypothesis, mapped onto the same `StreamingTranscriptionState`
    /// the WhisperKit path emits, so every consumer works unchanged.
    private var finalizedText = ""
    private var volatileText = ""
    private var sawAnyResult = false
    /// Latched copy of the tap's liveness, because `stop()` releases the adapter that owns it; otherwise the
    /// dead-session verdict would depend on whether the caller asks before or after stopping.
    private var tapDeliveredAudio = false
    private var onUpdate: ((StreamingTranscriptionState) -> Void)?
    /// Fired when the transcriber marks a result final — the whole point of this recognizer.
    private var onFinalized: (() -> Void)?

    // MARK: - Lifecycle

    /// Starts recognition. Non-blocking, unlike WhisperKit's `startStreaming` — results arrive on
    /// `onUpdate` and `onFinalized` until `stop()`.
    func start(
        locale: Locale = OrbConfigManager.shared.speechLocale,
        voiceProcessing: Bool,
        onUpdate: @escaping (StreamingTranscriptionState) -> Void,
        onFinalized: @escaping () -> Void
    ) async throws {
        guard Self.isAvailable else {
            logger.error("[ORB_APPLE_ASR]\(self.correlationTag) SpeechTranscriber.isAvailable is false on this machine. CONSEQUENCE: the Apple recognizer cannot be used; the caller must fall back to WhisperKit.")
            throw OrbSpeechRecognizerError.unavailable
        }
        self.onUpdate = onUpdate
        self.onFinalized = onFinalized
        finalizedText = ""
        volatileText = ""
        sawAnyResult = false
        tapDeliveredAudio = false

        // Resolve and reserve the locale first: `SpeechTranscriber` does not throw for an unallocated locale, it warns
        // and transcribes in a degraded mode, so reserving is required for correct output.
        let resolved = await Self.resolveLocale(locale, logger: logger)
        guard let resolvedLocale = resolved else {
            logger.error("[ORB_APPLE_ASR]\(self.correlationTag) No supported Apple Speech locale equivalent to \(locale.identifier). CONSEQUENCE: refusing to start rather than transcribing in a degraded mode — the caller falls back to WhisperKit.")
            throw OrbSpeechRecognizerError.localeUnsupported(locale.identifier)
        }

        // `.progressiveTranscription` is the preset that reports volatile hypotheses as well as
        // finalized text — without it there is nothing to show in the orb's live caption.
        let transcriber = SpeechTranscriber(locale: resolvedLocale, preset: .progressiveTranscription)
        // Explicit sensitivity rather than the convenience init: the level is the only tuning this module exposes.
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: true
        )
        self.transcriber = transcriber
        self.detector = detector

        try await Self.reserveAndInstall(locale: resolvedLocale, modules: [transcriber, detector], logger: logger)

        // The ANALYZER chooses the format; we convert to it. Doing it the other way round is the
        // silent-failure path.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber, detector]
        ) else {
            logger.error("[ORB_APPLE_ASR]\(self.correlationTag) No compatible audio format for the transcriber on this locale/machine. CONSEQUENCE: cannot start; falling back to WhisperKit.")
            throw OrbSpeechRecognizerError.noCompatibleFormat
        }

        // Async path: settle by awaiting rather than stalling the UI.
        await OrbAudioEngineBuilder.awaitDeviceRelease(logger: logger)
        let graph = try OrbAudioEngineBuilder.make(voiceProcessing: voiceProcessing, logger: logger)
        // Not `AVAudioConverter(from: graph.tapFormat, …)`: that format is read before the engine starts and voice processing
        // renegotiates it, yielding silence with no error. The adapter builds its converter from the first real buffer.
        let adapter = OrbTapAdapter(predicted: graph.tapFormat, target: analyzerFormat, tag: "[ORB_APPLE_ASR]", logger: logger)
        self.tapAdapter = adapter

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        // Shared with the WhisperKit path: settles the device, installs at the format the bus
        // actually has, and retries once if the hardware moves between install and start.
        try OrbAudioEngineBuilder.installTapAndStart(graph, tapSeconds: 0.1, logger: logger) { buffer in
            guard let converted = adapter.adapt(buffer) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        self.engine = graph.engine

        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber, detector])
        self.analyzer = analyzer

        // Consume BEFORE returning so no early result is dropped.
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    await self.handle(result)
                }
            } catch {
                self.logger.error("[ORB_APPLE_ASR]\(self.correlationTag) Result stream ended with an error: \(error.localizedDescription). CONSEQUENCE: no further transcription this session; the caller's watchdog ends the turn.")
            }
        }

        detectorTask = Task { [weak self] in
            guard let self else { return }
            // Real ML voice activity, rather than a buffer-energy counter that fires on fan hum.
            do {
                for try await result in detector.results {
                    // Real ML voice activity — logged at debug so a device test can correlate it
                    // with what the transcriber did, without flooding the info stream.
                    self.logger.debug("[ORB_APPLE_ASR]\(self.correlationTag) speechDetected: \(result.speechDetected)")
                }
            } catch {
                self.logger.info("[ORB_APPLE_ASR]\(self.correlationTag) Voice-activity stream ended: \(error.localizedDescription). CONSEQUENCE: transcription continues; only the barge-in trigger is lost this session.")
            }
        }

        logger.notice("[ORB_APPLE_ASR]\(self.correlationTag) STARTED — locale \(resolvedLocale.identifier) (requested \(locale.identifier)), analyzer format \(String(format: "%.0f", analyzerFormat.sampleRate)) Hz / \(analyzerFormat.channelCount) ch, voiceProcessing: \(graph.voiceProcessingEnabled).")
    }

    /// Stops recognition and returns the final transcript.
    @discardableResult
    func stop(reason: String = "finished") async -> String {
        inputContinuation?.finish()
        inputContinuation = nil
        // Flush anything still in flight so a command spoken right before the stop is not lost.
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                // This flush exists so a command spoken right before the stop is not lost; a swallowed throw would truncate it silently.
                logger.error("[ORB_APPLE_ASR]\(self.correlationTag) Final flush FAILED: \(error.localizedDescription). CONSEQUENCE: anything said in the last moment before stopping is missing from the transcript — the command may be truncated with no other sign.")
            }
        }
        resultsTask?.cancel(); resultsTask = nil
        detectorTask?.cancel(); detectorTask = nil

        if let tapAdapter {
            // Latch before releasing the adapter: `hasReceivedAudio` is read by the dead-microphone check, which runs after this.
            tapDeliveredAudio = tapAdapter.snapshot.sawAudio
            logger.notice("[ORB_APPLE_ASR]\(self.correlationTag) Tap summary — \(tapAdapter.summary()).")
        }
        tapAdapter = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        if engine != nil { OrbAudioEngineBuilder.noteTeardown() }
        engine = nil
        analyzer = nil
        transcriber = nil
        detector = nil

        let text = StreamingTranscriptionState.joined(confirmed: finalizedText, partial: volatileText)
        // Only a session that actually ran can prove a format mismatch; a superseded or cancelled session has no results.
        if !sawAnyResult, reason == "finished" {
            // The silent-failure signature this recognizer is most likely to hit: a clean compile,
            // a running engine, and no results at all because the format negotiation was wrong.
            logger.error("[ORB_APPLE_ASR]\(self.correlationTag) Session produced ZERO results. CONSEQUENCE: nothing was heard — this is the format-mismatch signature, not a quiet room; compare the analyzer and tap formats logged at START.")
        } else {
            logger.notice("[ORB_APPLE_ASR]\(self.correlationTag) STOPPED — \(text.split(separator: " ").count) word(s) transcribed.")
        }
        onUpdate = nil
        onFinalized = nil
        return text
    }

    // MARK: - Locale + on-device assets

    /// Returns the supported locale closest to `requested`, or nil if the language is unavailable.
    /// Uses the framework's matcher, not string comparison: `en_IN` has a supported equivalent not listed verbatim.
    private static func resolveLocale(_ requested: Locale, logger: DGLogger) async -> Locale? {
        if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            if equivalent.identifier != requested.identifier {
                logger.notice("[ORB_APPLE_ASR] Locale \(requested.identifier) is not supported directly; using the equivalent \(equivalent.identifier). CONSEQUENCE: recognition runs against that variant's model, which may differ slightly in accent handling.")
            }
            return equivalent
        }
        let supported = await SpeechTranscriber.supportedLocales
        logger.error("[ORB_APPLE_ASR] \(requested.identifier) has no supported equivalent among \(supported.count) locale(s).")
        return nil
    }

    // Why: skipping `AssetInventory.reserve` does not fail but silently degrades transcription.
    /// Reserves the locale and installs its on-device model if needed.
    /// A reserve can fail (cap `maximumReservedLocales`); the failure is reported, not swallowed.
    private static func reserveAndInstall(locale: Locale,
                                          modules: [any SpeechModule],
                                          logger: DGLogger) async throws {
        let alreadyReserved = await AssetInventory.reservedLocales
        if !alreadyReserved.contains(where: { $0.identifier == locale.identifier }) {
            do {
                let reserved = try await AssetInventory.reserve(locale: locale)
                logger.notice("[ORB_APPLE_ASR] Reserved locale \(locale.identifier): \(reserved) (was holding \(alreadyReserved.count)/\(AssetInventory.maximumReservedLocales)).")
                if !reserved {
                    logger.error("[ORB_APPLE_ASR] Locale reservation returned false — the reserved-locale limit (\(AssetInventory.maximumReservedLocales)) is likely full. CONSEQUENCE: recognition would run UNALLOCATED and produce degraded text; refusing to start so the caller falls back to WhisperKit.")
                    throw OrbSpeechRecognizerError.localeUnavailable(locale.identifier)
                }
            } catch let error as OrbSpeechRecognizerError {
                throw error
            } catch {
                logger.error("[ORB_APPLE_ASR] Reserving locale \(locale.identifier) FAILED: \(error.localizedDescription). CONSEQUENCE: refusing to start rather than transcribing degraded; the caller falls back to WhisperKit.")
                throw error
            }
        }

        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            logger.info("[ORB_APPLE_ASR] On-device model for \(locale.identifier) is installed.")
        case .supported, .downloading:
            logger.notice("[ORB_APPLE_ASR] On-device model for \(locale.identifier) is not installed yet — downloading. CONSEQUENCE: the first session waits for the download; later ones do not.")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
                logger.notice("[ORB_APPLE_ASR] On-device model install complete for \(locale.identifier).")
            } else {
                logger.info("[ORB_APPLE_ASR] No installation request needed for \(locale.identifier).")
            }
        case .unsupported:
            logger.error("[ORB_APPLE_ASR] Apple Speech reports \(locale.identifier) UNSUPPORTED for these modules. CONSEQUENCE: refusing to start; the caller falls back to WhisperKit.")
            throw OrbSpeechRecognizerError.localeUnsupported(locale.identifier)
        @unknown default:
            logger.warning("[ORB_APPLE_ASR] Unrecognised asset status for \(locale.identifier) — proceeding, but transcription quality is unverified.")
        }
    }

    // MARK: - Results

    private func handle(_ result: SpeechTranscriber.Result) async {
        sawAnyResult = true
        let text = String(result.text.characters)
        if result.isFinal {
            finalizedText = StreamingTranscriptionState.joined(confirmed: finalizedText, partial: text)
            volatileText = ""
        } else {
            volatileText = text
        }
        // Mapped onto the SAME bridge type the WhisperKit path emits, so nothing downstream knows
        // or cares which recognizer produced it.
        onUpdate?(StreamingTranscriptionState(
            confirmedText: finalizedText,
            partialText: volatileText,
            bufferEnergy: [],
            isRecording: true,
            isSilenceDetected: false
        ))
        if result.isFinal {
            logger.info("[ORB_APPLE_ASR]\(self.correlationTag) Result FINALIZED — dispatching immediately rather than waiting out a stability window.")
            onFinalized?()
        }
    }

}

// MARK: - Errors

enum OrbSpeechRecognizerError: LocalizedError {
    case unavailable
    case noCompatibleFormat
    case localeUnsupported(String)
    case localeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return String(localized: "Apple's on-device speech recognizer isn't available on this Mac.")
        case .noCompatibleFormat:
            return String(localized: "Apple's speech recognizer has no compatible audio format for this language.")
        case .localeUnsupported(let identifier):
            return String(localized: "Apple's speech recognizer doesn't support \(identifier).")
        case .localeUnavailable(let identifier):
            return String(localized: "Apple's speech recognizer couldn't reserve a model for \(identifier).")
        }
    }
}

// MARK: - One-shot gate

/// Bridges the Apple recognizer's callbacks into the listening loop's sequential shape.
/// Resumes exactly once, whichever edge arrives first (final result, capture cap, follow-up expiry, new generation);
/// a double resume traps and a missed one parks the turn forever.
@MainActor
final class OrbOneShot {
    private var continuation: CheckedContinuation<String, Never>?
    private var resolved: String?

    func wait() async -> String {
        if let resolved { return resolved }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ reason: String) {
        guard resolved == nil else { return }
        resolved = reason
        continuation?.resume(returning: reason)
        continuation = nil
    }
}

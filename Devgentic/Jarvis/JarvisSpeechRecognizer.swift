// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  JarvisSpeechRecognizer.swift
//  Devgentic
//
//  [Phase 5] Apple's macOS 26 `SpeechAnalyzer` as an alternative recognizer for Jarvis.
//
//  WHY: WhisperKit's `AudioStreamTranscriber` re-decodes its whole un-purged buffer, which is why
//  Jarvis has to recycle passive sessions every 45s, and it reports no finality — so Jarvis infers
//  "you stopped talking" from 2.2s of textual stability on a punctuation-stripped projection of
//  the transcript. `SpeechAnalyzer` is a long-lived actor with an explicit `isFinal` per result:
//  no per-turn restart, no growing buffer, no model download, and the send can fire the INSTANT
//  the transcriber finalizes instead of 2.2s later.
//
//  ⚠️ DEFAULT OFF, Developer mode. Never exercised against a real microphone.
//
//  VERIFIED AGAINST THE INSTALLED SDK (Speech.swiftmodule/arm64e-apple-macos.swiftinterface),
//  not against recall — Phase 4 taught that a confident plan can be wrong on its load-bearing API:
//   • `SpeechAnalyzer` is a `final public actor` (:223) — every call to it is `await`.
//   • `init(inputSequence:modules:options:analysisContext:volatileRangeChangedHandler:)` (:229)
//     requires `InputSequence.Element == AnalyzerInput`, and `AnalyzerInput(buffer:)` (:294) is
//     the only wrapper needed.
//   • `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` is `static async -> AVAudioFormat?`
//     (:278) — the analyzer tells US its format; we convert the tap to it.
//   • `SpeechTranscriber(locale:preset:)` (:408) with `.progressiveTranscription` (:414).
//   • `SpeechTranscriber.Result` (:495) carries `text: AttributedString`, and `isFinal` comes from
//     the `SpeechModuleResult` extension (:384).
//   • `SpeechDetector.Result` (:347) carries `speechDetected: Bool` — real ML voice activity,
//     which is also the future barge-in trigger once duplex playback lands.
//   • `SpeechTranscriber.isAvailable` (:474) gates adoption.
//  ⚠️⚠️ The convenience types every write-up mentions — `CaptureInputSequenceProvider`,
//  `AssetInputSequenceProvider`, `AnalyzerInputConverter` — **DO NOT EXIST** in this SDK. I
//  grepped: zero occurrences. The tap → converter → AsyncStream plumbing below is hand-rolled
//  because it has to be, and a format mismatch here compiles cleanly and produces TOTAL SILENCE.
//  That is why the negotiated format is logged and a zero-result session is reported loudly.
//

import Foundation
import AVFoundation
import Speech

@available(macOS 26.0, *)
final class JarvisSpeechRecognizer {

    /// Whether this machine can run the Apple recognizer at all.
    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// Whether the audio tap has delivered ANY buffer this session.
    ///
    /// ⚠️⚠️ THE ONLY HONEST LIVENESS SIGNAL ON THIS PATH, and the reason the caller's dead-microphone
    /// detection could not simply be copied from the WhisperKit loop. `handle(_:)` emits
    /// `bufferEnergy: []` — this recognizer has no per-buffer energy to report — so the controller's
    /// shared `receivedAudio` flag can only ever be set by TEXT arriving. Text proves audio, but
    /// silence does not disprove it: keyed on transcription alone, a dead microphone and a quiet
    /// room are the same observation, and warning on that would light up "NO AUDIO" every time
    /// nobody happened to speak.
    ///
    /// The tap firing is precisely what a non-empty `bufferEnergy` means on the WhisperKit side: a
    /// healthy engine delivers buffers within ~100 ms whether or not anyone is talking.
    var hasReceivedAudio: Bool {
        if tapDeliveredAudio { return true }
        return tapAdapter?.snapshot.sawAudio ?? false
    }

    private let logger = DGLogger(category: "JarvisAppleSpeech")
    /// Set by the session controller so Apple Speech lines carry the same `[s:…]` as the rest.
    var correlationTag: String = ""

    private var engine: AVAudioEngine?
    /// Owns format discovery, downmixing and drop accounting for this session's tap.
    private var tapAdapter: JarvisTapAdapter?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var detector: SpeechDetector?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var detectorTask: Task<Void, Never>?

    /// Text finalized so far this session, plus the volatile hypothesis — deliberately mapped onto
    /// the SAME `StreamingTranscriptionState` the WhisperKit path emits, so every consumer
    /// (the orb's live caption, the stability watchdog, the dead-mic detector) works unchanged.
    private var finalizedText = ""
    private var volatileText = ""
    private var sawAnyResult = false
    /// Latched copy of the tap's liveness, because `stop()` releases the adapter that owns it.
    /// Without the latch, whether a session counted as "dead" would depend on whether the caller
    /// happened to ask before or after stopping — a race in the one signal that decides whether the
    /// user is told their microphone is broken.
    private var tapDeliveredAudio = false
    private var onUpdate: ((StreamingTranscriptionState) -> Void)?
    /// Fired when the transcriber marks a result final — the whole point of this recognizer.
    private var onFinalized: (() -> Void)?

    // MARK: - Lifecycle

    /// Starts recognition. Non-blocking, unlike WhisperKit's `startStreaming` — results arrive on
    /// `onUpdate` and `onFinalized` until `stop()`.
    func start(
        locale: Locale = JarvisConfigManager.shared.speechLocale,
        voiceProcessing: Bool,
        onUpdate: @escaping (StreamingTranscriptionState) -> Void,
        onFinalized: @escaping () -> Void
    ) async throws {
        guard Self.isAvailable else {
            logger.error("[JARVIS_APPLE_ASR]\(self.correlationTag) SpeechTranscriber.isAvailable is false on this machine. CONSEQUENCE: the Apple recognizer cannot be used; the caller must fall back to WhisperKit.")
            throw JarvisSpeechRecognizerError.unavailable
        }
        self.onUpdate = onUpdate
        self.onFinalized = onFinalized
        finalizedText = ""
        volatileText = ""
        sawAnyResult = false
        tapDeliveredAudio = false

        // ⚠️⚠️ RESOLVE AND RESERVE THE LOCALE FIRST. `SpeechTranscriber` will happily run with an
        // unallocated locale — it does not throw, it WARNS and transcribes in a degraded mode.
        // Device test 2026-09-04: "write an essay on technology" came back as "write an SM
        // technology" and then "write in Asian technology", with the framework quietly logging
        // `Cannot use modules with unallocated locales [en_IN]. Currently allocated locales are []`.
        // Reserving is therefore not optional setup — it IS the difference between this recognizer
        // working and producing garbage.
        let resolved = await Self.resolveLocale(locale, logger: logger)
        guard let resolvedLocale = resolved else {
            logger.error("[JARVIS_APPLE_ASR]\(self.correlationTag) No supported Apple Speech locale equivalent to \(locale.identifier). CONSEQUENCE: refusing to start rather than transcribing in a degraded mode — the caller falls back to WhisperKit.")
            throw JarvisSpeechRecognizerError.localeUnsupported(locale.identifier)
        }

        // `.progressiveTranscription` is the preset that reports volatile hypotheses as well as
        // finalized text — without it there is nothing to show in the orb's live caption.
        let transcriber = SpeechTranscriber(locale: resolvedLocale, preset: .progressiveTranscription)
        // Explicit sensitivity rather than the convenience init: the level is the only tuning
        // this module exposes (there is no numeric threshold), so it should be visible here
        // rather than hidden behind a default.
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
            logger.error("[JARVIS_APPLE_ASR]\(self.correlationTag) No compatible audio format for the transcriber on this locale/machine. CONSEQUENCE: cannot start; falling back to WhisperKit.")
            throw JarvisSpeechRecognizerError.noCompatibleFormat
        }

        // Async path: settle by awaiting rather than stalling the UI.
        await JarvisAudioEngineBuilder.awaitDeviceRelease(logger: logger)
        let graph = try JarvisAudioEngineBuilder.make(voiceProcessing: voiceProcessing, logger: logger)
        // ⚠️ NOT `AVAudioConverter(from: graph.tapFormat, …)`. That format is read before the
        // engine starts, and voice processing renegotiates the device afterwards — a converter
        // pinned to the stale format yields silence with no error. The adapter builds its own from
        // the first real buffer, downmixes mic arrays, and names every dropped buffer.
        let adapter = JarvisTapAdapter(predicted: graph.tapFormat, target: analyzerFormat, tag: "[JARVIS_APPLE_ASR]", logger: logger)
        self.tapAdapter = adapter

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        // Shared with the WhisperKit path: settles the device, installs at the format the bus
        // actually has, and retries once if the hardware moves between install and start.
        try JarvisAudioEngineBuilder.installTapAndStart(graph, tapSeconds: 0.1, logger: logger) { buffer in
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
                self.logger.error("[JARVIS_APPLE_ASR]\(self.correlationTag) Result stream ended with an error: \(error.localizedDescription). CONSEQUENCE: no further transcription this session; the caller's watchdog ends the turn.")
            }
        }

        detectorTask = Task { [weak self] in
            guard let self else { return }
            // Real ML voice activity, replacing a buffer-energy counter that fires on fan hum.
            // Once duplex PLAYBACK lands this is also the barge-in trigger: speech detected on an
            // AEC-cleaned stream while Jarvis is speaking means the user interrupted, and nothing
            // else does.
            do {
                for try await result in detector.results {
                    // Real ML voice activity — logged at debug so a device test can correlate it
                    // with what the transcriber did, without flooding the info stream.
                    self.logger.debug("[JARVIS_APPLE_ASR]\(self.correlationTag) speechDetected: \(result.speechDetected)")
                }
            } catch {
                self.logger.info("[JARVIS_APPLE_ASR]\(self.correlationTag) Voice-activity stream ended: \(error.localizedDescription). CONSEQUENCE: transcription continues; only the barge-in trigger is lost this session.")
            }
        }

        logger.notice("[JARVIS_APPLE_ASR]\(self.correlationTag) STARTED — locale \(resolvedLocale.identifier) (requested \(locale.identifier)), analyzer format \(String(format: "%.0f", analyzerFormat.sampleRate)) Hz / \(analyzerFormat.channelCount) ch, voiceProcessing: \(graph.voiceProcessingEnabled).")
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
                // This call exists so a command spoken right before the stop is not lost. A
                // swallowed throw loses exactly that, and the user sees a truncated command with
                // no explanation anywhere.
                logger.error("[JARVIS_APPLE_ASR]\(self.correlationTag) Final flush FAILED: \(error.localizedDescription). CONSEQUENCE: anything said in the last moment before stopping is missing from the transcript — the command may be truncated with no other sign.")
            }
        }
        resultsTask?.cancel(); resultsTask = nil
        detectorTask?.cancel(); detectorTask = nil

        if let tapAdapter {
            // ⚠️ Latch BEFORE releasing the adapter — `hasReceivedAudio` is read by the caller's
            // dead-microphone check, which runs after this.
            tapDeliveredAudio = tapAdapter.snapshot.sawAudio
            logger.notice("[JARVIS_APPLE_ASR]\(self.correlationTag) Tap summary — \(tapAdapter.summary()).")
        }
        tapAdapter = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        if engine != nil { JarvisAudioEngineBuilder.noteTeardown() }
        engine = nil
        analyzer = nil
        transcriber = nil
        detector = nil

        let text = StreamingTranscriptionState.joined(confirmed: finalizedText, partial: volatileText)
        // ⚠️ Only a session that actually RAN can prove a format mismatch. A superseded or
        // cancelled session naturally has no results, and reporting that as the mismatch
        // signature trains the reader to ignore the one line that matters.
        if !sawAnyResult, reason == "finished" {
            // The silent-failure signature this recognizer is most likely to hit: a clean compile,
            // a running engine, and no results at all because the format negotiation was wrong.
            logger.error("[JARVIS_APPLE_ASR]\(self.correlationTag) Session produced ZERO results. CONSEQUENCE: nothing was heard — this is the format-mismatch signature, not a quiet room; compare the analyzer and tap formats logged at START.")
        } else {
            logger.notice("[JARVIS_APPLE_ASR]\(self.correlationTag) STOPPED — \(text.split(separator: " ").count) word(s) transcribed.")
        }
        onUpdate = nil
        onFinalized = nil
        return text
    }

    // MARK: - Locale + on-device assets

    /// The supported locale closest to `requested`, or nil if the language is unavailable.
    ///
    /// Uses the framework's own matcher rather than string comparison: `en_IN` is not in
    /// `supportedLocales` verbatim on every machine, but has a supported equivalent.
    private static func resolveLocale(_ requested: Locale, logger: DGLogger) async -> Locale? {
        if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            if equivalent.identifier != requested.identifier {
                logger.notice("[JARVIS_APPLE_ASR] Locale \(requested.identifier) is not supported directly; using the equivalent \(equivalent.identifier). CONSEQUENCE: recognition runs against that variant's model, which may differ slightly in accent handling.")
            }
            return equivalent
        }
        let supported = await SpeechTranscriber.supportedLocales
        logger.error("[JARVIS_APPLE_ASR] \(requested.identifier) has no supported equivalent among \(supported.count) locale(s).")
        return nil
    }

    /// Reserves the locale and installs its on-device model if needed.
    ///
    /// ⚠️ `AssetInventory.reserve` is what moves a locale into "allocated". Skipping it does NOT
    /// fail — it degrades, silently, which is exactly how this shipped broken the first time.
    /// There is a hard cap (`maximumReservedLocales`), so a reserve can legitimately fail and
    /// must be reported rather than swallowed.
    private static func reserveAndInstall(locale: Locale,
                                          modules: [any SpeechModule],
                                          logger: DGLogger) async throws {
        let alreadyReserved = await AssetInventory.reservedLocales
        if !alreadyReserved.contains(where: { $0.identifier == locale.identifier }) {
            do {
                let reserved = try await AssetInventory.reserve(locale: locale)
                logger.notice("[JARVIS_APPLE_ASR] Reserved locale \(locale.identifier): \(reserved) (was holding \(alreadyReserved.count)/\(AssetInventory.maximumReservedLocales)).")
                if !reserved {
                    logger.error("[JARVIS_APPLE_ASR] Locale reservation returned false — the reserved-locale limit (\(AssetInventory.maximumReservedLocales)) is likely full. CONSEQUENCE: recognition would run UNALLOCATED and produce degraded text; refusing to start so the caller falls back to WhisperKit.")
                    throw JarvisSpeechRecognizerError.localeUnavailable(locale.identifier)
                }
            } catch let error as JarvisSpeechRecognizerError {
                throw error
            } catch {
                logger.error("[JARVIS_APPLE_ASR] Reserving locale \(locale.identifier) FAILED: \(error.localizedDescription). CONSEQUENCE: refusing to start rather than transcribing degraded; the caller falls back to WhisperKit.")
                throw error
            }
        }

        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            logger.info("[JARVIS_APPLE_ASR] On-device model for \(locale.identifier) is installed.")
        case .supported, .downloading:
            logger.notice("[JARVIS_APPLE_ASR] On-device model for \(locale.identifier) is not installed yet — downloading. CONSEQUENCE: the first session waits for the download; later ones do not.")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
                logger.notice("[JARVIS_APPLE_ASR] On-device model install complete for \(locale.identifier).")
            } else {
                logger.info("[JARVIS_APPLE_ASR] No installation request needed for \(locale.identifier).")
            }
        case .unsupported:
            logger.error("[JARVIS_APPLE_ASR] Apple Speech reports \(locale.identifier) UNSUPPORTED for these modules. CONSEQUENCE: refusing to start; the caller falls back to WhisperKit.")
            throw JarvisSpeechRecognizerError.localeUnsupported(locale.identifier)
        @unknown default:
            logger.warning("[JARVIS_APPLE_ASR] Unrecognised asset status for \(locale.identifier) — proceeding, but transcription quality is unverified.")
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
            logger.info("[JARVIS_APPLE_ASR]\(self.correlationTag) Result FINALIZED — dispatching immediately rather than waiting out a stability window.")
            onFinalized?()
        }
    }

}

// MARK: - Errors

enum JarvisSpeechRecognizerError: LocalizedError {
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
///
/// Resumes EXACTLY ONCE, whichever edge arrives first — a finalized result, the capture hard cap,
/// an expired follow-up window, or a superseded generation. The same exactly-once discipline as
/// `drainSpeechCompletion`: a double resume traps, and a missed resume parks the turn forever.
@MainActor
final class JarvisOneShot {
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

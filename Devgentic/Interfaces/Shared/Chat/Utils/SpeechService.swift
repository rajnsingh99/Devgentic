// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SpeechService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import AVFoundation
import os

private let logger = DGLogger(category: "SpeechService")

// MARK: - Notifications

extension Notification.Name {
    /// Fired when all segments for a message have finished speaking.
    static let speechDidFinish = Notification.Name("SpeechServiceDidFinish")

    /// Fired when speech encounters a code block and wants it opened in the Code Viewer.
    /// `userInfo` contains `"language"` (String?) and `"code"` (String).
    static let speechOpenCodeViewer = Notification.Name("SpeechServiceOpenCodeViewer")
}

// MARK: - Speech Segment

/// Represents a segment of agent response content for sequential speech playback.
enum SpeechSegment: Equatable {
    /// Cleaned prose text to be spoken.
    case text(String)
    /// A code block encountered in the response — language and code content.
    case codeBlock(language: String?, code: String)
}

// MARK: - Voice Info

/// A user-friendly representation of an available system voice.
struct VoiceInfo: Identifiable, Hashable {
    let id: String // AVSpeechSynthesisVoice.identifier
    let name: String
    let locale: String
}

// MARK: - Stamped Utterance

// Why: `stopSpeaking(at:)` delivers `didFinish` (never `didCancel`) for the utterance it cancels,
// so an unstamped completion would advance the playlist a second time.
/// An `AVSpeechUtterance` stamped with the `speakUtterance` call that created it.
/// The stamp tells a completion for the live utterance from one for an utterance a skip or restart discarded.
private final class StampedUtterance: AVSpeechUtterance {
    // Why: keep it optional: the completion guard fails open only on nil, a sentinel like 0 would never match and park playback.
    /// `SpeechService.utteranceGeneration` when this utterance was handed over; nil when decoded.
    let generation: Int?

    init(string: String, generation: Int) {
        self.generation = generation
        super.init(string: string)
    }

    /// Required by `AVSpeechUtterance`'s `NSSecureCoding` conformance. Nothing here is ever
    /// archived today; if one ever is, it carries no live generation and `nil` routes it to the
    /// guard's fail-open branch, i.e. exactly the pre-stamp behaviour.
    required init?(coder: NSCoder) {
        generation = nil
        super.init(coder: coder)
    }
}

// MARK: - SpeechService

/// A singleton wrapper around AVSpeechSynthesizer that speaks agent responses
/// segment by segment. When a code block is encountered, it announces it, opens the Code Viewer,
/// and continues (or pauses if `pauseOnCode` is enabled).
@MainActor @Observable
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechService()

    // Why: a live AVSpeechSynthesizer holds a CoreAudio output context open, which can wedge the microphone.
    /// Created per playback session and released at stop or finish, not held for the app's lifetime.
    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?

    /// Returns the live synthesizer, creating one if this is a fresh session.
    private func ensureSynthesizer() -> AVSpeechSynthesizer {
        if let synthesizer { return synthesizer }
        let synth = AVSpeechSynthesizer()
        synth.delegate = self
        synthesizer = synth
        logger.info("[TTS] Synthesizer created (playback session starting).")
        return synth
    }

    /// [V5] Drops the synthesizer (and its CoreAudio output context). Only when idle —
    /// callers release at session end (stop / natural finish), never mid-session.
    private func releaseSynthesizer(reason: String) {
        guard synthesizer != nil else { return }
        synthesizer?.delegate = nil
        synthesizer = nil
        logger.info("[TTS] Synthesizer released (\(reason)) — CoreAudio output context freed.")
    }

    /// Whether the silent-test-host notice has been logged this process.
    private static var reportedSilentTestHost = false

    /// Test seam: whether a synthesizer (and its audio context) is currently held.
    var isSynthesizerLoaded: Bool { synthesizer != nil }

    // MARK: - State

    /// Whether a speech session is currently active (speaking or paused).
    private(set) var isActive: Bool = false

    /// Whether speech is currently paused (via user action or pause-on-code).
    private(set) var isPaused: Bool = false

    /// The index of the segment currently being spoken (1-based for display).
    private(set) var currentSegmentIndex: Int = 0

    /// Total number of segments in the current playback session.
    private(set) var totalSegmentCount: Int = 0

    /// The current speech rate multiplier (0.5, 1.0, 1.5, 2.0).
    private(set) var currentRate: Float = 1.0

    /// The currently selected voice identifier.
    private(set) var selectedVoice: String?

    /// Whether to pause playback when a code block is encountered (instead of auto-resuming).
    private(set) var pauseOnCode: Bool = false

    /// The message ID currently being spoken.
    private(set) var currentMessageID: UUID?

    // MARK: - Transport hosts [sa-5]

    // Why: a set of IDs, not a counter or per-surface stop: appear/disappear delivery need not pair, and the service is shared.
    /// Identities of the surfaces currently able to show the `SpeechControlIsland`.
    /// A live session with no host has no Play, Pause or Stop anywhere, so it is stopped once the set empties.
    private(set) var transportHostIDs: Set<UUID> = []

    /// How many surfaces currently host the transport.
    var mountedTransportHosts: Int { transportHostIDs.count }

    func transportHostDidAppear(_ id: UUID) {
        let inserted = transportHostIDs.insert(id).inserted
        logger.debug("[SPEECH] Transport host \(id.uuidString.prefix(8)) \(inserted ? "mounted" : "re-registered (already counted)") — \(self.transportHostIDs.count) on screen.")
    }

    /// Stops a live session once the last host is gone, checked one main-actor turn later so a mode switch has settled.
    func transportHostDidDisappear(_ id: UUID) {
        guard transportHostIDs.remove(id) != nil else {
            logger.debug("[SPEECH] Transport host \(id.uuidString.prefix(8)) reported gone but was not registered — ignored; \(self.transportHostIDs.count) remain.")
            return
        }
        logger.debug("[SPEECH] Transport host \(id.uuidString.prefix(8)) gone — \(self.transportHostIDs.count) remain\(self.isActive ? " while reading message \(self.messageIDPrefix)" : "").")
        guard transportHostIDs.isEmpty, isActive else { return }
        Task { @MainActor [weak self] in self?.stopIfNoTransportRemains() }
    }

    /// The synchronous rule behind `transportHostDidDisappear`, split out so it is testable
    /// without the deferral. Idle sessions and sessions with a host left are untouched.
    func stopIfNoTransportRemains() {
        guard isActive, transportHostIDs.isEmpty else { return }
        logger.info("[SPEECH] Every surface that could show the transport is gone while reading message \(self.messageIDPrefix) — stopping playback. CONSEQUENCE: the reader does not keep speaking with no Stop on screen, and the synthesizer is released.")
        stop()
    }

    #if DEBUG
    func resetTransportHostsForTesting() { transportHostIDs = [] }
    #endif

    // MARK: - External narration [sa-8]

    // Why: narration only: `OrbVoiceOutput`'s short phrases use a private synthesizer so Read Aloud does not cut them off.
    /// Cancels the other driver (`OrbStreamingSpeaker`) feeding this service; set by that driver while it holds the floor.
    /// A closure so `SpeechService` does not depend on Orb types.
    @ObservationIgnored private var externalNarrationCanceller: (() -> Void)?
    /// Who registered it. A driver may only release its OWN claim — a teardown arriving late
    /// from a previous speaker must not clear the registration of the one that replaced it.
    @ObservationIgnored private var externalNarrationOwner: ObjectIdentifier?

    var hasExternalNarration: Bool { externalNarrationCanceller != nil }

    func registerExternalNarration(owner: AnyObject, cancel: @escaping () -> Void) {
        externalNarrationCanceller = cancel
        externalNarrationOwner = ObjectIdentifier(owner)
    }

    /// Drops the claim, but only if `owner` is the driver that made it.
    func releaseExternalNarrationCanceller(ifOwnedBy owner: AnyObject) {
        guard externalNarrationOwner == ObjectIdentifier(owner) else { return }
        externalNarrationCanceller = nil
        externalNarrationOwner = nil
    }

    /// Hands the floor back from whatever external driver holds it. Idempotent: the closure is
    /// cleared before it is called, so a canceller that re-enters cannot recurse.
    private func cancelExternalNarration(reason: String) {
        guard let cancel = externalNarrationCanceller else { return }
        externalNarrationCanceller = nil
        externalNarrationOwner = nil
        logger.info("[SPEECH] Cancelling external narration (\(reason)). CONSEQUENCE: the other driver stops feeding this service, instead of continuing to queue utterances into a session it no longer owns and interleaving with what was just requested.")
        cancel()
    }

    #if DEBUG
    func clearExternalNarrationForTesting() {
        externalNarrationCanceller = nil
        externalNarrationOwner = nil
    }
    #endif

    // MARK: - Internal State

    /// The full list of segments for the current session (preserved for skip-backward).
    @ObservationIgnored private var allSegments: [SpeechSegment] = []

    /// Tracks the in-flight delayed Task (e.g., code-block pause) so it can be cancelled on stop().
    @ObservationIgnored private var pendingDelayTask: Task<Void, Never>?

    /// The index into `allSegments` of the segment currently being spoken.
    @ObservationIgnored private var playbackIndex: Int = 0

    /// Temporarily holds a code block waiting to be opened after the announcement finishes.
    private var pendingCodeBlock: (language: String?, code: String)?

    /// Whether the surface that started this session has a Code Viewer to hand a code block to; defaults to true.
    /// Set by `speak(_:messageID:canPresentCodeViewer:)` and reset at session end.
    @ObservationIgnored private var sessionCanPresentCodeViewer: Bool = true

    /// Test seam: the code-viewer capability the current session was started with.
    var sessionCanPresentCodeViewerForTesting: Bool { sessionCanPresentCodeViewer }

    // MARK: - In-flight utterance tracking

    // Why: rate and voice are baked into an `AVSpeechUtterance` at creation, so a mid-playback change needs a re-speak.
    /// The text of the utterance currently inside the synthesizer, nil between segments or when idle.
    /// With `spokenUpTo`, lets `setRate`/`setVoice` re-speak the remainder with the new setting.
    @ObservationIgnored private var currentUtteranceText: String?

    /// UTF-16 offset of the word the synthesizer most recently began speaking, from
    /// `willSpeakRangeOfSpeechString` — an `NSRange`, hence UTF-16 units and not `Character`s.
    /// 0 until the first word is reported.
    @ObservationIgnored private var spokenUpTo: Int = 0

    /// Set when a setting changes while PAUSED. `continueSpeaking()` would resume the old
    /// utterance with the old setting baked in, so `resumeSpeaking` stops it and re-speaks the
    /// remainder instead.
    @ObservationIgnored private var restartOnResume: Bool = false

    /// Bumped every time an utterance is handed to the synthesizer. Test seam: a live-setting
    /// change that restarts the current utterance is observable as a generation bump.
    @ObservationIgnored private(set) var utteranceGeneration: Int = 0

    /// The generation of the utterance still considered in flight, nil when none; set with `currentUtteranceText`.
    /// `handleUtteranceFinished` compares against it, so a discarded or already-consumed completion is ignored.
    @ObservationIgnored private var activeUtteranceGeneration: Int?

    /// Test seam: generation of the utterance the service believes is in flight.
    var activeUtteranceGenerationForTesting: Int? { activeUtteranceGeneration }

    /// Test seam: text of the utterance in flight (nil when nothing is queued).
    var currentUtteranceTextForTesting: String? { currentUtteranceText }

    /// Test seam: UTF-16 offset of the last word boundary the synthesizer reported.
    var spokenUpToForTesting: Int { spokenUpTo }

    /// Test seam: whether the next `resumeSpeaking` re-speaks with changed settings.
    var willRestartOnResume: Bool { restartOnResume }

    /// Available speed presets.
    static let speedPresets: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    // MARK: - Rate Mapping

    /// Maps the user-facing multiplier (0.5–2.0) to AVSpeechUtteranceRate range.
    /// AVSpeechUtteranceDefaultSpeechRate is ~0.5, min is 0.0, max is 1.0.
    private func avRate(for multiplier: Float) -> Float {
        AVSpeechUtteranceDefaultSpeechRate * multiplier
    }

    // MARK: - Init

    private override init() {
        let savedRate = UserDefaults.standard.float(forKey: AppSettings.speechPlaybackRateKey)
        let savedVoice = UserDefaults.standard.string(forKey: AppSettings.speechPlaybackVoiceKey)
        let savedPauseOnCode = UserDefaults.standard.bool(forKey: AppSettings.speechPauseOnCodeKey)

        super.init()

        if savedRate > 0 {
            currentRate = savedRate
        }
        selectedVoice = savedVoice
        pauseOnCode = savedPauseOnCode
    }

    // MARK: - Public API

    /// Starts segment-based speech for the given raw markdown text.
    /// `canPresentCodeViewer` says whether the calling surface can open a Code Viewer; when false, code blocks are announced
    /// as skipped, with no viewer hand-off or pause-on-code wait.
    func speak(_ rawText: String, messageID: UUID, canPresentCodeViewer: Bool = true) {
        // Cancel before `stop()`: stop only silences the synthesizer, and a streaming driver would keep queueing.
        cancelExternalNarration(reason: "Read Aloud was started")
        stop()

        let segments = SpeechService.parseSegments(from: rawText)
        guard !segments.isEmpty else { return }

        allSegments = segments
        playbackIndex = 0
        currentMessageID = messageID
        totalSegmentCount = segments.count
        currentSegmentIndex = 1
        isActive = true
        isPaused = false
        sessionCanPresentCodeViewer = canPresentCodeViewer

        logger.info("Started reading aloud message \(messageID.uuidString) (\(segments.count) segments)")
        speakCurrentSegment()
    }

    /// Stops all speech and resets state.
    func stop() {
        if let synthesizer, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        // Cancel any in-flight delayed task (e.g., code-block auto-resume sleep)
        pendingDelayTask?.cancel()
        pendingDelayTask = nil

        let previousID = currentMessageID

        allSegments.removeAll()
        playbackIndex = 0
        pendingCodeBlock = nil
        clearUtteranceTracking()
        isActive = false
        isPaused = false
        currentSegmentIndex = 0
        totalSegmentCount = 0
        currentMessageID = nil
        sessionCanPresentCodeViewer = true

        if let id = previousID {
            logger.info("Stopped reading aloud message \(id.uuidString)")
            NotificationCenter.default.post(name: .speechDidFinish, object: id)
        }

        releaseSynthesizer(reason: "stop")
    }

    /// Forgets the in-flight utterance once it is not the one in the synthesizer (finish, stop, skip, session end).
    private func clearUtteranceTracking() {
        currentUtteranceText = nil
        activeUtteranceGeneration = nil
        spokenUpTo = 0
        restartOnResume = false
    }

    /// Pauses speech at the next word boundary.
    func pauseSpeaking() {
        guard isActive, !isPaused else { return }

        // Treat the post-code-block delay as a park point: cancel it and advance so Play speaks the next segment once.
        // There is nothing in the synthesizer to pause during the delay.
        if pendingDelayTask != nil {
            pendingDelayTask?.cancel()
            pendingDelayTask = nil

            // A code block as the final segment has nothing to park on; let the delay run off the end and finish.
            guard playbackIndex + 1 < allSegments.count else {
                logger.info("[SPEECH] Pause landed during the code-block beat of the FINAL segment (message \(self.messageIDPrefix)) — nothing remains to park on, so the session ends here. CONSEQUENCE: the transport disappears instead of offering a Play that could only stop it.")
                finishPlayback()
                return
            }

            advancePlaybackIndex()
            isPaused = true
            logger.info("[SPEECH] Pause landed during the code-block beat (message \(self.messageIDPrefix)) — the beat was cancelled and playback parked on segment \(self.currentSegmentIndex) of \(self.totalSegmentCount) WITHOUT speaking it. CONSEQUENCE: no audio starts under a paused transport, and Play speaks that segment once instead of re-announcing the code block.")
            return
        }

        synthesizer?.pauseSpeaking(at: .word)
        isPaused = true
        // Pause is honoured at the next word boundary, so `isPaused` leads the synthesizer; `didPause` logs when it lands.
        logger.info("[SPEECH] Pause requested at the next word boundary (message \(self.messageIDPrefix), segment \(self.currentSegmentIndex) of \(self.totalSegmentCount)).")
    }

    #if DEBUG
    /// Test seam [sa-2]: whether the post-code-block beat is currently armed.
    var pendingDelayTaskIsArmedForTesting: Bool { pendingDelayTask != nil }
    /// Test seam [sa-2]: arms a beat exactly as `handOffPendingCodeBlock(autoResume: true)` does,
    /// without needing the user's persisted pause-on-code preference to be off.
    func armCodeBlockBeatForTesting() {
        pendingDelayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.pendingDelayTask = nil
            self.advancePlaybackIndex()
            self.speakCurrentSegment()
        }
    }
    #endif

    /// Resumes paused speech.
    func resumeSpeaking() {
        guard isActive, isPaused else { return }
        isPaused = false

        if restartOnResume, currentUtteranceText != nil {
            // Speed or voice changed while paused: `continueSpeaking()` would keep the old setting,
            // so re-speak from the last word boundary instead.
            restartOnResume = false
            restartCurrentUtterance(reason: "resume after a settings change while paused")
        } else if currentUtteranceText != nil, synthesizer?.isPaused == true || synthesizer?.isSpeaking == true {
            // `isSpeaking` covers the window where a pause was requested but has not landed; `isPaused` alone would queue a second
            // utterance behind one about to pause and leave playback silent. `continueSpeaking()` is harmless if nothing paused.
            synthesizer?.continueSpeaking()
        } else {
            // The utterance finished while a pause was pending, leaving the playlist parked on the next segment;
            // a `continueSpeaking()` with nothing queued would resume silence, so speak the segment directly.
            speakCurrentSegment()
        }
        logger.info("[SPEECH] Resumed (message \(self.messageIDPrefix), segment \(self.currentSegmentIndex) of \(self.totalSegmentCount)).")
    }

    /// Toggles between paused and speaking states.
    func togglePause() {
        if isPaused {
            resumeSpeaking()
        } else {
            pauseSpeaking()
        }
    }

    /// Skips to the next segment.
    func skipForward() {
        guard isActive else { return }

        if let synthesizer, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        // Cancel the code-block auto-resume sleep with the skip, as `stop()` does, or it advances the playlist a second time.
        pendingDelayTask?.cancel()
        pendingDelayTask = nil
        pendingCodeBlock = nil
        clearUtteranceTracking()
        isPaused = false

        playbackIndex += 1
        if playbackIndex < allSegments.count {
            currentSegmentIndex = playbackIndex + 1
            speakCurrentSegment()
        } else {
            finishPlayback()
        }
    }

    /// Skips back to the previous segment.
    func skipBackward() {
        guard isActive else { return }

        if let synthesizer, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        // Cancel the code-block auto-resume sleep with the skip, as `stop()` does, or it advances the playlist a second time.
        pendingDelayTask?.cancel()
        pendingDelayTask = nil
        pendingCodeBlock = nil
        clearUtteranceTracking()
        isPaused = false

        if playbackIndex > 0 {
            playbackIndex -= 1
        }
        currentSegmentIndex = playbackIndex + 1
        speakCurrentSegment()
    }

    /// Sets the speech rate multiplier, persists it, and applies it to the utterance in flight.
    func setRate(_ rate: Float) {
        currentRate = rate
        UserDefaults.standard.set(rate, forKey: AppSettings.speechPlaybackRateKey)
        logger.info("[SPEECH] Speech rate set to \(rate)× (message \(self.messageIDPrefix))")
        applySettingToCurrentUtterance(setting: "rate \(rate)×")
    }

    /// Sets the voice, persists it, and applies it to the utterance in flight.
    func setVoice(_ voiceID: String) {
        selectedVoice = voiceID
        UserDefaults.standard.set(voiceID, forKey: AppSettings.speechPlaybackVoiceKey)
        logger.info("[SPEECH] Speech voice set to \(voiceID) (message \(self.messageIDPrefix))")
        applySettingToCurrentUtterance(setting: "voice \(voiceID)")
    }

    /// Correlation id for [SPEECH] log lines — "idle" when no message is being read.
    private var messageIDPrefix: String {
        currentMessageID.map { String($0.uuidString.prefix(8)) } ?? "idle"
    }

    /// Makes a just-changed rate or voice audible now: re-speaks the remainder when speaking, flags a restart on resume
    /// when paused, and does nothing when idle (the next segment picks up the setting via `makeUtterance`).
    private func applySettingToCurrentUtterance(setting: String) {
        guard isActive, currentUtteranceText != nil else {
            logger.debug("[SPEECH] \(setting) — no utterance in flight (message \(self.messageIDPrefix)); the next utterance picks it up.")
            return
        }

        if isPaused {
            restartOnResume = true
            logger.info("[SPEECH] \(setting) noted while paused (message \(self.messageIDPrefix)) — resume will re-speak from the current word with the new setting.")
            return
        }

        // Trust the synthesizer for the restart: between it finishing and `didFinish` reaching the main actor,
        // a restart would queue a stray remainder behind the next segment.
        guard let synthesizer, synthesizer.isSpeaking else {
            logger.info("[SPEECH] \(setting) — synthesizer reports nothing speaking (message \(self.messageIDPrefix)); not restarting, the next utterance picks it up.")
            return
        }

        restartCurrentUtterance(reason: setting)
    }

    /// Cancels the in-flight utterance and speaks the rest from the last reported word boundary, with the current rate
    /// and voice. `pendingCodeBlock` and the playlist indices are untouched.
    private func restartCurrentUtterance(reason: String) {
        guard let text = currentUtteranceText else { return }
        let remainder = Self.remainder(of: text, spokenUpTo: spokenUpTo)
        let offset = spokenUpTo

        // `stopSpeaking(at:)` delivers `didFinish` for the cancelled utterance; the generation guard in
        // `handleUtteranceFinished` discards it because both branches below leave a different generation in flight.
        if let synthesizer, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // The change landed on the final word: advance the playlist here, since the cancelled utterance's `didFinish`
            // will be discarded as stale and playback would otherwise hang.
            logger.info("[SPEECH] \(reason): nothing left of the current utterance after offset \(offset) (message \(self.messageIDPrefix)) — advancing as if it had finished.")
            handleUtteranceFinished()
            return
        }

        logger.info("[SPEECH] \(reason): re-speaking the current utterance from UTF-16 offset \(offset) of \(text.utf16.count) (message \(self.messageIDPrefix)).")
        speakUtterance(remainder)
    }

    /// Toggles the pause-on-code preference and persists it.
    func togglePauseOnCode() {
        pauseOnCode.toggle()
        UserDefaults.standard.set(pauseOnCode, forKey: AppSettings.speechPauseOnCodeKey)
        logger.info("Pause on code: \(self.pauseOnCode)")
    }

    /// Returns the list of available system voices with user-friendly names.
    private static let _cachedVoices: [VoiceInfo] = {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            VoiceInfo(
                id: voice.identifier,
                name: voice.name,
                locale: voice.language
            )
        }
    }()

    static var availableVoices: [VoiceInfo] { _cachedVoices }

    /// Whether the synthesizer is currently speaking audio.
    var isSpeaking: Bool {
        synthesizer?.isSpeaking ?? false
    }

    // MARK: - Segment Playback

    private func speakCurrentSegment() {
        guard playbackIndex < allSegments.count else {
            finishPlayback()
            return
        }

        let segment = allSegments[playbackIndex]

        switch segment {
        case .text(let text):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                playbackIndex += 1
                currentSegmentIndex = playbackIndex + 1
                speakCurrentSegment()
            } else {
                speakUtterance(text)
            }

        case .codeBlock(let language, let code):
            // Take on the code-viewer hand-off only when this session's surface has a viewer; otherwise the notification
            // goes unanswered and pause-on-code would wait for a resume the user cannot press.
            guard sessionCanPresentCodeViewer else {
                logger.info("[SPEECH] Code block (\(language ?? "unlabelled"), \(code.count) chars) SKIPPED for message \(self.messageIDPrefix) — this surface has no Code Viewer to open it in. CONSEQUENCE: the listener is told the block is being skipped instead of being promised a panel, and playback continues to the next segment.")
                speakUtterance(Self.codeBlockAnnouncement(canPresentCodeViewer: false, language: language))
                return
            }
            pendingCodeBlock = (language: language, code: code)
            speakUtterance(Self.codeBlockAnnouncement(canPresentCodeViewer: true, language: language))
        }
    }

    /// Returns what the reader says on reaching a code block.
    /// Without a Code Viewer (QuickAccess) it names the block and moves on instead of promising a panel.
    nonisolated static func codeBlockAnnouncement(canPresentCodeViewer: Bool, language: String?) -> String {
        if canPresentCodeViewer {
            return "Here is the code in the panel view."
        }
        guard let language, !language.trimmingCharacters(in: .whitespaces).isEmpty else {
            return String(localized: "Skipping a code block. There is no code panel in this window.")
        }
        return String(localized: "Skipping a \(language) code block. There is no code panel in this window.")
    }

    /// The single path that hands an utterance to the synthesizer, so the service always knows what is in flight.
    /// Bypassing it leaves a setting change unable to find and re-speak that utterance.
    private func speakUtterance(_ text: String) {
        utteranceGeneration &+= 1
        let utterance = makeUtterance(text, generation: utteranceGeneration)
        currentUtteranceText = text
        activeUtteranceGeneration = utteranceGeneration
        spokenUpTo = 0
        restartOnResume = false
        let synth = ensureSynthesizer()
        // No audio in the test host: tests drive state through seams and need the synthesizer to exist, never to speak.
        // Live speech sessions across many speak/stop cycles crashed the host.
        if TestHost.isRunning {
            if !Self.reportedSilentTestHost {
                Self.reportedSilentTestHost = true
                logger.notice("[TESTHOST] Read Aloud is SILENT in the XCTest host — utterances are tracked but never handed to AVSpeechSynthesizer. CONSEQUENCE: no audio and no speech-service XPC traffic during tests; completions come only from the test seams. (Logged once.)")
            }
        } else {
            synth.speak(utterance)
        }

        // Resume a synthesizer left paused by `stopSpeaking`, which would otherwise never start the enqueued utterance and leave
        // the UI on "Playing" in silence. `!isPaused` keeps a deliberate user pause (`isPaused`, the service's own flag) intact.
        if let synthesizer, synthesizer.isPaused, !isPaused {
            logger.info("[SPEECH] Synthesizer was still PAUSED when the next utterance was enqueued (message \(self.messageIDPrefix)) — resuming it, because nothing asked for that pause. CONSEQUENCE: without this the utterance never starts and the transport shows Playing over silence.")
            synthesizer.continueSpeaking()
        }
    }

    /// Creates a stamped AVSpeechUtterance with the current rate and voice settings.
    /// Rate and voice are fixed once queued, so a live change goes through `restartCurrentUtterance`.
    private func makeUtterance(_ text: String, generation: Int) -> AVSpeechUtterance {
        let utterance = StampedUtterance(string: text, generation: generation)
        utterance.rate = avRate(for: currentRate)

        if let voiceID = selectedVoice,
           let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        }

        return utterance
    }

    /// Returns the part of `text` not yet spoken, from the UTF-16 offset of the last word the synthesizer reported.
    /// An offset of 0 or less returns the whole text; one at or past the end returns an empty string.
    /// Restarting at the start of that word repeats one word rather than dropping one.
    nonisolated static func remainder(of text: String, spokenUpTo utf16Offset: Int) -> String {
        guard utf16Offset > 0 else { return text }
        guard utf16Offset < text.utf16.count else { return "" }
        let index = String.Index(utf16Offset: utf16Offset, in: text)
        return String(text[index...])
    }

    private func finishPlayback() {
        let messageID = currentMessageID

        allSegments.removeAll()
        playbackIndex = 0
        pendingCodeBlock = nil
        clearUtteranceTracking()
        isActive = false
        isPaused = false
        currentSegmentIndex = 0
        totalSegmentCount = 0
        currentMessageID = nil
        sessionCanPresentCodeViewer = true

        if let id = messageID {
            NotificationCenter.default.post(name: .speechDidFinish, object: id)
        }

        releaseSynthesizer(reason: "playback finished")
    }

    // MARK: - AVSpeechSynthesizerDelegate

    /// Fires for a cancelled utterance too, since `stopSpeaking(at:)` delivers `didFinish` rather than `didCancel`.
    /// The generation stamp keeps a skip or restart from being read as a segment ending.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let generation = (utterance as? StampedUtterance)?.generation ?? nil
        Task { @MainActor [weak self] in
            self?.handleUtteranceFinished(generation: generation)
        }
    }

    /// Delivered once per word with the range about to be spoken; hops to the main actor where the state lives.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let location = characterRange.location
        let text = utterance.speechString
        Task { @MainActor [weak self] in
            self?.handleWillSpeakRange(location: location, text: text)
        }
    }

    /// Deliberately a no-op: `stopSpeaking(at:)` delivers `didFinish`, not `didCancel`, so cancellation is recognised by the
    /// `StampedUtterance` generation in `handleUtteranceFinished`.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    }

    /// Records that a `pauseSpeaking(at: .word)` request reached the synthesizer and names the utterance generation.
    /// It does not mean the utterance is held: `didPause` fires even when the utterance finishes before the pause lands.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        let generation = (utterance as? StampedUtterance)?.generation ?? nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            logger.info("[SPEECH] A pause request reached the synthesizer (message \(self.messageIDPrefix), segment \(self.currentSegmentIndex) of \(self.totalSegmentCount), utterance generation \(generation.map(String.init) ?? "unstamped")). CONSEQUENCE: the reader holds inside this segment UNLESS a 'finished while PAUSED' line follows for the same generation — that one means the utterance ended before the word boundary and the playlist parked on the NEXT segment instead.")
        }
    }

    /// Records how far into the in-flight utterance playback has got.
    /// Keyed on the utterance text, not identity, so a range report from a just-cancelled utterance is ignored.
    private func handleWillSpeakRange(location: Int, text: String) {
        guard isActive, let current = currentUtteranceText, current == text else { return }
        spokenUpTo = location
    }

    /// What `handleUtteranceFinished` does when an utterance completes, as a value so the decision is testable.
    enum UtteranceCompletionAction: Equatable, Hashable {
        /// A code block was announced: hand it to the viewer, then WAIT for the user —
        /// pause-on-code, or a Pause pressed while the announcement was still speaking.
        case openCodeViewerThenHold
        /// A code block was announced: hand it to the viewer, then auto-resume after the delay.
        case openCodeViewerThenAutoResume
        /// Playback is paused: move to the next segment but start no audio.
        case holdAtNextSegment
        /// Speak the next segment now.
        case speakNextSegment
        /// The playlist is exhausted.
        case finish
    }

    /// The completion table: maps pending code block, pause state and next-segment availability to an action.
    /// A pause requested at a word boundary can arrive after the utterance ends, so `isPaused` may already be true.
    /// `hasNextSegment` is whether a segment exists after the one that just finished.
    nonisolated static func completionAction(hasPendingCodeBlock: Bool,
                                             isPaused: Bool,
                                             pauseOnCode: Bool,
                                             hasNextSegment: Bool) -> UtteranceCompletionAction {
        if hasPendingCodeBlock {
            return (pauseOnCode || isPaused) ? .openCodeViewerThenHold : .openCodeViewerThenAutoResume
        }
        guard hasNextSegment else { return .finish }
        return isPaused ? .holdAtNextSegment : .speakNextSegment
    }

    // Why: unknown fails open: a completion wrongly ignored parks playback forever, one wrongly honoured only skips a segment.
    /// Whether a delivered completion belongs to the utterance still in flight.
    /// A nil `reported` (the internal stand-in from `restartCurrentUtterance`, or an unstamped utterance) is always honoured.
    nonisolated static func completionBelongsToInFlightUtterance(reported: Int?, inFlight: Int?) -> Bool {
        guard let reported else { return true }
        return reported == inFlight
    }

    /// Handles utterance completion on the main actor.
    /// `generation` is the completing utterance's stamp, or nil for the stand-in call from `restartCurrentUtterance`.
    private func handleUtteranceFinished(generation: Int? = nil) {
        guard isActive else { return }

        let completedGeneration = activeUtteranceGeneration
        guard Self.completionBelongsToInFlightUtterance(reported: generation, inFlight: completedGeneration) else {
            // `stopSpeaking(at:)` reports `didFinish` for a cancelled utterance, and skip/restart have already started
            // what plays next.
            logger.info("[SPEECH] Ignored a completion for utterance generation \(generation.map(String.init) ?? "unstamped") — generation \(completedGeneration.map(String.init) ?? "none") is in flight (message \(self.messageIDPrefix)). CONSEQUENCE: the playlist stays on segment \(self.currentSegmentIndex) of \(self.totalSegmentCount); acting on it would advance a second time and play two segments at once.")
            return
        }

        // Whatever comes next is a new utterance; a settings change must not re-speak this finished one.
        clearUtteranceTracking()

        switch Self.completionAction(hasPendingCodeBlock: pendingCodeBlock != nil,
                                     isPaused: isPaused,
                                     pauseOnCode: pauseOnCode,
                                     hasNextSegment: playbackIndex + 1 < allSegments.count) {
        case .openCodeViewerThenHold:
            handOffPendingCodeBlock(autoResume: false)
        case .openCodeViewerThenAutoResume:
            handOffPendingCodeBlock(autoResume: true)
        case .holdAtNextSegment:
            advancePlaybackIndex()
            logger.info("[SPEECH] Utterance finished while PAUSED (message \(self.messageIDPrefix), utterance generation \(completedGeneration.map(String.init) ?? "none")) — advanced to segment \(self.currentSegmentIndex) of \(self.totalSegmentCount) without speaking it. CONSEQUENCE: playback stays paused as the transport shows; Play speaks this segment once. This is the pause OVERTAKEN by completion — the 'pause request reached the synthesizer' line for the same generation did not hold the utterance.")
        case .speakNextSegment:
            advancePlaybackIndex()
            speakCurrentSegment()
        case .finish:
            finishPlayback()
        }
    }

    /// Test seam: replays a delegate completion for a given utterance generation through the production handler.
    /// Pass a generation a skip left behind for a stale completion, or the in-flight one for a natural finish.
    func deliverUtteranceCompletionForTesting(generation: Int?) {
        handleUtteranceFinished(generation: generation)
    }

    /// Moves the playlist on by one. `currentSegmentIndex` is display-only (1-based) and is
    /// left alone past the end so the island doesn't flash "5 of 4" on the way to teardown.
    private func advancePlaybackIndex() {
        playbackIndex += 1
        if playbackIndex < allSegments.count {
            currentSegmentIndex = playbackIndex + 1
        }
    }

    /// Posts the announced code block to whoever owns the Code Viewer, then either waits for
    /// the user (`autoResume: false`) or moves on after a beat.
    private func handOffPendingCodeBlock(autoResume: Bool) {
        guard let codeBlock = pendingCodeBlock else { return }
        pendingCodeBlock = nil
        NotificationCenter.default.post(
            name: .speechOpenCodeViewer,
            object: self.currentMessageID,
            userInfo: [
                "language": codeBlock.language as Any,
                "code": codeBlock.code
            ]
        )

        guard autoResume else {
            // Either pause-on-code, or the user pressed Pause during the announcement.
            isPaused = true
            advancePlaybackIndex()
            // This branch parks the playlist exactly as the finished-while-paused case does; the log line distinguishes the two.
            logger.info("[SPEECH] Code block handed to the viewer and playback HELD (message \(self.messageIDPrefix), \(self.pauseOnCode ? "pause-on-code" : "user paused during the announcement")) — the announcement finished and the playlist parked on segment \(self.currentSegmentIndex) of \(self.totalSegmentCount) without speaking it. CONSEQUENCE: the reader is paused, not stuck inside the announcement; Play speaks that segment once.")
            return
        }

        pendingDelayTask = Task { [weak self] in
            guard let self, self.isActive else { return }
            try? await Task.sleep(for: .seconds(1.0))
            guard !Task.isCancelled, self.isActive else { return }
            self.pendingDelayTask = nil
            self.advancePlaybackIndex()
            self.speakCurrentSegment()
        }
    }

    // MARK: - Segment Parsing

    /// Parses raw markdown text into an ordered list of speech segments.
    /// Text segments have markdown syntax stripped. Code blocks are preserved for the viewer.
    static func parseSegments(from text: String) -> [SpeechSegment] {
        var segments: [SpeechSegment] = []
        var currentText = ""
        var currentCodeLines: [String] = []
        var codeLanguage: String?
        var insideCodeBlock = false

        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if insideCodeBlock {
                    let code = currentCodeLines.joined(separator: "\n")
                    if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let cleaned = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty {
                            segments.append(.text(cleaned))
                            currentText = ""
                        }
                        segments.append(.codeBlock(language: codeLanguage, code: code))
                    }
                    currentCodeLines = []
                    codeLanguage = nil
                    insideCodeBlock = false
                } else {
                    let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    codeLanguage = lang.isEmpty ? nil : lang
                    insideCodeBlock = true
                }
                continue
            }

            if insideCodeBlock {
                currentCodeLines.append(line)
            } else {
                currentText += cleanLineForSpeech(line) + "\n"
            }
        }

        if insideCodeBlock {
            // The text ended inside a fenced block (cancelled mid-block or no closing fence).
            // The rendered bubble repairs the fence, so repair it here too and read the block.
            let code = currentCodeLines.joined(separator: "\n")
            if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let cleaned = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    segments.append(.text(cleaned))
                }
                segments.append(.codeBlock(language: codeLanguage, code: code))
                logger.info("[SPEECH] Repaired an unterminated ``` block while parsing speech segments — \(currentCodeLines.count) line(s) of \(codeLanguage ?? "unlabelled") code had no closing fence. CONSEQUENCE: the block is announced and handed to the viewer like any other; before the repair it was silently dropped from playback while the bubble still showed it.")
                return segments
            }
            // An empty unterminated block has nothing to announce or show. Fall through so
            // any prose BEFORE the fence is still spoken rather than lost with it.
        }

        let remaining = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            segments.append(.text(remaining))
        }

        return segments
    }

    /// Strips markdown syntax from a single line for natural speech.
    private static func cleanLineForSpeech(_ line: String) -> String {
        var cleaned = line
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("#") {
            cleaned = trimmed.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
        }

        cleaned = cleaned.replacingOccurrences(of: "\\*{1,3}([^*]+)\\*{1,3}", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "_{1,3}([^_]+)_{1,3}", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)

        return cleaned
    }

    // MARK: - Legacy

    /// Strips code blocks from text, replacing them with spoken markers.
    static func stripCodeBlocks(from text: String) -> String {
        let segments = parseSegments(from: text)
        var result = ""
        for segment in segments {
            switch segment {
            case .text(let text):
                result += text + "\n"
            case .codeBlock:
                result += "Code block.\n"
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

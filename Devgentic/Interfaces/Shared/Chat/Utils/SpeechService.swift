// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SpeechService.swift
//  Devgentic
//
//  Provides text-to-speech using AVSpeechSynthesizer.
//  Supports segment-based playback: speaks text, then opens code blocks
//  in the Code Viewer panel before continuing.
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

/// An `AVSpeechUtterance` that remembers WHICH `speakUtterance` call created it.
///
/// ⚠️ MEASURED on macOS 26 (Darwin 25.5), a real `AVSpeechSynthesizer` with a full delegate:
/// `stopSpeaking(at:)` delivers **`didFinish`** for the utterance it cancels — `didCancel` was
/// never delivered in any probe, including for a paused synthesizer. Every site here that stops
/// the synthesizer (`skipForward`, `skipBackward`, `restartCurrentUtterance`) then decides what
/// plays next itself, so that completion for the DISCARDED utterance would advance the playlist
/// a second time: one Skip Forward press would play two segments back to back.
///
/// AVFoundation hands the very same object back to each delegate callback (probed), so the stamp
/// travels with the callback and is what tells "the utterance we are still playing" from "an
/// utterance a skip or a restart already threw away". Only the `Int` crosses the actor hop.
private final class StampedUtterance: AVSpeechUtterance {
    /// `SpeechService.utteranceGeneration` at the moment this utterance was handed over.
    ///
    /// ⚠️ OPTIONAL, and `nil` on the decode path on purpose. The completion guard fails OPEN
    /// only on `nil`; any concrete value is compared for equality. A sentinel like `0` would
    /// therefore fail CLOSED — `speakUtterance` pre-increments, so no live utterance is ever
    /// generation 0 and a decoded one could never match — parking playback forever, which is
    /// the exact outcome `completionBelongsToInFlightUtterance` documents as the worse failure.
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

    /// [V5] Created per playback session and RELEASED at stop/finish — not held for the
    /// app's lifetime. A live AVSpeechSynthesizer keeps a CoreAudio output context open,
    /// which is exactly the pattern the Orb notes document as wedging the microphone
    /// (`OrbVoiceOutput` releases per-utterance for the same reason). Releasing when
    /// idle costs one lazy re-creation on the next Read Aloud.
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

    /// How many surfaces that can show the `SpeechControlIsland` are on screen: the main
    /// window's `ChatHistoryView` (Chat and Code modes each mount one) and the QuickAccess
    /// panel's EXPANDED transcript. The island mounts inside those views, so at zero a live
    /// session has no Play, Pause or Stop anywhere. Closing the panel (Esc), ⌘W on the main
    /// window, switching it to Workflow mode, or collapsing the panel all used to leave the
    /// reader speaking with the synthesizer — and its CoreAudio output context, the [V5]
    /// lifetime — held, and nothing to stop it short of re-summoning a surface.
    ///
    /// A SET of host identities, not a per-surface stop and not a bare counter. Not per-surface
    /// because this service is a singleton shared by both surfaces: stopping on any ONE
    /// surface's teardown would kill a session the OTHER surface was still showing a transport
    /// for (start Read Aloud in the main window, summon the panel for a quick question, press
    /// Esc → silence). Not a counter because SwiftUI's `onAppear`/`onDisappear` delivery is
    /// not something this code can prove pairs exactly once per mount, and AppKit's panel close
    /// is a second, non-SwiftUI teardown route: with a counter one duplicate appear leaks +1 and
    /// silently disarms the rule for the rest of the process, and one duplicate disappear steals
    /// a host that is still on screen. Keyed by identity, both are idempotent — a host that
    /// registers twice is one host, and the panel can deregister its transcript on close
    /// whether or not SwiftUI also delivered `onDisappear`.
    private(set) var transportHostIDs: Set<UUID> = []

    /// How many surfaces currently host the transport.
    var mountedTransportHosts: Int { transportHostIDs.count }

    func transportHostDidAppear(_ id: UUID) {
        let inserted = transportHostIDs.insert(id).inserted
        logger.debug("[SPEECH] Transport host \(id.uuidString.prefix(8)) \(inserted ? "mounted" : "re-registered (already counted)") — \(self.transportHostIDs.count) on screen.")
    }

    /// Stops a live session once the LAST host is gone — checked one main-actor turn later,
    /// because a mode switch tears one `ChatHistoryView` down and mounts another inside the
    /// same SwiftUI transaction and the order of the two callbacks is not specified; the next
    /// turn sees the settled set.
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

    /// Cancels whatever OTHER driver is currently feeding this service, set by that driver while
    /// it holds the floor.
    ///
    /// Today that is `OrbStreamingSpeaker`, which registers on the same line it already calls
    /// `stop()` to take the floor. The problem it solves: pressing Read Aloud called `stop()`,
    /// which silences the synthesizer and clears the session — but Orb's speaker is a
    /// STREAMING driver that goes on ingesting the answer and queueing utterances into the
    /// service it no longer owns, so the two interleaved and the chat answer was read out with
    /// fragments of Orb's narration spliced through it.
    ///
    /// A CLOSURE rather than a reference to the speaker: `OrbSessionController` is
    /// constructed per panel and has no singleton, so there is nothing global to reach for, and
    /// `SpeechService` must not learn about Orb types to do this.
    ///
    /// ⚠️ Narration ONLY. `OrbVoiceOutput`'s short phrases (greeting, approval, completion)
    /// deliberately use a private synthesizer so chat Read Aloud does NOT hard-cancel them
    /// mid-sentence; that decision is documented on that type and this must not undo it.
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

    /// [CF-21] Whether the surface that started this session has a Code Viewer to hand a code
    /// block to. Set by `speak(_:messageID:canPresentCodeViewer:)`, reset at session end.
    ///
    /// The `.speechOpenCodeViewer` hand-off is fire-and-forget: its observer calls
    /// `showCodeInViewer` on whatever `ChatHistoryViewModel` is in its environment, and
    /// QuickAccess's is built WITHOUT `ownsCodeViewer`, so nothing opens. The reader still
    /// announced "Here is the code in the panel view", and with pause-on-code enabled then
    /// stopped waiting for a user action in a window that mounts no transport controls.
    ///
    /// The default is `true` so a caller that doesn't pass the flag keeps main-window behavior.
    /// `ChatBubbleView.toggleReadAloud` — the only caller, shared by the main window and
    /// QuickAccess — now passes `chatHistoryViewModel.canPresentCodeViewer`, so QuickAccess's
    /// view model (built WITHOUT `ownsCodeViewer`) correctly gets `false` and the wrong
    /// announcement / stuck-waiting-on-a-panel-that-never-appears symptom is gone.
    ///
    /// ⚠️ CF-21's "QuickAccess mounts no speech island" is CLOSED — `QuickAccessContentView`
    /// mounts one. But the gap it described is not fully gone, and the replacement is narrower
    /// rather than nothing: that island is an `.overlay` on `transcriptView`, and
    /// `transcriptView` renders only under `if isExpanded`. So a reader STARTED from the
    /// expanded panel and then collapsed keeps running with `isActive == true` and no Play,
    /// Pause or Stop anywhere in that window. The main window's island is gated on the same
    /// `isActive`, so the user is stranded only when the main window is closed or hidden —
    /// which is the ordinary QuickAccess posture. Tracked as its own row, not as this comment.
    @ObservationIgnored private var sessionCanPresentCodeViewer: Bool = true

    /// Test seam: the code-viewer capability the current session was started with.
    var sessionCanPresentCodeViewerForTesting: Bool { sessionCanPresentCodeViewer }

    // MARK: - In-flight utterance tracking [CF-18]

    /// The text of the utterance currently inside the synthesizer, nil when nothing is in
    /// flight (between segments, during the code-block delay, or idle).
    ///
    /// Rate and voice are BAKED INTO an `AVSpeechUtterance` at creation (`makeUtterance`), so a
    /// setting changed mid-playback never reaches the utterance already queued — and because
    /// `parseSegments` splits only on ``` fences, a message with no code block is ONE utterance
    /// for the whole answer. Changing speed or voice therefore did nothing for the common case
    /// while the island showed the new setting. Knowing what is in flight, and how far into it
    /// playback has got, lets `setRate`/`setVoice` re-speak the remainder with the new setting.
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

    /// The generation of the utterance the service still considers in flight — nil whenever
    /// nothing is (between segments, during the code-block delay, idle). Set and cleared in
    /// lockstep with `currentUtteranceText`.
    ///
    /// This, not the monotonic counter, is what `handleUtteranceFinished` compares against: a
    /// completion whose generation is no longer the in-flight one belongs to an utterance a skip
    /// or a restart discarded, and acting on it double-advances the playlist. Nil-vs-nil never
    /// matches either, so a SECOND completion for a generation already consumed (the tracking is
    /// cleared as the first is handled) is ignored too — that is the `.holdAtNextSegment` case,
    /// where no replacement utterance is spoken to move the counter on.
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
    ///
    /// [CF-21] `canPresentCodeViewer` is the calling surface's answer to "do I have a Code
    /// Viewer to open into?" — pass `chatHistoryViewModel.canPresentCodeViewer`. When it is
    /// false the reader says a code block is being SKIPPED instead of promising a panel, posts
    /// no `.speechOpenCodeViewer`, and never enters the pause-on-code wait. It defaults to true
    /// so the main window (which does own a viewer) keeps its behaviour unchanged.
    func speak(_ rawText: String, messageID: UUID, canPresentCodeViewer: Bool = true) {
        // [sa-8] BEFORE `stop()`: stopping only silences the synthesizer, and a streaming driver
        // that is still ingesting would keep queueing into the session this call is about to
        // start.
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

    /// [CF-18] Forgets the in-flight utterance. Called wherever the utterance the tracking
    /// describes is no longer the one in the synthesizer (finish, stop, skip, session end) —
    /// a stale text here would make a later setting change re-speak the WRONG segment.
    private func clearUtteranceTracking() {
        currentUtteranceText = nil
        activeUtteranceGeneration = nil
        spokenUpTo = 0
        restartOnResume = false
    }

    /// Pauses speech at the next word boundary.
    func pauseSpeaking() {
        guard isActive, !isPaused else { return }

        // ⚠️ [sa-2] The 1-second beat after a code-block hand-off is a hole in every other
        // transport verb's coverage. `stop()`, `skipForward()` and `skipBackward()` all cancel
        // `pendingDelayTask`; this did not — and during that beat there is nothing in the
        // synthesizer to pause (`handleUtteranceFinished` cleared the tracking before dispatching
        // here), so `pauseSpeaking(at:)` was a no-op on an idle synthesizer. The transport flipped
        // to Paused, the beat fired anyway, and the NEXT segment spoke in full under a Paused
        // island — the flag only took effect one segment later.
        //
        // Treat the beat as a park point, exactly as the `autoResume: false` branch already does:
        // cancel it and advance, so Play speaks the next segment ONCE rather than re-announcing
        // the code block (the playlist has not advanced yet during the beat — that happens inside
        // the task — so simply cancelling would leave `speakCurrentSegment` to re-enter the
        // `.codeBlock` case and announce it a second time).
        if pendingDelayTask != nil {
            pendingDelayTask?.cancel()
            pendingDelayTask = nil

            // ⚠️ A code block as the LAST segment has nothing to park on. Advancing past the end
            // and setting `isPaused` would leave a session whose island shows "N of N" with a
            // Play button that can only end it, and a bubble still reading "Stop". That is the
            // one case where the old behaviour was accidentally correct — the beat ran off the
            // end and finished cleanly — so preserve the outcome rather than the mechanism.
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
        // [CF-22] The request is honoured at the NEXT word boundary, so `isPaused` runs ahead
        // of the synthesizer here. `didPause` logs when (or whether) it actually landed.
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
            // [CF-18] Speed or voice changed while paused. `continueSpeaking()` would resume the
            // utterance already in the synthesizer, with the OLD setting baked in — so drop it
            // and re-speak from the last word boundary with the new one.
            restartOnResume = false
            restartCurrentUtterance(reason: "resume after a settings change while paused")
        } else if currentUtteranceText != nil, synthesizer?.isPaused == true || synthesizer?.isSpeaking == true {
            // ⚠️ `isPaused == true` is NOT sufficient, and testing it alone was PERMANENT SILENCE.
            // MEASURED on macOS 26: `pauseSpeaking(at: .word)` returns true but leaves `isPaused`
            // FALSE until the word boundary actually lands — so a Play pressed within that window
            // (a user changing their mind, ~300ms) fell through to `speakCurrentSegment()` and
            // queued a second utterance BEHIND an utterance that was about to pause. The
            // synthesizer then paused and the queued one never started: probe recorded
            // `isPaused=true, isSpeaking=true`, events `[start, pause]`, and no completion ever —
            // a dead-silent reader under a Playing transport, escapable only by Stop or Skip.
            // `isSpeaking` is what covers the pause-pending window; `continueSpeaking()` is
            // harmless when the pause has not landed yet.
            synthesizer?.continueSpeaking()
        } else {
            // [CF-22] `currentUtteranceText` leads here. When an utterance FINISHED while the
            // pause was still pending at a word boundary, `handleUtteranceFinished` cleared the
            // tracking and left the playlist parked on the next segment — but whether the
            // synthesizer also drops its paused flag when its queue drains is undocumented, and
            // a `continueSpeaking()` with nothing queued resumes silence for good.
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
        // ⚠️ The code-block auto-resume sleep must die with the skip, exactly as in `stop()`.
        // Left running, it fires ~1s later on top of the segment the skip just started and
        // advances the playlist a SECOND time; when the skip landed on the last segment it
        // instead tears the transport down mid-speech.
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
        // ⚠️ The code-block auto-resume sleep must die with the skip, exactly as in `stop()`.
        // Left running, it fires ~1s later on top of the segment the skip just started and
        // advances the playlist a SECOND time; when the skip landed on the last segment it
        // instead tears the transport down mid-speech.
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

    /// Sets the speech rate multiplier and persists it. [CF-18] Also applies it to the
    /// utterance in flight — a setting that only reached the NEXT segment did nothing for a
    /// message with no code block, which is one segment.
    func setRate(_ rate: Float) {
        currentRate = rate
        UserDefaults.standard.set(rate, forKey: AppSettings.speechPlaybackRateKey)
        logger.info("[SPEECH] Speech rate set to \(rate)× (message \(self.messageIDPrefix))")
        applySettingToCurrentUtterance(setting: "rate \(rate)×")
    }

    /// Sets the voice and persists it. [CF-18] Also applies it to the utterance in flight.
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

    /// [CF-18] Makes a just-changed rate or voice audible NOW rather than at the next segment.
    ///
    /// Three cases:
    ///   - Speaking: stop the utterance and re-speak its remainder with the new setting.
    ///   - Paused: flag it; `resumeSpeaking` re-speaks the remainder instead of continuing.
    ///   - Active but nothing in flight (the 1s code-block delay, or a paused-on-code stop after
    ///     the announcement finished): nothing to restart — the next segment is created with the
    ///     new setting by `makeUtterance`, so it is already covered.
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

        // Our own tracking says something is in flight, but trust the synthesizer for the
        // restart itself: in the gap between the synthesizer finishing an utterance and
        // `didFinish` hopping to the main actor, a restart would queue a stray remainder
        // BEHIND the next segment and then advance the playlist twice when it finished.
        guard let synthesizer, synthesizer.isSpeaking else {
            logger.info("[SPEECH] \(setting) — synthesizer reports nothing speaking (message \(self.messageIDPrefix)); not restarting, the next utterance picks it up.")
            return
        }

        restartCurrentUtterance(reason: setting)
    }

    /// [CF-18] Cancels the utterance in the synthesizer and speaks what was left of it, from
    /// the last word boundary `willSpeakRangeOfSpeechString` reported, with the CURRENT rate
    /// and voice. `pendingCodeBlock` and the playlist indices are untouched, so a restarted
    /// announcement still opens its code block when the remainder finishes.
    private func restartCurrentUtterance(reason: String) {
        guard let text = currentUtteranceText else { return }
        let remainder = Self.remainder(of: text, spokenUpTo: spokenUpTo)
        let offset = spokenUpTo

        // ⚠️ `stopSpeaking(at:)` delivers `didFinish` for the utterance it cancels (measured —
        // see `StampedUtterance`; the previous comment here asserted the opposite). That stray
        // completion is discarded by the generation guard in `handleUtteranceFinished`, because
        // both branches below leave a DIFFERENT generation in flight than the one being stopped.
        if let synthesizer, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // The change landed on the final word. Nothing is left to say, and the cancelled
            // utterance's own `didFinish` is about to be discarded as stale, so advance the
            // playlist here exactly as it would have — otherwise playback hangs on this segment.
            logger.info("[SPEECH] \(reason): nothing left of the current utterance after offset \(offset) (message \(self.messageIDPrefix)) — advancing as if it had finished.")
            handleUtteranceFinished()
            return
        }

        logger.info("[SPEECH] \(reason): re-speaking the current utterance from UTF-16 offset \(offset) of \(text.utf16.count) (message \(self.messageIDPrefix)).")
        // The un-pause guard that used to live here now lives in `speakUtterance` itself, so
        // every enqueue is covered rather than this one path — see its note.
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
            // [CF-21] Only take on the code-viewer hand-off when this session's surface has a
            // viewer. Without one, `pendingCodeBlock` would post a notification nobody acts on,
            // and — with pause-on-code enabled — hold playback for a resume the user has no
            // transport to press.
            guard sessionCanPresentCodeViewer else {
                logger.info("[SPEECH] Code block (\(language ?? "unlabelled"), \(code.count) chars) SKIPPED for message \(self.messageIDPrefix) — this surface has no Code Viewer to open it in. CONSEQUENCE: the listener is told the block is being skipped instead of being promised a panel, and playback continues to the next segment.")
                speakUtterance(Self.codeBlockAnnouncement(canPresentCodeViewer: false, language: language))
                return
            }
            pendingCodeBlock = (language: language, code: code)
            speakUtterance(Self.codeBlockAnnouncement(canPresentCodeViewer: true, language: language))
        }
    }

    /// [CF-21] What the reader says when it reaches a code block.
    ///
    /// The panel sentence is a PROMISE, and it was made unconditionally. Where no Code Viewer
    /// can be presented (QuickAccess), naming the block and moving on is the honest version —
    /// and it is what lets `speakCurrentSegment` skip the hand-off without the listener losing
    /// track of the response's structure.
    nonisolated static func codeBlockAnnouncement(canPresentCodeViewer: Bool, language: String?) -> String {
        if canPresentCodeViewer {
            return "Here is the code in the panel view."
        }
        guard let language, !language.trimmingCharacters(in: .whitespaces).isEmpty else {
            return String(localized: "Skipping a code block. There is no code panel in this window.")
        }
        return String(localized: "Skipping a \(language) code block. There is no code panel in this window.")
    }

    /// [CF-18] The ONE path that hands an utterance to the synthesizer, so the service always
    /// knows what is in flight. Bypassing this for a `speak` call would leave a setting change
    /// unable to find (and re-speak) that utterance.
    private func speakUtterance(_ text: String) {
        utteranceGeneration &+= 1
        let utterance = makeUtterance(text, generation: utteranceGeneration)
        currentUtteranceText = text
        activeUtteranceGeneration = utteranceGeneration
        spokenUpTo = 0
        restartOnResume = false
        ensureSynthesizer().speak(utterance)

        // ⚠️ Stopping a PAUSED synthesizer is documented to clear its queue; whether it also
        // clears the paused FLAG is not. An utterance enqueued into a still-paused synthesizer
        // never starts, and because the transport reads `isActive`, the UI sits on "Playing"
        // in permanent silence with no completion ever arriving to advance the playlist.
        //
        // This guard was written for `restartCurrentUtterance` and lived there — one of the
        // four paths that speak into a just-stopped synthesizer. Skip forward, skip backward
        // and the resume-into-a-drained-queue path had the same exposure and no guard. It
        // belongs HERE, on the single documented enqueue path, so a fifth caller cannot
        // reintroduce the hole by forgetting it.
        // ⚠️ `!isPaused` is load-bearing, and I got this wrong first: hoisting the guard here
        // without it made EVERY enqueue un-pause, including the code-block auto-resume's delayed
        // one — so a Pause pressed during that 1s window was overridden AUDIBLY, where before it
        // had been (accidentally) honoured by the very silence this guard exists to remove.
        //
        // The two states are different things. `synthesizer.isPaused` can be a STALE AVFoundation
        // flag left by a `stopSpeaking` — nobody asked for it, and an utterance enqueued behind it
        // never starts. `isPaused` is the SERVICE's record of a deliberate pause (`pauseSpeaking`,
        // or the pause-on-code branch above). Resume only the former. The auto-resume path leaves
        // `isPaused` false, so it is unaffected; a user pause during the delay now survives, and
        // Play speaks that segment once.
        if let synthesizer, synthesizer.isPaused, !isPaused {
            logger.info("[SPEECH] Synthesizer was still PAUSED when the next utterance was enqueued (message \(self.messageIDPrefix)) — resuming it, because nothing asked for that pause. CONSEQUENCE: without this the utterance never starts and the transport shows Playing over silence.")
            synthesizer.continueSpeaking()
        }
    }

    /// Creates an AVSpeechUtterance with current rate and voice settings, stamped with the
    /// generation that lets a completion for it be told apart from a completion for an utterance
    /// a skip or a restart discarded (see `StampedUtterance`).
    ///
    /// ⚠️ Rate and voice are fixed on the utterance from here on — AVFoundation offers no way to
    /// change them for an utterance already queued. That is why a live change must go through
    /// `restartCurrentUtterance` rather than "just apply".
    private func makeUtterance(_ text: String, generation: Int) -> AVSpeechUtterance {
        let utterance = StampedUtterance(string: text, generation: generation)
        utterance.rate = avRate(for: currentRate)

        if let voiceID = selectedVoice,
           let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        }

        return utterance
    }

    /// [CF-18] The part of `text` not yet spoken, given the UTF-16 offset of the last word the
    /// synthesizer reported via `willSpeakRangeOfSpeechString`. Re-speaking from the START of
    /// that word repeats one word rather than dropping one, which is the better of the two.
    ///
    /// Pure and clamped: 0 (or negative) returns the whole text — no word has been reported
    /// yet — and an offset at or past the end returns "". The offset is UTF-16 because the
    /// synthesizer hands over an `NSRange`; `String.Index(utf16Offset:in:)` maps it onto the
    /// Swift string, and a slice at that index rounds down to a scalar boundary rather than
    /// splitting a surrogate pair.
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

    /// ⚠️ This fires for a CANCELLED utterance too — `stopSpeaking(at:)` delivers `didFinish`,
    /// not `didCancel`, on macOS (measured; see `StampedUtterance`). The generation stamp is
    /// what keeps a skip or a live-settings restart from being read as "that segment ended".
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let generation = (utterance as? StampedUtterance)?.generation ?? nil
        Task { @MainActor [weak self] in
            self?.handleUtteranceFinished(generation: generation)
        }
    }

    /// [CF-18] Position tracking. Delivered once per word (the range about to be spoken);
    /// hops to the main actor like `didFinish` because that is where the state lives. Only
    /// the range's location and the utterance's text cross the hop — both `Sendable`.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let location = characterRange.location
        let text = utterance.speechString
        Task { @MainActor [weak self] in
            self?.handleWillSpeakRange(location: location, text: text)
        }
    }

    /// Deliberately a no-op — and, on macOS, never called.
    ///
    /// ⚠️ This used to be documented as THE cancellation signal: "`stopSpeaking(at:)` delivers
    /// `didCancel`, not `didFinish`". That is false here. A probe against a real synthesizer
    /// (immediate stop, stop-at-word, stop while paused, stop-then-speak-the-next-segment)
    /// delivered `didFinish` every time and `didCancel` not once. Cancellation is therefore
    /// recognised by the `StampedUtterance` generation in `handleUtteranceFinished`, not here.
    /// The method stays as a no-op so a platform or path that DOES deliver it cannot advance
    /// the playlist behind the call site's back.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Intentionally empty — see the doc comment.
    }

    /// [CF-22] Records that a `pauseSpeaking(at: .word)` request reached the synthesizer.
    ///
    /// ⚠️ It does NOT mean the utterance is being held. Measured: `didPause` fires in BOTH
    /// outcomes of the CF-22 race — pause at 0.35s into a 0.7s utterance gives `[start, pause]`
    /// and `isPaused == true`, pause at 0.5s gives `[start, pause, finish]` and `isPaused ==
    /// false`. The line therefore reports only that the request landed, and names the utterance
    /// generation so the "[SPEECH] Utterance finished while PAUSED" line that follows in the
    /// overtaken case is unambiguously about the SAME utterance rather than the next one.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        let generation = (utterance as? StampedUtterance)?.generation ?? nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            logger.info("[SPEECH] A pause request reached the synthesizer (message \(self.messageIDPrefix), segment \(self.currentSegmentIndex) of \(self.totalSegmentCount), utterance generation \(generation.map(String.init) ?? "unstamped")). CONSEQUENCE: the reader holds inside this segment UNLESS a 'finished while PAUSED' line follows for the same generation — that one means the utterance ended before the word boundary and the playlist parked on the NEXT segment instead.")
        }
    }

    /// Records how far into the in-flight utterance playback has got.
    ///
    /// Keyed on the utterance TEXT rather than object identity: a range report from an
    /// utterance that was just cancelled can still be in the main-actor hop when its
    /// replacement starts, and the text is what tells the two apart. (When a restart happened
    /// at offset 0 the texts are identical — and then the offset is valid for either.)
    private func handleWillSpeakRange(location: Int, text: String) {
        guard isActive, let current = currentUtteranceText, current == text else { return }
        spokenUpTo = location
    }

    /// [CF-22] What `handleUtteranceFinished` does when an utterance completes. Extracted so
    /// the decision can be tested without a live synthesizer, which is the only way to reach it.
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

    /// The completion table.
    ///
    /// `isPaused` is the [CF-22] half, and it was missing entirely: `pauseSpeaking(at: .word)`
    /// is honoured at the NEXT word boundary, so an utterance that ends before that boundary
    /// still delivers `didFinish` with `isPaused` already true. Speaking on regardless put live
    /// audio under a transport showing Play, and the Play the user then pressed found the
    /// synthesizer un-paused and spoke that same segment a SECOND time (re-opening the viewer
    /// with it, for a code block).
    ///
    /// `hasNextSegment` asks whether a segment exists AFTER the one that just finished.
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

    /// Whether a delivered completion belongs to the utterance still in flight.
    ///
    /// `reported == nil` means the completion did not come from the synthesizer at all — it is
    /// `restartCurrentUtterance` standing in for a `didFinish` it just made impossible — so it is
    /// always honoured. It also covers an utterance that somehow reached the delegate without its
    /// stamp: unknown fails OPEN, to the pre-stamp behaviour, because a completion wrongly
    /// ignored parks playback forever while one wrongly honoured only skips a segment.
    ///
    /// Extracted so the rule is testable without a live synthesizer; `handleUtteranceFinished`
    /// is its only caller.
    nonisolated static func completionBelongsToInFlightUtterance(reported: Int?, inFlight: Int?) -> Bool {
        guard let reported else { return true }
        return reported == inFlight
    }

    /// Handles utterance completion on the main actor where all state lives.
    ///
    /// `generation` is the stamp carried by the completing utterance, or nil for the internal
    /// stand-in call from `restartCurrentUtterance`.
    private func handleUtteranceFinished(generation: Int? = nil) {
        guard isActive else { return }

        let completedGeneration = activeUtteranceGeneration
        guard Self.completionBelongsToInFlightUtterance(reported: generation, inFlight: completedGeneration) else {
            // `stopSpeaking(at:)` reports `didFinish` for the utterance it cancelled (measured —
            // see `StampedUtterance`), and `skipForward`/`skipBackward`/`restartCurrentUtterance`
            // have already chosen and started what plays next by the time it arrives.
            logger.info("[SPEECH] Ignored a completion for utterance generation \(generation.map(String.init) ?? "unstamped") — generation \(completedGeneration.map(String.init) ?? "none") is in flight (message \(self.messageIDPrefix)). CONSEQUENCE: the playlist stays on segment \(self.currentSegmentIndex) of \(self.totalSegmentCount); acting on it would advance a second time and play two segments at once.")
            return
        }

        // [CF-18] Whatever comes next is a new utterance; a settings change in the meantime
        // must not try to re-speak this finished one.
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

    /// Test seam: replays a delegate completion for a given utterance generation, through the
    /// production handler. The real path needs a live `AVSpeechSynthesizer`, audio output, and a
    /// race whose whole point is that it lands a few milliseconds AFTER the skip that caused it —
    /// none of which a test can arrange. Pass the generation a skip left behind to reproduce the
    /// stale completion; pass the in-flight one for a natural finish.
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
            // Either pause-on-code, or [CF-22] the user pressed Pause during the announcement.
            isPaused = true
            advancePlaybackIndex()
            // ⚠️ This branch parks the playlist exactly as the "finished while PAUSED" case does,
            // and used to do it silently — so a field log showed a pause request with no
            // follow-up and read as "held inside the announcement", which is what the didPause
            // line tells the reader to conclude. It is the other outcome, and now says so.
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
            // [CF-20] The text ended INSIDE a fenced block — the response was cancelled
            // mid-block, or the model never wrote the closing fence. Only the fence-CLOSE
            // branch above appends a `.codeBlock`, so those lines used to be discarded here
            // with no log, and `totalSegmentCount` was short by one. The bubble does not
            // agree: the finalized render runs `preprocessStreamResilientMarkdown`, which
            // appends the missing fence, so the user sees a code block Read Aloud pretended
            // was not there. Repair the fence on this side too.
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

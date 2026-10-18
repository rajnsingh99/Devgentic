// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbSessionController.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import AppKit
import AVFoundation
import Observation

// MARK: - Stage

/// The stages of an Orb voice session, from profile selection through listening, execution and announcement.
enum OrbStage: Equatable {
    /// Pick which Bot/Agent profile powers the session (always asked on open).
    case selectingProfile
    /// Greeting TTS is playing.
    case welcoming
    /// Wake-word scan — say "Orb" to arm command capture.
    case passiveListening
    /// Wake word heard; capturing the command until the user stops talking.
    case commandCapture
    /// Just answered, microphone still hot: ANY speech now is a follow-up, no wake word needed.
    /// The deadline lives on the controller rather than in the case so `stage == .followUpWindow`
    /// stays a plain equality check at every call site.
    case followUpWindow
    /// A run is streaming through the chat pipeline.
    case executing
    /// Completion TTS is playing.
    case announcing
    /// The run has stopped to ask the user something and is waiting for an answer.
    case awaitingApproval
    /// Voice input can't run (no model / mic denied / session failure).
    case voiceUnavailable(reason: String)
}

/// A phrase that controls Orb instead of being sent to the model.
/// What a FINISHED capture becomes. Produced only by `OrbSessionController.classifyCapture(_:)`,
/// which both recognizer loops switch on — one decision, not two drifting copies.
enum OrbCaptureOutcome: Equatable {
    /// A spoken cancel or stop. Nothing is sent.
    case cancel
    /// A control phrase for Orb itself, never forwarded to the model.
    case voiceCommand(OrbVoiceCommand)
    /// A real request — sent to the profile.
    case dispatch
    /// Something was heard, but fewer words than `minimumCommandWords`.
    case belowFloor
    /// Capture was armed and nothing was said.
    case nothingHeard
}

/// What one transcript update from a NARRATION LISTENER does. Produced only by
/// `OrbSessionController.narrationListenerAction(openedDuringNarration:stage:transcript:)`.
enum OrbNarrationListenerAction: Equatable {
    /// The session was not opened during narration — ordinary handling applies.
    case notANarrationListener
    /// The narration has ended and this session is closing: drop the update. Never falls through.
    case dropStale
    /// Still narrating, and no stop phrase yet.
    case keepListening
    /// Still narrating, and the user said stop.
    case interrupt
}

enum OrbVoiceCommand: Equatable {
    case repeatAnswer
    case newConversation
    /// Escalating detail about the run that just finished, spoken only on request.
    /// A report after every turn would be noise on top of an answer the user just heard in full.
    case whatWentWrong
    case whatDidYouChange
    /// Speaks the part of the answer a length setting held back. This is what makes a short
    /// default a CHOICE rather than a loss — and it is the answer to the truncation notice, which
    /// otherwise points at a chat window the user may not be near.
    case tellMeMore
}

// MARK: - Controller

@MainActor @Observable
final class OrbSessionController {

    // MARK: Tunables

    /// Bumped whenever a tester is asked to verify a change, so a log proves which binary ran.
    static let featureMarker = "pr10 (spoken stop — whole-utterance stop words; voice interrupt while speaking when AEC is live)"
    // Why: read at use time, never cached in a `let`, so a changed Setting reaches the matchers of a running orb.
    /// Canonical wake word: the user's configured word, sanitized, defaulting to "orb".
    static var wakeWord: String { OrbConfigManager.shared.wakeWord }
    /// Spoken when a run ends well; call sites use `announcement(for:reason:)` to reflect the real outcome.
    static let completionPhrase = String(localized: "Your task is completed, let me know next")
    // Why: read at use time: the panel lives outside the SwiftUI environment; the config manager is Settings' only channel.
    /// Command considered final after this much stability of the normalized transcript.
    /// Read from the config manager at use time; the watchdog re-reads it on every 300ms tick.
    private static var commandSilenceCommit: TimeInterval {
        OrbConfigManager.shared.endpointing.seconds
    }
    /// Wake word heard but nothing said — give up capture and re-arm after this.
    private static let emptyCaptureTimeout: TimeInterval = 8.0
    // Why: in a noisy room Whisper keeps producing changing text, so no stability window settles; this cap ends capture.
    /// Hard cap for a single capture session: whatever has been heard by then is the command.
    private static let captureHardCap: TimeInterval = 18.0
    /// Recycle passive sessions to bound WhisperKit's ever-growing audio buffer.
    private static let passiveRecycleInterval: TimeInterval = 45.0
    private static let energyBarCount = 48

    // Why: Whisper hallucinates short filler on silence and agent profiles have shell tools; one token must not start a run.
    /// Minimum word count before a capture is dispatched to a profile.
    static let minimumCommandWords = 2

    /// Spoken phrases that ABORT an armed capture instead of becoming the command.
    /// The audible half of the cancel path — see `cancelCapture()` for why one was needed.
    static let cancelPhrases = ["never mind", "nevermind", "cancel that", "forget it"]

    // Why: kept apart from `cancelPhrases`: that list matches suffixes and denies parked tools, so widening it breaks both.
    /// Short ways of saying "stop" to a capture, or to Orb while it is speaking.
    static let stopPhrases = ["stop", "stop it", "stop talking", "cancel", "enough",
                              "quiet", "be quiet", "shush", "shut up"]

    // Why: only safe on a finished utterance: a partial "stop" of "stop the server" would cancel the request mid-sentence.
    /// Whether the whole utterance is a stop phrase, said once or repeated ("stop, stop"). Pure.
    static func isStopPhrase(_ utterance: String) -> Bool {
        let words = normalizedForStability(utterance).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }
        return stopPhrases.contains { phrase in
            let unit = phrase.split(separator: " ").map(String.init)
            guard words.count % unit.count == 0 else { return false }
            return stride(from: 0, to: words.count, by: unit.count)
                .allSatisfy { Array(words[$0..<($0 + unit.count)]) == unit }
        }
    }

    /// Whether a transcript heard while Orb speaks ends in a stop phrase. Pure.
    /// Looser than `isStopPhrase` (a suffix, not the whole utterance) so a stray word before "stop" does not defeat it.
    /// A false match only stops the answer early; it remains in the chat window.
    static func endsWithStopPhrase(_ transcript: String) -> Bool {
        let normalized = normalizedForStability(transcript)
        guard !normalized.isEmpty else { return false }
        return stopPhrases.contains { normalized == $0 || normalized.hasSuffix(" " + $0) }
    }

    // Why: never during an approval announcement: an interrupt there would drop the orb to passive listening with a run parked.
    /// Whether a microphone may stay open while Orb speaks, listening only for a stop. Pure.
    /// Requires echo cancellation, and a WhisperKit recognizer: Apple Speech releases the duplex engine first.
    static func listensDuringNarration(echoCancelling: Bool,
                                       recognizerIsAppleSpeech: Bool,
                                       announcingApproval: Bool) -> Bool {
        echoCancelling && !recognizerIsAppleSpeech && !announcingApproval
    }

    // Why: nothing may fall through to the ordinary path: its follow-up window dispatches any late speech.
    /// What a transcript update from a narration listener does. Pure.
    static func narrationListenerAction(openedDuringNarration: Bool,
                                        stage: OrbStage,
                                        transcript: String) -> OrbNarrationListenerAction {
        guard openedDuringNarration else { return .notANarrationListener }
        guard stage == .announcing else { return .dropStale }
        return endsWithStopPhrase(transcript) ? .interrupt : .keepListening
    }

    // Why: order is load-bearing: cancel and stop are checked before the dispatch floor, so a one-word "stop" is a cancel.
    /// What a finished capture becomes. Pure, and the only place this decision is made.
    static func classifyCapture(_ command: String) -> OrbCaptureOutcome {
        if isCancelPhrase(command) || isStopPhrase(command) { return .cancel }
        if let voiceCommand = voiceCommand(in: command) { return .voiceCommand(voiceCommand) }
        if isDispatchable(command) { return .dispatch }
        return command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .nothingHeard : .belowFloor
    }

    /// Seconds to wait for `AVSpeechSynthesizer`'s `didFinish` before handing back anyway.
    /// Generous: it is a deadlock breaker, not a pacing control.
    private static let speechCompletionTimeout: TimeInterval = 20

    // Why: AVSpeechSynthesizer tears down its output after didFinish; opening the engine sooner races it and leaves a dead mic.
    /// CoreAudio settle time before opening the mic.
    /// Pairs with `OrbVoiceOutput.releaseAudio()`, which deallocates the synthesizer first.
    private static let audioSettleDelay: TimeInterval = 1.0

    /// The settle used when the microphone is Bluetooth and Orb has just spoken, or the last session opened deaf.
    /// Earbuds must switch from playback mode to microphone mode before recording, which takes longer than the default.
    static let bluetoothAudioSettleDelay: TimeInterval = 2.5

    /// How long to wait before opening the microphone. Pure.
    /// `secondsSinceSpeech` is nil if Orb never spoke; `afterDeadSession` means the previous session delivered no audio.
    static func settleDelay(bluetoothInput: Bool, secondsSinceSpeech: TimeInterval?,
                            afterDeadSession: Bool) -> TimeInterval {
        guard bluetoothInput else { return audioSettleDelay }
        if afterDeadSession { return bluetoothAudioSettleDelay }
        // Only right after speech: a passive recycle needs no mode switch, and a longer settle would lose the wake word.
        if let secondsSinceSpeech, secondsSinceSpeech < bluetoothAudioSettleDelay { return bluetoothAudioSettleDelay }
        return audioSettleDelay
    }

    /// Whether the watchdog ends a WhisperKit session that delivered no audio, so the retry ladder reopens the mic now.
    /// A narration listener is left alone: it closes with the answer and its audio is never classified.
    static func endsDeadSession(receivedAudio: Bool, sessionAge: TimeInterval, narrationListener: Bool) -> Bool {
        !receivedAudio && !narrationListener && sessionAge > deadAudioWarningDelay
    }

    // Why: skipping is sound only while both speech paths use the shared engine; a plain AVSpeechSynthesizer breaks it.
    /// Releases the speech synthesisers and waits out the CoreAudio race, unless the duplex engine is up and cancelling echo.
    private func settleAudioBeforeCapture() async {
        // Ambient announcements speak without holding the stage; releasing audio here would deallocate the synthesizer
        // mid-sentence. Waiting costs at most one delayed session.
        if voice.isSpeaking, ambientSpeechInFlight {
            logger.info("[ORB_SESSION]\(self.tag) Holding the microphone closed until the ambient announcement finishes. CONSEQUENCE: this session opens a moment later; without it the announcement would be cut off mid-sentence with nothing logged.")
            for _ in 0..<Int(Self.ambientSpeechGrace * 10) {
                guard voice.isSpeaking else { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            ambientSpeechInFlight = false
        }
        if OrbDuplexAudio.shared.isEchoCancelling {
            logger.info("[ORB_SESSION]\(self.tag) Skipping the \(String(format: "%.1f", Self.audioSettleDelay))s audio settle — speech and capture share one echo-cancelling engine, so there is no synthesiser teardown to outrun. CONSEQUENCE: the microphone opens immediately.")
            return
        }
        // Fully release the speech synthesizer's audio unit, then let CoreAudio settle, before
        // claiming the input device.
        voice.releaseAudio()
        // The narrator holds its own synthesizer for the length of an answer; BOTH audio units
        // must be gone before the HAL is asked for the input device.
        speaker.releaseAudio()
        let lastSpeech = [voice.lastAudioReleasedAt, speaker.lastAudioReleasedAt].compactMap { $0 }.max()
        let afterDeadSession = consecutiveDeadSessions > 0
        let delay = Self.settleDelay(bluetoothInput: MicrophoneSelection.shared.sessionInputIsBluetooth,
                                     secondsSinceSpeech: lastSpeech.map { Date().timeIntervalSince($0) },
                                     afterDeadSession: afterDeadSession)
        if delay > Self.audioSettleDelay {
            logger.info("[ORB_SESSION]\(self.tag) The microphone is Bluetooth and \(afterDeadSession ? "the last session opened deaf" : "Orb has just spoken") — waiting \(String(format: "%.1f", delay))s instead of \(String(format: "%.1f", Self.audioSettleDelay))s before opening it. CONSEQUENCE: the headset finishes switching from playback to its microphone first; opened sooner, the session starts deaf (-10877 / error 35).")
        }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
    /// Consecutive dead sessions before surfacing voiceUnavailable instead of retrying.
    private static let maxDeadSessions = 4
    /// How long an open session may deliver no audio before the orb says so.
    /// A healthy microphone produces samples within ~100ms even in a silent room, so quiet cannot trigger it.
    static let deadAudioWarningDelay: TimeInterval = 3.0

    // Why: WhisperKit passive sessions recycle on their own; `SpeechAnalyzer` does not, so a dead one would run forever.
    /// How long an Apple Speech session may deliver no audio before it is ended so the retry ladder can run.
    /// The signal is "the tap delivered zero buffers", not "nobody spoke", so it cannot cut short a thinking user.
    static let deadAudioSessionLimit: TimeInterval = 12.0

    /// What to do after a session that delivered no audio at all.
    enum DeadSessionOutcome: Equatable {
        case retry(backoff: TimeInterval)
        /// Stop pretending to listen and say so.
        case giveUp
    }

    // Why: both loops call this one function; a loop without the ladder re-arms forever on a dead input device.
    /// The escalation ladder for consecutive dead microphone sessions, shared by both recognizer loops.
    /// The backoff climbs so the HAL has longer to release a device another app is holding.
    static func deadSessionOutcome(consecutive: Int) -> DeadSessionOutcome {
        guard consecutive < maxDeadSessions else { return .giveUp }
        return .retry(backoff: Double(consecutive) * 0.8)
    }

    /// Spoken by the orb when the microphone opens but delivers nothing. Shared so both loops
    /// send the user to the same place.
    static let deadAudioUnavailableReason = String(localized:
        "The microphone opened but delivered no audio. Another app may be holding the input device — quit apps using the mic (or check your input device in System Settings → Sound), then retry.")

    // MARK: Observable state (drives the HUD)

    private(set) var stage: OrbStage = .selectingProfile
    private(set) var liveTranscript: String = ""
    private(set) var energyLevels: [Float] = []
    private(set) var profiles: [BackendProfileModel] = []
    private(set) var selectedProfile: BackendProfileModel?
    private(set) var currentAgentMessage: ChatMessage?
    /// The profile remembered from the last Orb session (pre-highlighted in the picker).
    private(set) var rememberedProfileID: UUID?
    /// True once a microphone session has opened but delivered no audio.
    /// Separate from `voiceUnavailable`: the first -10877 is often transient, so the loop keeps retrying while this warns.
    private(set) var micTroubleDetected = false
    /// True when the configured ASR language cannot produce a wake-word match, so clicking
    /// the orb is the ONLY way in. Drives the tooltip — without it the orb looks alive and
    /// simply never responds. See `wakeWordCanMatch(language:)`.
    private(set) var wakeWordUnavailable = false

    /// The command as it stands right now: everything spoken after the wake word, or —
    /// when capture was armed by clicking — everything spoken after the arm point.
    var commandPreview: String {
        Self.commandPreview(liveTranscript: liveTranscript, manualBaseline: manualCaptureBaseline)
    }

    /// The policy behind `commandPreview`. Pure.
    /// Leading wake words are stripped on both the wake-word and the tap path; the wake word is never part of the request.
    static func commandPreview(liveTranscript: String,
                               manualBaseline: String?,
                               wakeWord: String = OrbSessionController.wakeWord) -> String {
        if let manualBaseline {
            return strippingLeadingWakeWords(from: strippingPrefix(manualBaseline, from: liveTranscript),
                                             wakeWord: wakeWord)
        }
        return extractCommand(from: liveTranscript, wakeWord: wakeWord)
    }

    /// Normalized 0…1 audio level for the core visual.
    var audioLevel: CGFloat {
        guard let last = energyLevels.last else { return 0 }
        return CGFloat(min(1.0, max(0.0, last / 0.25)))
    }

    /// Pending HITL for the Orb conversation (agent profiles can park mid-run).
    var pendingInteraction: PendingHITL? {
        guard let convID = orbConversationID, let center = mainVM?.interactionCenter else { return nil }
        return center.current(for: convID)
    }

    var isExecuting: Bool { streamingMessageID != nil }

    var isVoiceUnavailable: Bool {
        if case .voiceUnavailable = stage { return true }
        return false
    }

    // MARK: Private state

    @ObservationIgnored private weak var mainVM: MainApplicationViewModel?

    /// The chat persistence store, injected so tests can exercise dispatch without writing the real SwiftData store.
    /// Defaults to `.shared` in production.
    @ObservationIgnored private let persistence: ChatPersistenceProtocol

    init(persistence: ChatPersistenceProtocol = ChatPersistenceStore.shared) {
        self.persistence = persistence
    }
    @ObservationIgnored private let backendConfiguration = BackendConfiguration()
    @ObservationIgnored private let voice = OrbVoiceOutput()
    /// Narrates the assistant's answer as it streams.
    @ObservationIgnored private let speaker = OrbStreamingSpeaker()
    // Why: held strongly here only: ActiveStreamManager keeps mirror delegates in weak boxes and silently drops dead ones.
    /// Announces main-window runs.
    @ObservationIgnored private var ambientWatcher: OrbAmbientRunWatcher?
    /// True while an unprompted announcement is playing. The listening loop's settle would
    /// otherwise deallocate its synthesizer mid-sentence.
    @ObservationIgnored private var ambientSpeechInFlight = false
    /// Tracked from the lock/unlock notifications, because a display wake arrives BEFORE
    /// authentication and cannot be treated as one.
    @ObservationIgnored private var screenLocked = false
    /// Hard bound on how long a session start waits for one. An announcement is a few seconds;
    /// this exists so a stuck synthesizer cannot stop the microphone from ever reopening.
    private static let ambientSpeechGrace: TimeInterval = 6
    // Why: the deadline is required: `.awaitingApproval` never closes on its own, so an armed window without one is an open mic.
    /// The operation a spoken "yes" would currently approve, and the deadline after which it expires.
    /// Holds the whole token, not just the id: `.describe` re-reads the tool and arguments for the read-back.
    @ObservationIgnored private var voiceApprovalToken: OrbApprovalPolicy.VoiceApproval?
    private var voiceApprovalOperationID: UUID? { voiceApprovalToken?.operationID }
    @ObservationIgnored private var voiceApprovalTask: Task<Void, Never>?
    @ObservationIgnored private let logger = DGLogger(category: "OrbSession")

    /// Correlation identity for every Orb log line: `s` identifies the panel presentation, `t` the turn within it.
    @ObservationIgnored private let sessionID = UUID().uuidString.prefix(4).lowercased()
    // Why: lines logged while listening, capturing or aborting must carry this turn's id, not the last dispatched turn's.
    /// Stamped when a capture begins, not when a send is decided.
    @ObservationIgnored private var turnID: String = "—"
    private var tag: String { "[s:\(sessionID) t:\(turnID)]" }

    /// The HITL request already announced, so a re-render of the queue does not re-speak it.
    @ObservationIgnored private var announcedInteractionID: UUID?

    /// Whether the OPEN microphone session was opened while Orb was speaking — a narration
    /// listener, which acts on a stop phrase and nothing else, and whose audio is never classified.
    @ObservationIgnored private var sessionOpenedDuringNarration = false

    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    /// Deadlock breaker for the two TTS-gated stages — see `speakWithWatchdog`.
    @ObservationIgnored private var speechWatchdogTask: Task<Void, Never>?
    /// When the current phrase started, and its length; detects a synthesizer that finishes instantly with no audio.
    @ObservationIgnored private var speechStartedAt = Date()
    @ObservationIgnored private var speechPhraseLength = 0
    /// The hand-back for the phrase currently being spoken. Nil-ing it out IS the
    /// exactly-once guarantee: whichever edge (didFinish or timeout) arrives first wins.
    @ObservationIgnored private var pendingSpeechCompletion: (() -> Void)?
    @ObservationIgnored private var isSessionActive = false
    @ObservationIgnored private var sessionStart = Date()
    @ObservationIgnored private var lastTranscriptChange = Date()
    @ObservationIgnored private var dismissed = false
    /// Sleep/lock observers — see `installSystemObservers()`.
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var distributedObservers: [NSObjectProtocol] = []
    /// True while the machine is asleep or the screen is locked.
    @ObservationIgnored private var systemSuspended = false
    /// True between the push-to-talk shortcut's key-down and key-up.
    @ObservationIgnored private var pushToTalkHeld = false
    /// When the open follow-up window closes. Nil outside `.followUpWindow`.
    @ObservationIgnored private var followUpDeadline: Date?
    /// A voice command recognised during capture, performed instead of being sent to the model.
    @ObservationIgnored private var pendingVoiceCommand: OrbVoiceCommand?

    @ObservationIgnored private var orbConversationID: UUID?
    /// How many voice turns this session has sent.
    /// Used by the log lines that report what a profile switch or a "new conversation" command discards.
    @ObservationIgnored private var spokenTurnCount: Int = 0
    @ObservationIgnored private var streamingMessageID: UUID?
    /// Dead-mic sessions in a row (see audioSettleDelay).
    @ObservationIgnored private var consecutiveDeadSessions = 0
    /// Whether the audio engine delivered any samples this session; the authoritative liveness signal.
    /// A failed `_StartIO` still lets WhisperKit's loop end normally, so duration alone cannot tell a dead mic from silence.
    @ObservationIgnored private var receivedAudio = false
    /// Incremented whenever the voice loop must stop; a running loop exits when its captured generation differs.
    /// Task cancellation does not propagate out of WhisperKit's realtime loop. See `stopListening()`.
    @ObservationIgnored private var listenGeneration = 0
    /// Transcript text already present when capture was armed by click. Whisper's
    /// `fullText` is cumulative per session, so the command is what arrives AFTER
    /// this prefix. nil means capture was armed by the wake word instead.
    @ObservationIgnored private var manualCaptureBaseline: String?
    /// Stability tracking on the NORMALIZED command (lowercased, punctuation
    /// stripped): Whisper's temperature-fallback re-decodes churn casing and
    /// punctuation on every pass, and raw-text comparison never settles.
    @ObservationIgnored private var lastNormalizedCommand = ""
    @ObservationIgnored private var lastCommandChange = Date()
    /// When command capture was armed (wake word or tap). The capture hard cap measures from here, not session start.
    /// A wake word late in a passive session must still get the full capture window.
    @ObservationIgnored private var captureArmedAt = Date()

    // MARK: Lifecycle

    /// Fired when the wake word is heard, so the panel can raise/recenter itself
    /// before the user starts speaking.
    @ObservationIgnored var onRequestAttention: (() -> Void)?

    func attach(mainVM: MainApplicationViewModel) {
        self.mainVM = mainVM
        // Registered here rather than at init: this is where `mainVM` — and therefore the stream
        // manager — first exists.
        let watcher = OrbAmbientRunWatcher { [weak self] phrase, reason in
            // Go through the arbiter, never `voice.speak` directly: an announcement mid-turn would orphan the in-flight
            // speech hand-back and park the orb.
            self?.speakAmbient(phrase, reason: reason)
        }
        watcher.correlationTag = tag
        ambientWatcher = watcher
        // Covers every panel-scoped audio type, not just the speakers, so device-test log lines carry the session id.
        OrbDuplexAudio.shared.correlationTag = tag
        voice.correlationTag = tag
        speaker.correlationTag = tag
        mainVM.activeStreamManager.addMirrorDelegate(watcher)
        logger.info("[ORB_SESSION]\(self.tag) Ambient run watcher registered (announcements \(OrbConfigManager.shared.ambientAnnouncements ? "on" : "off"), threshold \(Int(OrbConfigManager.shared.ambientThresholdSeconds))s).")
    }

    /// True when a chosen profile still resolves.
    /// Drives "ask once, then go straight to the orb": the picker is a first-run step only.
    var hasRememberedProfile: Bool { Self.rememberedProfile() != nil }

    private static func rememberedProfile() -> BackendProfileModel? {
        guard let id = OrbConfigManager.shared.profileID else { return nil }
        do {
            guard let profile = try BackendProfileStore.shared.fetchProfile(byId: id) else {
                staticLogger.info("[ORB_SESSION] Remembered profile \(id.uuidString.prefix(8)) no longer exists. CONSEQUENCE: the picker is shown instead of resuming — expected after deleting a profile.")
                return nil
            }
            guard profile.profileType == .bot || profile.profileType == .agent else {
                staticLogger.info("[ORB_SESSION] Remembered profile is a \(profile.profileType.rawValue), which Orb cannot drive. CONSEQUENCE: the picker is shown instead of resuming.")
                return nil
            }
            return profile
        } catch {
            staticLogger.error("[ORB_SESSION] Could not read the remembered profile: \(error.localizedDescription). CONSEQUENCE: the picker is shown as if none had ever been chosen, and the user's choice appears to have been forgotten.")
            return nil
        }
    }

    /// The static half of the type has no instance `logger`; without this the two failures above
    /// would have to stay silent, which is how they got missed.
    private static let staticLogger = DGLogger(category: "OrbSession")

    func begin() {
        // One log line answering "which build is this, and how is it configured?"; bump `featureMarker`
        // with any change a tester is asked to verify.
        let config = OrbConfigManager.shared
        logger.notice("[ORB_SESSION]\(self.tag) Orb \(Self.featureMarker) starting — activation: \(config.activationMode.rawValue), wakeWord: \"\(Self.wakeWord)\", recognizer: \(config.recognizer.rawValue), spokenResponses: \(config.spokenResponses.rawValue), followUp: \(config.followUp.rawValue), earcons: \(config.earcons.rawValue), approvals: \(config.toolApprovals.rawValue), duplexAudio: \(config.duplexAudioEnabled), endpointing: \(String(format: "%.1f", Self.commandSilenceCommit))s.")
        installSystemObservers()
        loadProfiles()
        // Remembered profile → skip the picker entirely and start listening.
        // A deleted/renamed-away profile falls back to the picker rather than failing later.
        if let remembered = Self.rememberedProfile() {
            logger.info("[ORB_SESSION]\(self.tag) Resuming with remembered profile \"\(remembered.displayName)\" — skipping the picker.")
            selectProfile(remembered)
        } else {
            setStage(.selectingProfile, "begin")
        }
    }

    // Why: conversation state must be cleared, or the new profile inherits the previous profile's turns as history.
    /// Config-bubble action: returns to the picker, stopping the voice loop and any run first.
    func requestProfileSwitch() {
        guard stage != .selectingProfile else { return }
        stopListening()
        // The picker can stay open indefinitely; holding the input device while nothing listens is needless.
        // `selectProfile` warms the engine again on the way out.
        OrbDuplexAudio.shared.releaseWhenIdle(reason: "profile picker open")
        if let id = streamingMessageID {
            mainVM?.activeStreamManager.cancelStream(for: id)
            streamingMessageID = nil
        }
        // Same order as `teardown()`: `voice.stop()` drops the synthesizer completion, so a stale greeting hand-back
        // would later fire and drag the user out of the picker.
        speechWatchdogTask?.cancel()
        speechWatchdogTask = nil
        pendingSpeechCompletion = nil
        voice.stop()
        speaker.cancel()
        // Release any HITL park on the outgoing conversation before abandoning it — the
        // full `teardown()` does this, and a switch that skipped it stranded the entry.
        if let convID = orbConversationID {
            Task { await ExecutionSuspensionService.shared.cancel(for: convID) }
        }
        logger.info("[ORB_SESSION]\(self.tag) Profile switch — discarding \(self.spokenTurnCount) turn(s) and starting a new conversation. CONSEQUENCE: the new profile starts with empty history and any autonomous grant on the old conversation is revoked.")
        if let convID = orbConversationID {
            Task { await SessionToolApprovals.shared.setAutonomous(false, conversationID: convID, origin: .orb) }
        }
        announcedInteractionID = nil
        spokenTurnCount = 0
        orbConversationID = nil
        currentAgentMessage = nil
        loadProfiles()
        setStage(.selectingProfile, "requestProfileSwitch")
    }

    // Why: cancelling `listenTask` is not enough: WhisperKit swallows the cancellation, so bump the generation.
    /// Tears down the voice loop without ending the whole session (profile switch).
    private func stopListening() {
        listenGeneration &+= 1
        watchdogTask?.cancel()
        watchdogTask = nil
        listenTask?.cancel()
        listenTask = nil
        if isSessionActive {
            Task { _ = await WhisperRecognitionService.shared.stopStreaming() }
            isSessionActive = false
        }
    }

    /// Full stop: called when the panel closes. Cancels any in-flight run so
    /// nothing keeps executing invisibly after the HUD is gone.
    func teardown() {
        dismissed = true
        removeSystemObservers()
        listenGeneration &+= 1
        watchdogTask?.cancel()
        watchdogTask = nil
        listenTask?.cancel()
        listenTask = nil
        // Drop the speech hand-back before stopping the synthesizer: `voice.stop()` cancels the
        // pending completion, so a live watchdog would otherwise fire into a torn-down session.
        speechWatchdogTask?.cancel()
        speechWatchdogTask = nil
        pendingSpeechCompletion = nil
        voice.stop()
        speaker.cancel()
        // Synchronous and outside the Task below: a live AVAudioEngine at process death wedges coreaudiod into an
        // app-wide dead microphone.
        disarmVoiceApproval(reason: "panel torn down")
        OrbDuplexAudio.shared.release(reason: "panel torn down")
        if let ambientWatcher {
            mainVM?.activeStreamManager.removeMirrorDelegate(ambientWatcher)
            self.ambientWatcher = nil
        }
        if isSessionActive {
            Task { _ = await WhisperRecognitionService.shared.stopStreaming() }
            isSessionActive = false
        }
        if let id = streamingMessageID {
            mainVM?.activeStreamManager.cancelStream(for: id)
            streamingMessageID = nil
        }
        if let convID = orbConversationID {
            Task {
                await ExecutionSuspensionService.shared.cancel(for: convID)
                // Revoke the blanket grant with the panel: it is in-memory but would otherwise outlive the orb closing,
                // and a mode the user cannot see must not keep approving tools.
                await SessionToolApprovals.shared.setAutonomous(false, conversationID: convID, origin: .orb)
            }
        }
        logger.info("[ORB_SESSION]\(self.tag) Panel torn down — voice loop stopped, run cancelled, autonomous grant revoked.")
    }

    // MARK: System power / lock

    // Why: the panel stays up across spaces; otherwise a locked screen leaves a Whisper decoder running on the mic.
    /// Releases the microphone while the machine is asleep or the screen is locked.
    private func installSystemObservers() {
        guard workspaceObservers.isEmpty, distributedObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        let pause: (Notification) -> Void = { [weak self] note in
            MainActor.assumeIsolated { self?.suspendForSystemEvent(note.name.rawValue) }
        }
        // Wake is not unlock: `didWake` and `screensDidWake` fire while the login window is still showing, so resuming
        // here would reopen the microphone there and defeat the lock-state observer.
        let wake: (Notification) -> Void = { [weak self] note in
            MainActor.assumeIsolated { self?.resumeIfUnlocked(note.name.rawValue) }
        }
        let unlock: (Notification) -> Void = { [weak self] note in
            MainActor.assumeIsolated { self?.screenLocked = false; self?.resumeAfterSystemEvent(note.name.rawValue) }
        }
        let lock: (Notification) -> Void = { [weak self] note in
            MainActor.assumeIsolated { self?.screenLocked = true; self?.suspendForSystemEvent(note.name.rawValue) }
        }

        workspaceObservers = [
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: pause),
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: pause),
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: wake),
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: wake),
        ]
        // Screen lock has no NSWorkspace equivalent; these are the documented distributed names.
        distributedObservers = [
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: lock),
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: unlock),
        ]
    }

    private func removeSystemObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { workspace.removeObserver(observer) }
        workspaceObservers.removeAll()
        let distributed = DistributedNotificationCenter.default()
        for observer in distributedObservers { distributed.removeObserver(observer) }
        distributedObservers.removeAll()
    }

    private func suspendForSystemEvent(_ event: String) {
        guard !dismissed, !systemSuspended else { return }
        systemSuspended = true
        // All four mic-holding stages: `.followUpWindow` and an armed `.awaitingApproval` also keep a session open.
        guard stage == .passiveListening || stage == .commandCapture
                || stage == .followUpWindow
                || (stage == .awaitingApproval && isVoiceApprovalArmed) else { return }
        logger.info("[ORB_SESSION]\(self.tag) Releasing the microphone for system event \(event). CONSEQUENCE: the wake word cannot fire until the system wakes — an in-flight run keeps executing, only listening stops.")
        // A capture armed before the machine slept is stale by definition — the user walked away.
        if stage == .commandCapture {
            manualCaptureBaseline = nil
            setStage(.passiveListening, "suspendForSystemEvent")
        }
        // Disarm before stopping: an armed approval window survives a screen lock, so a bystander could approve a tool.
        // Disarming also closes the session, so it must come first.
        if isVoiceApprovalArmed {
            logger.notice("[ORB_HITL]\(self.tag) Disarming the spoken approval for \(event) — the request stays on screen and must be answered there. CONSEQUENCE: nobody can approve it by speaking at a locked or sleeping Mac.")
            disarmVoiceApproval(reason: "system event: \(event)")
        }
        stopListening()
        // Non-optional: a panel-scoped engine surviving sleep would hold the device and its indicator while idle.
        OrbDuplexAudio.shared.release(reason: "system suspend")
    }

    /// A display or system wake. Resumes only if the screen is not locked; otherwise the microphone would reopen
    /// at the login window.
    private func resumeIfUnlocked(_ event: String) {
        guard !dismissed, systemSuspended else { return }
        guard !screenLocked else {
            logger.info("[ORB_SESSION]\(self.tag) Woke on \(event) but the screen is still locked — staying suspended. CONSEQUENCE: the microphone does not reopen until the screen is actually unlocked.")
            return
        }
        resumeAfterSystemEvent(event)
    }

    private func resumeAfterSystemEvent(_ event: String) {
        guard !dismissed, systemSuspended else { return }
        systemSuspended = false
        // Only resume a loop we actually paused: a stage that moved on (executing, announcing,
        // voiceUnavailable) owns its own transition back to listening.
        guard listenTask == nil, stage == .passiveListening else { return }
        logger.info("[ORB_SESSION]\(self.tag) Resuming voice input after \(event).")
        consecutiveDeadSessions = 0
        Task { [weak self] in
            await OrbDuplexAudio.shared.warm(reason: "system resume")
            guard let self, !self.dismissed, self.listenTask == nil, self.stage == .passiveListening else { return }
            self.startListeningLoop()
        }
    }

    // MARK: Profile selection

    func loadProfiles() {
        // `fetchSharedProfiles`, not `fetchProfiles`: workflow nodes own private bot/agent profiles that the type filter
        // below does not exclude, and selecting one would persist its id as the remembered Orb profile.
        let all: [BackendProfileModel]
        do {
            all = try BackendProfileStore.shared.fetchSharedProfiles()
        } catch {
            // A failed fetch is logged, not turned into `[]`: an empty picker looks like a user with no profiles.
            logger.error("[ORB_SESSION]\(self.tag) Could not load profiles: \(error.localizedDescription). CONSEQUENCE: the picker will be EMPTY and Orb cannot start a turn — this is a store failure, not an absence of profiles.")
            all = []
        }
        // Same restriction as QuickAccess: only chat-style profiles make sense here.
        profiles = all.filter { $0.profileType == .bot || $0.profileType == .agent }
        if let idString = TestHost.defaults.string(forKey: AppSettings.orbProfileIDKey) {
            rememberedProfileID = UUID(uuidString: idString)
        }
    }

    func selectProfile(_ profile: BackendProfileModel) {
        guard !dismissed else { return }
        selectedProfile = profile
        backendConfiguration.selectedProfileID = profile.id
        OrbConfigManager.shared.profileID = profile.id
        setStage(.welcoming, "selectProfile")
        // Order matters: voice processing is healthy only when its engine is the first audio client, so the engine is
        // warmed and awaited before Orb speaks.
        Task { [weak self] in
            guard let self else { return }
            await OrbDuplexAudio.shared.warm(reason: "panel open")
            guard !self.dismissed else { return }
            // Push-to-talk arms capture synchronously after `show()`, before this Task runs; without this guard the greeting
            // would speak over that capture and its hand-back would cancel the user's turn.
            guard !self.pushToTalkHeld else {
                self.logger.info("[ORB_SESSION]\(self.tag) Skipping the greeting — push-to-talk was pressed before it could start, so the microphone is already open. CONSEQUENCE: Orb does not say hello this time; speaking over the user's first words and then cancelling their capture is the alternative.")
                return
            }
            self.speakWithWatchdog(self.greetingLine) { [weak self] in
                guard let self, !self.dismissed else { return }
                self.setStage(.passiveListening, "selectProfile")
                self.startListeningLoop()
            }
        }
    }

    // MARK: Stage transitions

    /// The ONLY way `stage` changes. Every transition is logged with where it came from, so a
    /// session can be replayed from the log without the app in front of you.
    private func setStage(_ next: OrbStage, _ origin: String) {
        guard stage != next else { return }
        logger.info("[ORB_STAGE]\(self.tag) \(Self.name(of: self.stage)) → \(Self.name(of: next)) (\(origin))")
        let previous = stage
        stage = next
        if Self.releasesEngineOnEntry(to: next) { releaseEngineForOfflineStage(origin) }
        // Both edges of `.announcing` are handled here, the one place a new entry point cannot forget.
        // Exit first: it only closes.
        if previous == .announcing { closeNarrationListener(origin) }
        if next == .announcing { openNarrationListenerIfAdmissible(origin) }
    }

    /// Whether THIS narration may be listened over. See `listensDuringNarration`.
    private var narrationListenerAdmissible: Bool {
        Self.listensDuringNarration(
            echoCancelling: OrbDuplexAudio.shared.isEchoCancelling,
            recognizerIsAppleSpeech: OrbConfigManager.shared.recognizer.isAppleSpeech,
            announcingApproval: announcedInteractionID != nil)
    }

    /// Entry edge of `.announcing`: keep a microphone open for a spoken stop, when echo
    /// cancellation makes that safe. Without it the only interrupt is a click.
    private func openNarrationListenerIfAdmissible(_ origin: String) {
        guard !dismissed, narrationListenerAdmissible else { return }
        logger.info("[ORB_SESSION]\(self.tag) Listening for a spoken stop while Orb speaks (\(origin)) — echo cancellation is live. CONSEQUENCE: only a stop phrase is acted on; everything else heard during the answer is discarded.")
        // A session still open from before this narration holds a transcript unrelated to this answer.
        // End it; the loop then reopens as a narration listener.
        if isSessionActive, !sessionOpenedDuringNarration {
            Task { _ = await WhisperRecognitionService.shared.stopStreaming() }
        }
        startListeningLoop()   // a no-op when a loop is already running — it picks the stage up itself
    }

    // Why: the follow-up window dispatches any speech; end the session and clear the transcript so Orb's own voice is not sent.
    /// Exit edge of `.announcing`: the narration listener never outlives the narration.
    private func closeNarrationListener(_ origin: String) {
        guard sessionOpenedDuringNarration else { return }
        liveTranscript = ""
        lastNormalizedCommand = ""
        guard isSessionActive else { return }
        logger.info("[ORB_ASR]\(self.tag) Closing the narration listener (\(origin)). CONSEQUENCE: nothing it heard is carried into \(Self.name(of: self.stage)); a fresh session opens.")
        Task { _ = await WhisperRecognitionService.shared.stopStreaming() }
    }

    // Why: not in `.awaitingApproval`/`.executing`: the release hits a live narration queue and the re-warm is refused.
    /// Whether entering `stage` should hand the input device back. Pure.
    /// Only `.voiceUnavailable` does: nothing is narrating, and its one automatic exit, `retryVoice()`, awaits the re-warm.
    static func releasesEngineOnEntry(to stage: OrbStage) -> Bool {
        if case .voiceUnavailable = stage { return true }
        return false
    }

    // Why: never while speech is in flight: stopping the engine under the speaker's player node makes `player.play()` crash.
    /// Gives the input device back when voice input has been declared unavailable.
    /// Hooked on the stage funnel (`setStage`), so no `.voiceUnavailable` entry point can forget it.
    private func releaseEngineForOfflineStage(_ origin: String) {
        guard OrbDuplexAudio.shared.isWarm else { return }
        guard !voice.isSpeaking, !speaker.isSpeaking else {
            logger.info("[ORB_SESSION]\(self.tag) Voice went unavailable (\(origin)) but Orb is still speaking — keeping the audio engine. CONSEQUENCE: the input device stays held until the panel closes; stopping the engine under a live render would strand the hand-back and crash on the next sentence.")
            return
        }
        OrbDuplexAudio.shared.releaseWhenIdle(reason: "voice unavailable (\(origin))")
    }

    /// Short, log-friendly stage name. `String(describing:)` would inline the whole
    /// `voiceUnavailable` sentence and make every line unscannable.
    static func name(of stage: OrbStage) -> String {
        switch stage {
        case .selectingProfile: return "selectingProfile"
        case .welcoming:        return "welcoming"
        case .passiveListening: return "passiveListening"
        case .commandCapture:   return "commandCapture"
        case .followUpWindow:   return "followUpWindow"
        case .executing:        return "executing"
        case .awaitingApproval: return "awaitingApproval"
        case .announcing:       return "announcing"
        case .voiceUnavailable: return "voiceUnavailable"
        }
    }

    // MARK: Earcons

    // Why: `NSSound`, not a synthesizer: it holds no CoreAudio output context open, so it cannot re-arm the -10877 race.
    /// Plays a short system sound marking a turn boundary.
    /// A retired system sound name yields nil and simply no sound, never a failure.
    private func playEarcon(_ cue: OrbEarcon) {
        guard OrbConfigManager.shared.earcons.plays(cue) else { return }
        NSSound(named: cue.systemSoundName)?.play()
    }

    // MARK: Speech hand-back

    /// Speaks `phrase` and guarantees `then` runs exactly once.
    /// `AVSpeechSynthesizer`'s `didFinish` has no timeout or failure path, so a watchdog supplies the missing exit.
    private func speakWithWatchdog(_ phrase: String, then: @escaping () -> Void) {
        speechWatchdogTask?.cancel()
        speechStartedAt = Date()
        speechPhraseLength = phrase.count
        pendingSpeechCompletion = then
        voice.speak(phrase) { [weak self] in
            self?.drainSpeechCompletion(failureReason: nil)
        }
        speechWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.speechCompletionTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.drainSpeechCompletion(
                failureReason: "no didFinish within \(Int(Self.speechCompletionTimeout))s"
            )
        }
    }

    // Why: not `speakWithWatchdog`: a second call would orphan the single pending hand-back and park the orb.
    /// Speaks something nobody asked for, and refuses rather than interrupt.
    @discardableResult
    private func speakAmbient(_ phrase: String, reason: String) -> Bool {
        guard !dismissed else { return false }
        if pendingSpeechCompletion != nil || voice.isSpeaking || speaker.isSpeaking {
            logger.info("[ORB_SESSION]\(self.tag) Ambient announcement DROPPED (\(reason)) — Orb is already speaking. CONSEQUENCE: this one is never spoken; interrupting would orphan the in-flight turn's hand-back and park the orb.")
            return false
        }
        // Passive listening only: announcing over a capture or an approval would talk across the user. Not `.followUpWindow`,
        // where any transcript is a command and Orb could dispatch its own announcement back to the model.
        guard stage == .passiveListening else {
            logger.info("[ORB_SESSION]\(self.tag) Ambient announcement DROPPED (\(reason)) — stage is \(Self.name(of: self.stage)). CONSEQUENCE: this one is never spoken; the user is mid-turn.")
            return false
        }
        logger.notice("[ORB_SESSION]\(self.tag) Ambient announcement: \(reason).")
        ambientSpeechInFlight = true
        voice.speak(phrase) { [weak self] in
            self?.ambientSpeechInFlight = false
        }
        return true
    }

    /// Runs the pending speech hand-back exactly once, whichever edge arrives first.
    private func drainSpeechCompletion(failureReason: String?) {
        guard let completion = pendingSpeechCompletion else { return }
        pendingSpeechCompletion = nil
        speechWatchdogTask?.cancel()
        speechWatchdogTask = nil
        // A synthesizer with a dead audio unit calls didFinish immediately having played nothing. Real speech takes about
        // 60-80ms per character; finishing under 30ms/char (and a 0.25s floor for short phrases) means nothing played.
        let elapsed = Date().timeIntervalSince(speechStartedAt)
        let plausibleFloor = max(0.25, Double(speechPhraseLength) * 0.03)
        if failureReason == nil, speechPhraseLength > 8, elapsed < plausibleFloor {
            logger.error("[ORB_TTS]\(self.tag) Speech reported completion after only \(Int(elapsed * 1000))ms for a \(self.speechPhraseLength)-character phrase — it almost certainly produced NO AUDIO. CONSEQUENCE: Orb advances as if it had spoken, so the user hears nothing and the turn continues silently. On macOS this usually means a wedged coreaudiod (paired with `_StartIO error 35` on the microphone); `sudo killall coreaudiod` clears it.")
        }
        if let failureReason {
            logger.error("[ORB_TTS]\(self.tag) Speech completion never fired (\(failureReason)) — handing back anyway. CONSEQUENCE: without this the stage machine parks in \(String(describing: self.stage)) forever with the microphone closed, and only closing the panel recovers.")
        }
        guard !dismissed else { return }
        completion()
    }

    // MARK: Greeting

    static var greetingName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespaces)
        guard let first = full.split(separator: " ").first, !first.isEmpty else { return "there" }
        return String(first)
    }

    var greetingLine: String { String(localized: "Hello \(Self.greetingName)") }

    // MARK: Voice loop

    /// Offers to restart CoreAudio's daemon, then retries listening.
    /// The wedge survives quitting the app, so this is the only in-app remedy.
    func repairAudio() {
        // Release before the daemon restarts: restarting coreaudiod under a live engine is what creates the wedge.
        let wasWarm = OrbDuplexAudio.shared.isWarm
        OrbDuplexAudio.shared.release(reason: "audio repair")
        let outcome = OrbAudioRepair.run(logger: logger, tag: tag)
        guard outcome == .repaired else {
            // The alert and the administrator prompt are both declinable; the engine is restored here so a cancelled repair
            // does not silently cost echo cancellation on later turns.
            logger.info("[ORB_SESSION]\(self.tag) Audio repair was not performed. CONSEQUENCE: \(wasWarm ? "restoring the echo-cancelling engine that was released for it" : "nothing had been released, so there is nothing to restore").")
            if wasWarm {
                Task { [weak self] in
                    await OrbDuplexAudio.shared.warm(reason: "audio repair declined")
                    guard let self, !self.dismissed else { return }
                    self.startListeningLoop()
                }
            }
            return
        }
        micTroubleDetected = false
        consecutiveDeadSessions = 0
        if case .voiceUnavailable = stage {
            setStage(.passiveListening, "repairAudio")
        }
        stopListening()
        Task { [weak self] in
            await OrbDuplexAudio.shared.warm(reason: "after audio repair")
            guard let self, !self.dismissed else { return }
            self.startListeningLoop()
        }
    }

    /// Called when the activation mode changes while the panel is open.
    /// Switching from hold to continuous must register the loop itself; continuous to hold ends it on its next iteration.
    func activationModeChanged() {
        guard !dismissed else { return }
        let mode = OrbConfigManager.shared.activationMode
        logger.notice("[ORB_SESSION]\(self.tag) Activation mode changed to \(mode.rawValue) while the panel is open.")
        guard mode.listensContinuously else {
            // The loop's own guard closes the microphone on its next pass; nothing to start.
            logger.info("[ORB_SESSION]\(self.tag) Hold-to-talk selected — the running loop will close the microphone on its next pass. CONSEQUENCE: the shortcut is now the only way in.")
            return
        }
        guard stage == .passiveListening || stage == .followUpWindow else {
            logger.info("[ORB_SESSION]\(self.tag) Continuous mode selected mid-turn (stage \(Self.name(of: self.stage))). CONSEQUENCE: listening resumes when the turn returns to standby, not now.")
            return
        }
        startListeningLoop()
    }

    // Why: must close the microphone too, not just disarm: an armed `.awaitingApproval` keeps the mic open.
    /// Called when the user switches the spoken-approval channel off.
    func cancelVoiceApproval(reason: String) {
        guard isVoiceApprovalArmed else { return }
        disarmVoiceApproval(reason: reason)
        logger.notice("[ORB_HITL]\(self.tag) Spoken approval withdrawn mid-window (\(reason)). CONSEQUENCE: the microphone is closed and the request stays on screen to be answered there.")
    }

    /// Called when the Tool approvals picker changes while the orb is open.
    /// Re-applies the autonomous grant, which is otherwise set per dispatch and revoked only at teardown.
    func toolApprovalsChanged() {
        guard !dismissed, let convID = orbConversationID else { return }
        let autonomous = OrbConfigManager.shared.toolApprovals == .autonomous
        logger.notice("[ORB_HITL]\(self.tag) Tool approvals changed to \(OrbConfigManager.shared.toolApprovals.rawValue) mid-session — applying to the run in flight. CONSEQUENCE: \(autonomous ? "remaining tool calls in this conversation are auto-approved" : "the blanket grant is revoked NOW; the next tool call asks").")
        Task { await SessionToolApprovals.shared.setAutonomous(autonomous, conversationID: convID, origin: .orb) }
    }

    // Why: await the warm: a fire-and-forget Task loses the race with `startListeningLoop`, so echo cancellation is lost.
    /// Re-entry point from the voiceUnavailable stage.
    /// Awaits the engine re-warm before listening, as `selectProfile` does. Releasing in `.awaitingApproval` or
    /// `.executing` is unsafe; see `releasesEngineOnEntry(to:)`.
    func retryVoice() {
        guard !dismissed, listenTask == nil else { return }
        micTroubleDetected = false
        consecutiveDeadSessions = 0
        setStage(.passiveListening, "retryVoice")
        Task { [weak self] in
            await OrbDuplexAudio.shared.warm(reason: "retry after voice unavailable")
            guard let self, !self.dismissed, self.listenTask == nil,
                  self.stage == .passiveListening else { return }
            self.startListeningLoop()
        }
    }

    private func startListeningLoop() {
        guard listenTask == nil, !dismissed else { return }
        // Hold-to-talk keeps the microphone closed at rest: the loop runs only while the shortcut is held, so
        // `beginPushToTalk()` sets `.commandCapture` first. An armed `.awaitingApproval` needs it too, or approval is inert.
        guard OrbConfigManager.shared.activationMode.listensContinuously
                || stage == .commandCapture
                || stage == .followUpWindow
                || (stage == .awaitingApproval && isVoiceApprovalArmed) else {
            // Callers log "Resuming voice input…" just before this; returning silently would make the log claim listening
            // resumed while no microphone opened.
            logger.info("[ORB_SESSION]\(self.tag) Listening loop NOT started in \(Self.name(of: self.stage)) — hold-to-talk opens the microphone only while the shortcut is held. CONSEQUENCE: the orb is idle and no session is running; any line above claiming listening resumed refers to intent, not to an open microphone.")
            return
        }
        listenGeneration &+= 1
        let generation = listenGeneration
        listenTask = Task { @MainActor [weak self] in
            let command = await self?.runListeningSessions(generation: generation)
            // A superseded loop must not clear a NEWER loop's task handle, nor
            // execute a command the user has since navigated away from.
            guard let self, self.listenGeneration == generation else { return }
            self.listenTask = nil
            guard !self.dismissed else { return }
            if let voiceCommand = self.pendingVoiceCommand {
                self.pendingVoiceCommand = nil
                self.perform(voiceCommand)
                return
            }
            if let command, !command.isEmpty {
                await self.execute(command)
            }
        }
    }

    /// Runs bounded listening sessions back-to-back until a command is captured,
    /// voice becomes unavailable, or this loop is superseded/torn down.
    private func runListeningSessions(generation: Int) async -> String? {
        // Why: re-read each iteration: the Apple loop exits only on a dispatchable command, so switching back needs it.
        // Apple Speech runs an entirely separate loop, an early branch so the WhisperKit path is unaffected.
        if #available(macOS 26.0, *), OrbConfigManager.shared.recognizer.isAppleSpeech {
            // Apple Speech builds its own engine through the same builder and `AVAudioNode` allows one tap per bus, so the duplex
            // engine must release before this branch runs, including when the recognizer is switched mid-panel.
            OrbDuplexAudio.shared.release(reason: "Apple Speech recognizer selected")
            return await runAppleSpeechSessions(generation: generation)
        }
        let service = WhisperRecognitionService.shared
        while !dismissed, generation == listenGeneration {
            // Only the wake-word, capture and follow-up stages hold the mic open; `.awaitingApproval` is admitted only while a
            // voice-approval window is armed, since that stage has no closing edge of its own.
            guard stage == .passiveListening || stage == .commandCapture || stage == .followUpWindow
                    || (stage == .awaitingApproval && isVoiceApprovalArmed)
                    || (stage == .announcing && narrationListenerAdmissible)
            else { return nil }
            // Hold-to-talk must not drift into always-open listening: the stage can return to `.passiveListening` while this
            // loop runs (an expired follow-up window), which would silently keep the microphone open.
            if !OrbConfigManager.shared.activationMode.listensContinuously,
               stage != .commandCapture, stage != .followUpWindow {
                logger.info("[ORB_SESSION]\(self.tag) Closing the microphone — hold-to-talk has no idle listening.")
                return nil
            }
            guard case .loaded = service.loadingState else {
                setStage(.voiceUnavailable(reason: String(localized: "No speech model is loaded. Download a Whisper model from the composer's voice settings, then retry.")), "runListeningSessions")
                return nil
            }
            // The wake word is English orthography matched as a whole word. Another script can never match,
            // and the failure is silent: the orb looks alive and ignores the user.
            let canMatchWakeWord = OrbConfigManager.shared.activationMode != .wakeWord
                || Self.wakeWordCanMatch(language: service.currentLanguage)
            if wakeWordUnavailable != !canMatchWakeWord {
                wakeWordUnavailable = !canMatchWakeWord
                if !canMatchWakeWord {
                    logger.warning("[ORB_ASR]\(self.tag) Speech language \"\(service.currentLanguage ?? "auto")\" cannot produce a wake-word match. CONSEQUENCE: the wake word will never fire; clicking the orb is the only way to speak a command, and the tooltip now says so.")
                }
            }

            let granted = await AVAudioApplication.requestRecordPermission()
            guard !dismissed, generation == listenGeneration else { return nil }
            guard granted else {
                setStage(.voiceUnavailable(reason: String(localized: "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone.")), "runListeningSessions")
                return nil
            }

            await settleAudioBeforeCapture()
            guard !dismissed, generation == listenGeneration else { return nil }
            // Re-read the stage: the settle above can take a second, and a push-to-talk key may be released inside it,
            // which cannot stop a session that has not opened yet.
            guard stage == .passiveListening || stage == .commandCapture || stage == .followUpWindow
                    || (stage == .awaitingApproval && isVoiceApprovalArmed)
                    || (stage == .announcing && narrationListenerAdmissible) else {
                logger.info("[ORB_SESSION]\(self.tag) Abandoning the session before it opened — the stage moved to \(Self.name(of: self.stage)) while audio settled. CONSEQUENCE: the microphone is not opened.")
                return nil
            }

            liveTranscript = ""
            energyLevels = []
            manualCaptureBaseline = nil
            receivedAudio = false
            sessionOpenedDuringNarration = (stage == .announcing)
            lastNormalizedCommand = ""
            sessionStart = Date()
            lastTranscriptChange = Date()
            lastCommandChange = Date()
            // The follow-up window is measured from when the microphone is live, not from when the answer ended,
            // so the settle delay does not consume its first second.
            if stage == .followUpWindow, let seconds = OrbConfigManager.shared.followUp.seconds {
                followUpDeadline = Date().addingTimeInterval(seconds)
            }
            isSessionActive = true
            startWatchdog()
            logger.info("[ORB_ASR]\(self.tag) Mic session opening in \(Self.name(of: self.stage)) (mode: \(OrbConfigManager.shared.activationMode.rawValue), model: \(service.activeModelName), endpointing: \(String(format: "%.1f", Self.commandSilenceCommit))s).")

            do {
                // Blocks until VAD auto-stop, the watchdog's stopStreaming, or an external stop (model switch in Settings).
                // `.sessionBusy` (composer or QuickAccess already recording) lands in the catch below as `.voiceUnavailable`.
                try await service.startStreaming(owner: .orb) { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.handleTranscriptUpdate(state)
                    }
                }
            } catch {
                isSessionActive = false
                watchdogTask?.cancel()
                logger.error("[ORB_ASR]\(self.tag) Mic session failed to start: \(error.localizedDescription). CONSEQUENCE: voice input is now unavailable and the orb shows OFFLINE until the user retries — nothing spoken will be heard.")
                setStage(.voiceUnavailable(reason: String(localized: "The voice session failed to start. Check that a speech model is loaded, then retry.")), "runListeningSessions")
                return nil
            }

            isSessionActive = false
            watchdogTask?.cancel()

            // Report the outcome before the dismissed guard: a user who closes the panel because nothing seemed to happen
            // is the case the log is most needed for.
            let heard = liveTranscript
            logger.info("[ORB_ASR]\(self.tag) Mic session closed after \(String(format: "%.1f", Date().timeIntervalSince(self.sessionStart)))s in \(Self.name(of: self.stage)) — audio: \(self.receivedAudio ? "yes" : "NONE"), heard \(Self.wordCount(heard)) word(s), wake word matched: \(Self.wakeWordRange(in: heard) != nil).")
            logger.debug("[ORB_ASR]\(self.tag) Transcript: \"\(heard)\"")

            guard !dismissed, generation == listenGeneration else { return nil }

            // A narration listener's audio is never classified, and this sits before the dead-audio check on purpose: it closes
            // the instant the answer ends, often before its first buffer, and would raise a false NO AUDIO warning.
            if sessionOpenedDuringNarration {
                sessionOpenedDuringNarration = false
                logger.info("[ORB_ASR]\(self.tag) Narration listener closed (now \(Self.name(of: self.stage))) — its audio is discarded, never classified. CONSEQUENCE: whatever the next stage needs opens a FRESH session with an empty transcript.")
                continue
            }

            // No samples at all means the engine never really started, however long the session appeared to run.
            // Back off and retry, then give up with a real message rather than pretending to listen forever.
            let duration = Date().timeIntervalSince(sessionStart)
            if !receivedAudio {
                consecutiveDeadSessions += 1
                // Tell the user on the FIRST failure; keep retrying regardless.
                if !micTroubleDetected {
                    micTroubleDetected = true
                    logger.warning("[ORB_ASR]\(self.tag) Surfacing a microphone warning after the FIRST dead session while retries continue. CONSEQUENCE: the orb shows trouble instead of a healthy STANDBY, so a wedged audio system is visible in seconds rather than after \(Self.maxDeadSessions) attempts.")
                }
                logger.warning("[ORB_ASR]\(self.tag) Mic session delivered NO audio in \(String(format: "%.1f", duration))s (attempt \(self.consecutiveDeadSessions)/\(Self.maxDeadSessions)) — the audio engine almost certainly failed to start. CONSEQUENCE: the session LOOKED healthy but heard nothing; backing off and retrying, and surfacing OFFLINE after \(Self.maxDeadSessions) attempts.")
                switch Self.deadSessionOutcome(consecutive: consecutiveDeadSessions) {
                case .giveUp:
                    setStage(.voiceUnavailable(reason: Self.deadAudioUnavailableReason), "runListeningSessions")
                    return nil
                case .retry(let backoff):
                    // Escalating backoff gives the HAL time to release the device.
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    continue
                }
            }
            consecutiveDeadSessions = 0
            if micTroubleDetected {
                micTroubleDetected = false
                logger.notice("[ORB_ASR]\(self.tag) Microphone RECOVERED — audio is flowing again.")
            }

            // Checked before `.commandCapture`: inside an armed window the utterance is a decision about a parked tool,
            // never a new request, so forwarding it to the model would send "yes" as a prompt.
            if stage == .awaitingApproval, isVoiceApprovalArmed {
                let spoken = commandPreview
                logger.info("[ORB_ASR]\(self.tag) Approval window heard \(spoken.split(separator: " ").count) word(s).")
                // Silence is not an answer: a session that ended with nothing heard keeps the window listening until its own
                // 30 s expiry, on both recognizers.
                if spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    logger.info("[ORB_ASR]\(self.tag) Approval session ended with nothing heard. CONSEQUENCE: listening again — the window stays open until it expires.")
                    continue
                }
                handleVoiceApprovalUtterance(spoken)
                return nil
            }

            if stage == .commandCapture {
                // commandPreview honors whichever way capture was armed (wake word or click).
                let command = commandPreview
                switch Self.classifyCapture(command) {
                case .cancel:
                    // Audible: a spoken "stop" that produces no sound reads as "not heard".
                    playEarcon(.interrupted)
                    logger.info("[ORB_SESSION]\(self.tag) Capture ended on a spoken cancel (\(Self.wordCount(command)) word(s)) — discarding it. CONSEQUENCE: nothing is sent; the loop re-arms for the wake word.")
                    manualCaptureBaseline = nil
                    setStage(.passiveListening, "runListeningSessions")
                case .voiceCommand(let voiceCommand):
                    // A control phrase never reaches the model. Handled after the loop unwinds so
                    // the microphone session is fully closed before anything speaks.
                    logger.info("[ORB_SESSION]\(self.tag) Voice command recognised: \(String(describing: voiceCommand)).")
                    playEarcon(.captured)
                    pendingVoiceCommand = voiceCommand
                    return nil
                case .dispatch:
                    playEarcon(.captured)
                    return command
                case .belowFloor:
                    logger.warning("[ORB_ASR]\(self.tag) Discarded a \(Self.wordCount(command))-word capture below the \(Self.minimumCommandWords)-word dispatch floor. CONSEQUENCE: nothing is sent and capture re-arms — this is the guard against a Whisper silence-hallucination starting a tool-using run.")
                    setStage(.passiveListening, "runListeningSessions")
                case .nothingHeard:
                    logger.info("[ORB_ASR]\(self.tag) Capture armed but nothing was heard. CONSEQUENCE: nothing is sent; the loop re-arms for the wake word or shortcut.")
                    setStage(.passiveListening, "runListeningSessions")
                }
            }
            // Passive session ended (recycle / non-wake speech) — loop restarts it.
        }
        return nil
    }

    /// The Apple Speech listening loop.
    /// Simpler than the WhisperKit loop: `SpeechAnalyzer` reports finality explicitly, so there is no stability window,
    /// no 45s session recycle and no blocking call to unwind.
    @available(macOS 26.0, *)
    private func runAppleSpeechSessions(generation: Int) async -> String? {
        guard OrbSpeechRecognizer.isAvailable else {
            logger.error("[ORB_APPLE_ASR]\(self.tag) SpeechTranscriber is unavailable on this Mac. CONSEQUENCE: Orb cannot listen in Apple Speech mode — switch the recognizer back to WhisperKit in Developer settings.")
            setStage(.voiceUnavailable(reason: String(localized: "Apple's speech recognizer isn't available on this Mac. Switch the recognizer back to WhisperKit in Orb settings.")), "runAppleSpeechSessions")
            return nil
        }

        while !dismissed, generation == listenGeneration {
            // Escape hatch: re-read the recognizer every iteration. This loop returns only on a dispatchable command, so with
            // Apple Speech producing nothing usable it would re-arm forever and a switch back to WhisperKit would not apply.
            guard OrbConfigManager.shared.recognizer.isAppleSpeech else {
                // Checked at the TOP of an iteration, so no recognizer exists yet to stop — the
                // previous iteration already tore its own down.
                logger.notice("[ORB_APPLE_ASR]\(self.tag) Recognizer switched away from Apple Speech — leaving the Apple loop. CONSEQUENCE: the caller re-enters and the next session opens on WhisperKit.")
                return nil
            }
            // `.awaitingApproval` is admitted only while a voice-approval window is armed: the stage has no closing edge of its
            // own, so an unconditional guard would hold the microphone open in an empty room.
            guard stage == .passiveListening || stage == .commandCapture || stage == .followUpWindow
                    || (stage == .awaitingApproval && isVoiceApprovalArmed)
            else { return nil }
            if !OrbConfigManager.shared.activationMode.listensContinuously,
               stage != .commandCapture, stage != .followUpWindow {
                logger.info("[ORB_APPLE_ASR]\(self.tag) Closing the microphone — hold-to-talk has no idle listening.")
                return nil
            }

            let granted = await AVAudioApplication.requestRecordPermission()
            guard !dismissed, generation == listenGeneration else { return nil }
            guard granted else {
                setStage(.voiceUnavailable(reason: String(localized: "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone.")), "runAppleSpeechSessions")
                return nil
            }

            // The synthesizers can still hold CoreAudio output, so the settle handshake stays; a dead microphone is worse.
            await settleAudioBeforeCapture()
            guard !dismissed, generation == listenGeneration else { return nil }
            // Re-read the stage: the settle above can take a second, and a push-to-talk key may be released inside it,
            // which cannot stop a session that has not opened yet.
            guard stage == .passiveListening || stage == .commandCapture || stage == .followUpWindow
                    || (stage == .awaitingApproval && isVoiceApprovalArmed) else {
                logger.info("[ORB_SESSION]\(self.tag) Abandoning the session before it opened — the stage moved to \(Self.name(of: self.stage)) while audio settled. CONSEQUENCE: the microphone is not opened.")
                return nil
            }

            liveTranscript = ""
            energyLevels = []
            manualCaptureBaseline = nil
            receivedAudio = false
            lastCommandChange = Date()
            // Set here because every age-based check below measures from `sessionStart`.
            sessionStart = Date()
            if stage == .followUpWindow, let seconds = OrbConfigManager.shared.followUp.seconds {
                followUpDeadline = Date().addingTimeInterval(seconds)
            }

            let recognizer = OrbSpeechRecognizer()
            recognizer.correlationTag = tag
            let gate = OrbOneShot()
            do {
                try await recognizer.start(
                    voiceProcessing: OrbConfigManager.shared.duplexAudioEnabled,
                    onUpdate: { [weak self] state in
                        Task { @MainActor [weak self] in self?.handleTranscriptUpdate(state) }
                    },
                    onFinalized: { Task { @MainActor in gate.resolve("finalized") } }
                )
            } catch {
                logger.error("[ORB_APPLE_ASR]\(self.tag) Could not start: \(error.localizedDescription). CONSEQUENCE: voice input is unavailable this session; switch the recognizer back to WhisperKit if this persists.")
                setStage(.voiceUnavailable(reason: String(localized: "Apple's speech recognizer couldn't start. Switch back to WhisperKit in Orb settings, then retry.")), "runAppleSpeechSessions")
                return nil
            }
            logger.info("[ORB_APPLE_ASR]\(self.tag) Listening in \(Self.name(of: self.stage)) (duplex: \(OrbConfigManager.shared.duplexAudioEnabled)).")

            // The only timers needed are the capture hard cap and the follow-up window's expiry; the rest of the WhisperKit
            // watchdog compensates for missing finality, which this recognizer supplies.
            let bound = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }

                    // Dead-microphone net, keyed on the audio tap (see `OrbSpeechRecognizer.hasReceivedAudio`): no text is a quiet room too.
                    // It lives here because this loop has no passive recycle, so a wedged session never ends on its own.
                    if !self.receivedAudio, recognizer.hasReceivedAudio {
                        self.receivedAudio = true
                    }
                    let sessionAge = Date().timeIntervalSince(self.sessionStart)
                    if !self.receivedAudio {
                        if !self.micTroubleDetected, sessionAge > Self.deadAudioWarningDelay {
                            self.micTroubleDetected = true
                            self.logger.warning("[ORB_APPLE_ASR]\(self.tag) No audio after \(String(format: "%.1f", sessionAge))s of an OPEN Apple Speech session — the tap has delivered ZERO buffers, so the engine started but is not capturing. CONSEQUENCE: the orb now shows NO AUDIO and offers Repair Audio in its right-click menu; ending the session shortly so the retry ladder can run.")
                        }
                        if sessionAge > Self.deadAudioSessionLimit {
                            gate.resolve("noAudio")
                            return
                        }
                    }

                    if self.stage == .commandCapture,
                       Date().timeIntervalSince(self.captureArmedAt) > Self.captureHardCap {
                        gate.resolve("captureHardCap")
                        return
                    }
                    if self.stage == .followUpWindow, let deadline = self.followUpDeadline,
                       Date() >= deadline {
                        self.expireFollowUpWindow()
                        gate.resolve("followUpExpired")
                        return
                    }
                    if self.dismissed || generation != self.listenGeneration {
                        gate.resolve("superseded")
                        return
                    }
                }
            }

            let reason = await gate.wait()
            bound.cancel()
            // Pass the reason through so a superseded session is not reported as the
            // format-mismatch signature — that alarm only means anything for a session that ran.
            let finalText = await recognizer.stop(reason: reason)
            // Text proves audio even if the tap counter was never sampled; the tap proves it even
            // in a silent room. Either is enough. (`hasReceivedAudio` is latched across `stop()`.)
            if recognizer.hasReceivedAudio || !finalText.isEmpty { receivedAudio = true }
            liveTranscript = finalText
            logger.info("[ORB_APPLE_ASR]\(self.tag) Session ended (\(reason)) — audio: \(self.receivedAudio ? "yes" : "NONE"), heard \(Self.wordCount(finalText)) word(s).")
            logger.debug("[ORB_APPLE_ASR]\(self.tag) Transcript: \"\(finalText)\"")

            guard !dismissed, generation == listenGeneration else { return nil }

            // The same ladder as the WhisperKit loop: warn on the first dead session, retry with escalating backoff, then
            // surface OFFLINE, which also makes "Repair Audio…" reachable.
            if !receivedAudio {
                consecutiveDeadSessions += 1
                logger.warning("[ORB_APPLE_ASR]\(self.tag) Apple Speech session delivered NO audio in \(String(format: "%.1f", Date().timeIntervalSince(self.sessionStart)))s (attempt \(self.consecutiveDeadSessions)/\(Self.maxDeadSessions)). CONSEQUENCE: the session LOOKED healthy but heard nothing; backing off and retrying, and surfacing OFFLINE after \(Self.maxDeadSessions) attempts.")
                switch Self.deadSessionOutcome(consecutive: consecutiveDeadSessions) {
                case .giveUp:
                    setStage(.voiceUnavailable(reason: Self.deadAudioUnavailableReason), "runAppleSpeechSessions")
                    return nil
                case .retry(let backoff):
                    // Escalating backoff gives the HAL time to release the device.
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    continue
                }
            }
            consecutiveDeadSessions = 0
            if micTroubleDetected {
                micTroubleDetected = false
                logger.notice("[ORB_APPLE_ASR]\(self.tag) Microphone RECOVERED — the tap is delivering audio again.")
            }

            // Same rule as the WhisperKit path — omitting it here would make the feature
            // silently do nothing under Apple Speech.
            if stage == .awaitingApproval, isVoiceApprovalArmed {
                let spoken = commandPreview
                logger.info("[ORB_ASR]\(self.tag) Approval window heard \(spoken.split(separator: " ").count) word(s).")
                // Silence is not an answer: a session that ended with nothing heard keeps the window listening until its own
                // 30 s expiry, on both recognizers.
                if spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    logger.info("[ORB_ASR]\(self.tag) Approval session ended with nothing heard. CONSEQUENCE: listening again — the window stays open until it expires.")
                    continue
                }
                handleVoiceApprovalUtterance(spoken)
                return nil
            }

            if stage == .commandCapture {
                let command = commandPreview
                // The same classifier as the WhisperKit loop, so both loops handle cancel and stop identically.
                switch Self.classifyCapture(command) {
                case .cancel:
                    playEarcon(.interrupted)
                    logger.info("[ORB_APPLE_ASR]\(self.tag) Capture ended on a spoken cancel (\(Self.wordCount(command)) word(s)) — discarding it. CONSEQUENCE: nothing is sent; capture re-arms.")
                    manualCaptureBaseline = nil
                    setStage(.passiveListening, "runAppleSpeechSessions")
                case .voiceCommand(let voiceCommand):
                    playEarcon(.captured)
                    pendingVoiceCommand = voiceCommand
                    return nil
                case .dispatch:
                    playEarcon(.captured)
                    return command
                case .belowFloor:
                    logger.info("[ORB_APPLE_ASR]\(self.tag) Discarded a \(Self.wordCount(command))-word capture below the \(Self.minimumCommandWords)-word dispatch floor. CONSEQUENCE: nothing is sent; capture re-arms.")
                    setStage(.passiveListening, "runAppleSpeechSessions")
                case .nothingHeard:
                    logger.info("[ORB_APPLE_ASR]\(self.tag) Capture armed but nothing was heard. CONSEQUENCE: nothing is sent; capture re-arms.")
                    setStage(.passiveListening, "runAppleSpeechSessions")
                }
            }
        }
        return nil
    }

    /// Provides the session exits WhisperKit's VAD can't: command commit after
    /// silence, empty-capture reset, capture hard cap, and passive recycling.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.isSessionActive, !Task.isCancelled else { return }
                let age = Date().timeIntervalSince(self.sessionStart)

                // Detect a dead microphone during the session, not only after it returns: WhisperKit's loop can keep spinning after
                // a -10877 failure, and the watchdog is the only observer while a session is hung.
                if !self.receivedAudio, !self.micTroubleDetected, age > Self.deadAudioWarningDelay {
                    self.micTroubleDetected = true
                    self.logger.warning("[ORB_ASR]\(self.tag) No audio after \(String(format: "%.1f", age))s of an OPEN mic session — the engine started but is delivering nothing. CONSEQUENCE: the orb now shows NO AUDIO and offers Repair Audio in its right-click menu; \(self.sessionOpenedDuringNarration ? "this narration listener closes with the answer" : "the session is ended now and the microphone reopened").")
                }

                // Every `stopStreaming()` below names its cause, so a device log can answer why listening stopped.
                @MainActor func endSession(_ cause: String) async {
                    self.logger.info("[ORB_ASR]\(self.tag) Ending the mic session — \(cause). CONSEQUENCE: the session closes and its transcript is classified; the loop decides whether to reopen.")
                    _ = await WhisperRecognitionService.shared.stopStreaming()
                }

                // A dead session is ENDED, not waited out — the post-session check then counts it
                // and the retry ladder reopens the microphone (see `endsDeadSession`).
                if Self.endsDeadSession(receivedAudio: self.receivedAudio, sessionAge: age,
                                        narrationListener: self.sessionOpenedDuringNarration) {
                    await endSession("no audio after \(String(format: "%.1f", age))s — the microphone opened deaf, so it is reopened now")
                    return
                }

                switch self.stage {
                case .commandCapture:
                    // Judged on the normalized command timeline (see lastCommandChange) so punctuation and case churn from Whisper's
                    // re-decodes cannot reset the window. The hard cap runs on capture age, not session age.
                    let commandIdle = Date().timeIntervalSince(self.lastCommandChange)
                    let captureAge = Date().timeIntervalSince(self.captureArmedAt)
                    let hasCommand = !self.commandPreview.isEmpty
                    // While the push-to-talk key is held only the hard cap may end the capture,
                    // or a pause for breath would send half a sentence.
                    let silenceMayCommit = !self.pushToTalkHeld
                    if silenceMayCommit && hasCommand && commandIdle > Self.commandSilenceCommit {
                        await endSession("command stable for \(String(format: "%.1f", commandIdle))s")
                        return
                    }
                    if silenceMayCommit && !hasCommand && commandIdle > Self.emptyCaptureTimeout {
                        await endSession("nothing was said within \(String(format: "%.1f", Self.emptyCaptureTimeout))s of arming")
                        return
                    }
                    if captureAge > Self.captureHardCap {
                        await endSession("hard cap — capture ran \(String(format: "%.1f", captureAge))s")
                        return
                    }
                case .followUpWindow:
                    if let deadline = self.followUpDeadline, Date() >= deadline {
                        self.expireFollowUpWindow()
                        await endSession("follow-up window expired")
                        return
                    }
                    // The window still counts against the recycle budget: WhisperKit re-decodes
                    // its whole un-purged buffer, so an unbounded session degrades either way.
                    if age > Self.passiveRecycleInterval {
                        await endSession("recycling — the follow-up session reached \(Int(age))s")
                        return
                    }
                case .passiveListening:
                    if age > Self.passiveRecycleInterval {
                        await endSession("recycling — the passive session reached \(Int(age))s")
                        return
                    }
                case .awaitingApproval where self.isVoiceApprovalArmed:
                    // This case is required: `default: return` would exit on the first tick, so nothing would end the mic session
                    // and a one-word "approve" is only processed once the session closes.
                    let idle = Date().timeIntervalSince(self.lastCommandChange)
                    let hasWord = !self.commandPreview.isEmpty
                    if hasWord && idle > Self.commandSilenceCommit {
                        await endSession("approval answer stable for \(String(format: "%.1f", idle))s")
                        return
                    }
                    // No 8 s empty-capture end here: silence would end the session and the empty utterance would read as "not a
                    // confirmation". The window's own 30 s expiry (`readBackAndListen`) closes the microphone.
                case .announcing where self.sessionOpenedDuringNarration:
                    // Bounded like every other session: WhisperKit re-decodes its whole buffer,
                    // and "read the rest" can narrate for minutes.
                    if age > Self.passiveRecycleInterval {
                        await endSession("recycling — the narration listener reached \(Int(age))s")
                        return
                    }
                default:
                    return
                }
            }
        }
    }

    private func handleTranscriptUpdate(_ state: StreamingTranscriptionState) {
        // A narration listener acts on a stop phrase and nothing else. Once the narration has ended its updates are stale
        // and dropped, so nothing heard during the answer reaches a stage that dispatches. See `closeNarrationListener`.
        switch Self.narrationListenerAction(openedDuringNarration: sessionOpenedDuringNarration,
                                            stage: stage, transcript: state.fullText) {
        case .notANarrationListener:
            break
        case .dropStale:
            return
        case .keepListening:
            if !state.bufferEnergy.isEmpty { receivedAudio = true }
            liveTranscript = state.fullText
            return
        case .interrupt:
            if !state.bufferEnergy.isEmpty { receivedAudio = true }
            logger.debug("[ORB_ASR]\(self.tag) Stop phrase heard during narration in: \"\(state.fullText)\"")
            bargeIn(by: "voice")
            return
        }
        let text = state.fullText
        if text != liveTranscript {
            liveTranscript = text
            lastTranscriptChange = Date()
        }
        // Energy samples are proof the engine is actually delivering audio.
        if !state.bufferEnergy.isEmpty { receivedAudio = true }
        energyLevels = Array(state.bufferEnergy.suffix(Self.energyBarCount))

        // Command-stability timeline: only a change in the NORMALIZED command counts.
        let normalized = Self.normalizedForStability(commandPreview)
        if normalized != lastNormalizedCommand {
            lastNormalizedCommand = normalized
            lastCommandChange = Date()
        }

        // Inside the follow-up window ANY speech is the command — not needing the wake word
        // again is the entire point of the window.
        if stage == .followUpWindow, !Self.normalizedForStability(commandPreview).isEmpty {
            armFollowUpCapture()
        }

        // A spoken cancel aborts the capture rather than becoming the command; checked before the wake-word arm so it only
        // fires on an already-armed capture. Only multi-word cancels here: a partial "stop the server" is a bare "stop".
        if stage == .commandCapture, Self.isCancelPhrase(commandPreview) {
            cancelCapture()
            return
        }

        if stage == .passiveListening,
           OrbConfigManager.shared.activationMode == .wakeWord,
           Self.wakeWordRange(in: text) != nil {
            setStage(.commandCapture, "handleTranscriptUpdate")
            manualCaptureBaseline = nil
            lastTranscriptChange = Date()
            lastCommandChange = Date()
            captureArmedAt = Date()
            // [ORB_ASR] Raw speech stays on the unbuffered debug channel — see the
            // session-end log for why the level IS the privacy control here.
            beginTurn()
            logger.info("[ORB_ASR]\(self.tag) Wake word detected — arming command capture.")
            playEarcon(.listening)
            logger.debug("[ORB_ASR]\(self.tag) Wake word matched in: \"\(text)\"")
            // Surface the orb before the user starts speaking.
            onRequestAttention?()
        }
    }

    /// Case- and punctuation-insensitive form used for the stability window.
    /// Whisper's re-decodes reshuffle punctuation and casing; comparing this form keeps the silence-commit timer steady.
    static func normalizedForStability(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }

    // Why: keyed by the word so homophones cannot outlive a renamed wake word; entries are observed on device,
    // never guessed, since a guess widens the match.
    /// Mishearings to accept alongside a wake word, keyed by that word.
    /// Matching is deliberately generous: a false positive only arms a visible command capture.
    static let wakeWordHomophones: [String: [String]] = [
        OrbConfigManager.defaultWakeWord: ["orba", "orbs"]
    ]

    /// Spellings accepted for `wakeWord`: the word itself plus any observed mishearing of it.
    static func wakeWordVariants(for wakeWord: String = OrbSessionController.wakeWord) -> [String] {
        [wakeWord] + (wakeWordHomophones[wakeWord.lowercased()] ?? [])
    }

    /// `\b(?:orb|orba|orbs)\b` for the default word. Built per call: the wake word is settable,
    /// and a cached pattern is exactly how the old `static let` silently ignored the setting.
    static func wakeWordPattern(for wakeWord: String) -> String {
        let alternatives = wakeWordVariants(for: wakeWord)
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return "\\b(?:\(alternatives))\\b"
    }

    // Why: never a bare substring: a three-letter word fires inside "absorb" and "orbit" and leaves garbage prompts.
    /// Range of the first accepted wake-word variant in `text`, matched as a whole word, if any.
    static func wakeWordRange(in text: String,
                              wakeWord: String = OrbSessionController.wakeWord) -> Range<String.Index>? {
        text.range(of: wakeWordPattern(for: wakeWord), options: [.regularExpression, .caseInsensitive])
    }

    /// Everything after the FIRST wake-word occurrence, stripped of leading/trailing
    /// punctuation. Falls back to the whole transcript if the wake word was rewritten
    /// out of the final text (partial → confirmed drift).
    static func extractCommand(from transcriptText: String,
                               wakeWord: String = OrbSessionController.wakeWord) -> String {
        guard let range = wakeWordRange(in: transcriptText, wakeWord: wakeWord) else {
            return transcriptText.trimmingCharacters(in: commandStrippers)
        }
        let command = String(transcriptText[range.upperBound...]).trimmingCharacters(in: commandStrippers)
        return strippingLeadingWakeWords(from: command, wakeWord: wakeWord)
    }

    /// `command` with every leading wake word removed, trimmed of punctuation. Pure.
    /// Leading only: a later wake word is part of the request ("tell Orb about it") and survives; repeats are stripped.
    static func strippingLeadingWakeWords(from text: String,
                                          wakeWord: String = OrbSessionController.wakeWord) -> String {
        var command = text.trimmingCharacters(in: commandStrippers)
        while let leading = wakeWordRange(in: command, wakeWord: wakeWord),
              leading.lowerBound == command.startIndex {
            let stripped = String(command[leading.upperBound...]).trimmingCharacters(in: commandStrippers)
            if stripped == command { break }   // no progress — do not spin
            command = stripped
        }
        return command
    }

    private static let commandStrippers = CharacterSet(charactersIn: ",.!?:;–—-").union(.whitespacesAndNewlines)

    /// Text that arrived after `prefix` in a cumulative transcript. Falls back to the
    /// whole string when Whisper rewrote the earlier text (confirmed-segment drift).
    static func strippingPrefix(_ prefix: String, from text: String) -> String {
        guard !prefix.isEmpty, text.hasPrefix(prefix) else {
            return text.trimmingCharacters(in: commandStrippers)
        }
        return String(text.dropFirst(prefix.count)).trimmingCharacters(in: commandStrippers)
    }

    // Why: never as a suffix: "repeat the test that failed" is a real request; only a bare "repeat that" is a command.
    /// Phrases that control Orb rather than being sent to the model, matched on the whole normalized utterance.
    // "read me the answer" is a repeat phrase, not a separate command: `repeatLastAnswer` narrates the whole message,
    // whereas the report's answer row is a truncated preview.
    static let repeatPhrases = ["repeat that", "say that again", "repeat", "what did you say",
                                "read me the answer", "read the answer", "read that back"]
    static let newConversationPhrases = ["new conversation", "new chat", "start over", "forget everything"]
    static let tellMeMorePhrases = ["tell me more", "go on", "continue", "read the rest",
                                    "say the rest", "and then", "what else"]
    static let whatWentWrongPhrases = ["what went wrong", "what failed", "what broke",
                                       "why did that fail", "what was the problem"]
    static let whatDidYouChangePhrases = ["what did you change", "what changed", "what files did you change",
                                          "what did you edit", "show me what changed"]

    /// The control phrase in `command`, if the whole utterance is one. Pure.
    static func voiceCommand(in command: String) -> OrbVoiceCommand? {
        let normalized = normalizedForStability(command)
        guard !normalized.isEmpty else { return nil }
        if repeatPhrases.contains(normalized) { return .repeatAnswer }
        if newConversationPhrases.contains(normalized) { return .newConversation }
        if tellMeMorePhrases.contains(normalized) { return .tellMeMore }
        if whatWentWrongPhrases.contains(normalized) { return .whatWentWrong }
        if whatDidYouChangePhrases.contains(normalized) { return .whatDidYouChange }
        return nil
    }

    // Why: decorate only the override, never the persisted row; the length request follows the setting, since a
    // sentence cap can only truncate, not make the model concise.
    /// Appended to the query the model sees when the answer will be read aloud.
    /// Only the model's copy is decorated: the hint travels as `promptOverride`; the persisted message stays clean.
    static func spokenStyleHint(for mode: OrbSpokenResponses) -> String {
        let length: String
        switch mode {
        case .gist:
            length = "Answer in one or two sentences — just the essential point. The user can ask you to go on if they want more."
        case .automatic, .preferSpoken, .preferSilent:
            length = "Reply in short plain sentences, and keep it to about six sentences unless the user asks for detail — a spoken answer cannot be skimmed."
        }
        return """


        (This request was spoken aloud and the answer will be read back by a text-to-speech voice. \
        \(length) No markdown, no bullet lists, no headings, no tables. \
        If code is unavoidable, describe it in a sentence rather than printing it.)
        """
    }

    /// The query as the model should see it. Pure.
    static func decoratedQuery(for command: String, mode: OrbSpokenResponses) -> String {
        mode.speaksAnswer ? command + spokenStyleHint(for: mode) : command
    }

    // Why: persisted and send-path rows must be one message by ID: history stripping matches by ID, so a mismatch orphans it.
    /// The two halves of a voice turn: the persisted and displayed message, and the model-facing text when it differs.
    /// `promptOverride` is nil when the decoration is a no-op (`.preferSilent`).
    /// `fileProcessorService` is required by the shared factory but unused: a voice turn never has attachments.
    static func voiceTurn(
        command: String,
        conversationID: UUID,
        mode: OrbSpokenResponses,
        fileProcessorService: FileProcessorService
    ) async -> (userMessage: ChatMessage, promptOverride: String?) {
        let userMessage = await MessagingCoordinator.makeUserMessage(
            conversationID: conversationID,
            query: command,
            files: [],
            fileProcessorService: fileProcessorService
        )
        userMessage.messageSource = .orb   // attribute voice traffic — set BEFORE persisting
        let decorated = decoratedQuery(for: command, mode: mode)
        return (userMessage, decorated == command ? nil : decorated)
    }

    /// Words in `text`, whitespace-separated. Pure.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Whether a captured command is worth sending. Pure — see `minimumCommandWords`.
    static func isDispatchable(_ command: String) -> Bool {
        wordCount(command) >= minimumCommandWords
    }

    /// Whether the capture is a spoken cancel rather than a request. Pure.
    /// Compared on the normalized form so punctuation and casing churn from Whisper's
    /// temperature-fallback re-decodes cannot defeat the match.
    static func isCancelPhrase(_ command: String) -> Bool {
        let normalized = normalizedForStability(command)
        guard !normalized.isEmpty else { return false }
        return cancelPhrases.contains { normalized == $0 || normalized.hasSuffix(" " + $0) }
    }

    /// Whether the configured ASR language can ever produce a wake-word match. Pure.
    /// Variants are English orthography, so a non-Latin-script language can never match;
    /// callers fall back to click-to-speak instead of leaving the user no way in.
    static func wakeWordCanMatch(language: String?) -> Bool {
        guard let language, !language.isEmpty else { return true }   // unset ⇒ auto-detect
        return language.lowercased().hasPrefix("en")
    }

    /// The phrase spoken when a run ends. Pure.
    /// Branches on the outcome so failed and warned runs are not announced as success.
    static func announcement(for outcome: ExecutionOutcome?, reason: String?) -> String {
        switch outcome {
        case .completed:
            return completionPhrase
        case .completedWithWarnings:
            return String(localized: "I finished, but not cleanly. Check the chat window for details.")
        case .failed:
            if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(localized: "That didn't work. \(reason)")
            }
            // Offers a follow-up instead of fetching the trace: loading the run here would leave the orb silent in `.announcing`;
            // `what went wrong` does the work on request.
            return String(localized: "That didn't work. Ask me what went wrong, or check the chat window.")
        case .timedOut:
            return String(localized: "That ran out of time and was stopped. Check the chat window for what it got done.")
        case .cancelled:
            return String(localized: "Stopped.")
        case nil:
            // finalizeMessage stamps an outcome before onComplete fires, so nil means a path
            // that bypassed finalize entirely — report the uncertainty rather than success.
            return String(localized: "The run ended, but I couldn't tell how. Check the chat window.")
        }
    }

    /// What a push-to-talk key-down should do from a given stage. Pure, so the entry path can be
    /// pinned by a test — it had none, which is how the `.welcoming` hole below survived an audit.
    enum PushToTalkAdmission: Equatable {
        /// The stage is idle and ready; arm capture directly.
        case arm
        /// Startup speech is in flight and must be abandoned first — see `.welcoming` below.
        case cutGreetingAndArm
        /// Nothing to capture into. The string is spoken to the LOG, not the user.
        case refuse(String)
        /// Parked on a request whose spoken window has closed: the press re-opens that window (read-back, then a fresh 30 s
        /// to answer) instead of capturing a new command.
        case reopenVoiceApproval
    }

    // Why: admit `.welcoming`: the shortcut opens the panel and arms capture in one gesture, so a cold open always lands there.
    /// Decides what a push-to-talk press does in `stage`; a held key is an explicit "talk now" that outranks the greeting.
    /// `.welcoming` is admitted because a cold open sets it before this runs.
    /// `canReopenApproval`: the run is parked on a request answerable by voice and no window is armed.
    static func pushToTalkAdmission(stage: OrbStage, canReopenApproval: Bool = false) -> PushToTalkAdmission {
        if stage == .awaitingApproval, canReopenApproval { return .reopenVoiceApproval }
        switch stage {
        case .passiveListening, .commandCapture:
            return .arm
        case .welcoming:
            return .cutGreetingAndArm
        case .selectingProfile:
            // Nothing can be sent until a profile is chosen, so this press is genuinely inert.
            return .refuse("no profile has been chosen yet — pick one in the panel that just opened")
        case .followUpWindow:
            // Unreachable today: hold-to-talk never opens a follow-up window (`followUpSeconds`
            // returns nil for it), and the shortcut is only registered in hold-to-talk.
            return .arm
        case .executing, .announcing, .awaitingApproval:
            return .refuse("a turn is already in flight — wait for it to finish, or interrupt it from the orb")
        case .voiceUnavailable(let reason):
            return .refuse("voice input is unavailable: \(reason)")
        }
    }

    /// Push-to-talk key DOWN: opens the microphone for as long as the shortcut is held.
    /// The mic is closed at rest in this mode, so this both arms capture and starts the loop.
    func beginPushToTalk() {
        guard !dismissed, !pushToTalkHeld else { return }

        switch Self.pushToTalkAdmission(stage: stage, canReopenApproval: reopenableApprovalToken() != nil) {
        case .reopenVoiceApproval:
            // `pushToTalkHeld` stays false: the window runs on its own clock,
            // and the key-up must not treat this as a command capture.
            if let token = reopenableApprovalToken() { reopenVoiceApproval(token, via: "push-to-talk") }
            return
        case .refuse(let reason):
            // Never silent: a refused press is logged so a device log shows that the press happened.
            logger.info("[ORB_SESSION]\(self.tag) Push-to-talk pressed in \(Self.name(of: self.stage)) — \(reason). CONSEQUENCE: this press raises the orb but captures NOTHING; nothing spoken while it is held will be heard.")
            return
        case .cutGreetingAndArm:
            // Same order as `teardown()`: drop the hand-back before `voice.stop()`, or the 20 s watchdog fires into a moved-on turn.
            // On a cold open `pushToTalkHeld` must be set here: it is what stops `selectProfile`'s greeting Task.
            logger.info("[ORB_SESSION]\(self.tag) Push-to-talk pressed during startup — skipping the greeting and opening the microphone now. CONSEQUENCE: Orb does not say hello this turn; without this the entire first utterance was captured by nothing.")
            speechWatchdogTask?.cancel()
            speechWatchdogTask = nil
            pendingSpeechCompletion = nil
            voice.stop()
        case .arm:
            break
        }

        pushToTalkHeld = true
        manualCaptureBaseline = nil
        captureArmedAt = Date()
        lastCommandChange = Date()
        setStage(.commandCapture, "beginPushToTalk")
        beginTurn()
        logger.info("[ORB_SESSION]\(self.tag) Push-to-talk engaged — opening the microphone.")
        playEarcon(.listening)
        startListeningLoop()
        onRequestAttention?()
    }

    /// Push-to-talk key UP: commits whatever was heard.
    func endPushToTalk() {
        guard pushToTalkHeld else { return }
        pushToTalkHeld = false
        guard stage == .commandCapture else {
            // Also never silent: a release that commits nothing means the press was refused, so there is no capture to end.
            logger.info("[ORB_SESSION]\(self.tag) Push-to-talk released in \(Self.name(of: self.stage)) with no capture armed. CONSEQUENCE: nothing is sent — whatever was said while the key was held was never being recorded.")
            return
        }
        logger.info("[ORB_SESSION]\(self.tag) Push-to-talk released — committing \(Self.wordCount(self.commandPreview)) word(s).")
        if isSessionActive {
            Task { _ = await WhisperRecognitionService.shared.stopStreaming() }
        } else {
            // The session has not opened yet: `isSessionActive` is set only after the permission check and the settle, so
            // a release inside that window stops nothing and must abandon the capture instead.
            logger.info("[ORB_SESSION]\(self.tag) Released before the session opened — abandoning the capture rather than opening the microphone for a key that is no longer held. CONSEQUENCE: nothing is captured or sent; the orb returns to standby.")
            manualCaptureBaseline = nil
            setStage(.passiveListening, "endPushToTalk")
        }
    }

    /// Click-to-speak: arms command capture without the wake word, mid-session.
    /// The safety net for when Whisper never renders the wake word recognizably.
    func armManualCapture() {
        // `!dismissed`, as in `beginPushToTalk`: a view can outlive the teardown that closed its panel, and entering
        // `.voiceUnavailable` releases the app-scoped engine, which a dead controller must not do to a new panel's engine.
        guard !dismissed else { return }
        if let token = reopenableApprovalToken() {
            reopenVoiceApproval(token, via: "a click on the orb")
            return
        }
        guard stage == .passiveListening else { return }
        manualCaptureBaseline = liveTranscript
        setStage(.commandCapture, "armManualCapture")
        lastTranscriptChange = Date()
        lastCommandChange = Date()
        captureArmedAt = Date()
        beginTurn()
        logger.info("[ORB_SESSION]\(self.tag) Command capture armed by click.")
        playEarcon(.listening)
        onRequestAttention?()
        // The loop is not running at rest in hold-to-talk, so a click must start it. `startListeningLoop` is a no-op
        // when a loop is already live, so the wake-word mode is unaffected.
        startListeningLoop()
    }

    /// Discards an armed capture without sending it and returns to wake-word scanning.
    /// The session is ended too, so discarded speech cannot leak into the next command via the cumulative transcript.
    func cancelCapture() {
        guard !dismissed, stage == .commandCapture else { return }
        playEarcon(.interrupted)
        logger.info("[ORB_SESSION]\(self.tag) Capture cancelled by the user — discarding \(Self.wordCount(self.commandPreview)) word(s). CONSEQUENCE: nothing is sent; the loop re-arms for the wake word.")
        manualCaptureBaseline = nil
        setStage(.passiveListening, "cancelCapture")
        if isSessionActive {
            Task { _ = await WhisperRecognitionService.shared.stopStreaming() }
        }
    }

    /// Siri-style "I'm done talking" tap: ends the capture session immediately and
    /// commits whatever has been heard. The definitive exit when background noise
    /// keeps every automatic stability window from settling.
    func commitCaptureNow() {
        guard !dismissed, stage == .commandCapture, isSessionActive else { return }
        logger.info("[ORB_SESSION]\(self.tag) Capture committed by user tap — sending \(Self.wordCount(self.commandPreview)) word(s).")
        Task { _ = await WhisperRecognitionService.shared.stopStreaming() }
    }

    // MARK: Execution (the chat-interface send path, verbatim from QuickAccess)

    private func execute(_ command: String) async {
        guard let mainVM, !dismissed else { return }
        setStage(.executing, "execute")
        liveTranscript = command

        guard let config = backendConfiguration.getRequestConfig() else {
            // Selected profile was deleted mid-session — fall back to the picker.
            logger.error("[ORB_RUN]\(self.tag) Send ABORTED — the selected profile no longer resolves. CONSEQUENCE: the command the user just spoke is DISCARDED without being sent, and the orb falls back to the profile picker.")
            setStage(.selectingProfile, "execute")
            loadProfiles()
            return
        }

        // Already stamped by `beginTurn()` when the capture opened; a second stamp here would
        // split one turn across two ids.
        if turnID == "—" { beginTurn() }
        let convID = ensureConversation(titleFrom: command, profileID: config.profile.id)

        // Re-applied every turn, not only at conversation creation: the setting can change while the orb is open,
        // and a stale autonomous grant is invisible state.
        let approvals = OrbConfigManager.shared.toolApprovals
        logger.info("[ORB_RUN]\(self.tag) Dispatching \(Self.wordCount(command)) word(s) to \"\(config.profile.displayName)\" (approvals: \(approvals.rawValue), conv \(convID.uuidString.prefix(8))).")
        Task { await SessionToolApprovals.shared.setAutonomous(approvals.isAutonomous, conversationID: convID, origin: .orb) }
        observeInteractions()
        // Bind the profile so restart-resume, ChatOps, and the sidebar all resolve it.
        persistence.updateBackendForConversation(
            id: convID, backendEntityId: config.profile.id
        )

        // The orb stays wordless while the run plays out in the real chat interface behind the panel, through the
        // notification the QuickAccess handoff also posts, which MainApplicationView observes.
        NotificationCenter.default.post(
            name: GlobalConstants.openConversationNotification,
            object: nil,
            userInfo: ["conversationID": convID.uuidString]
        )

        // Both halves are built together so the persisted row and the model's copy cannot drift apart; see `voiceTurn`.
        // A voice turn carries no attachments.
        let turn = await Self.voiceTurn(
            command: command,
            conversationID: convID,
            mode: OrbConfigManager.shared.spokenResponses,
            fileProcessorService: FileProcessorService()
        )
        let userMessage = turn.userMessage
        await persistence.addMessage(userMessage, toConversation: convID)
        spokenTurnCount += 1
        guard !dismissed else { return }

        // Identity guard for the completion closure: onComplete fires on every termination, so a stale stream's late
        // completion must not clobber a newer one's state. Filled right after the call returns (streaming starts in a Task).
        var thisStreamID: UUID?
        // Workflow bookkeeping: always nil here since the profile picker filters to `.bot`/`.agent`, so a workflow cannot
        // be selected by voice. Kept for a uniform call shape across every `startMessageStream` site.
        let workflowTicket = WorkflowRunBootstrap.begin(
            config: config,
            conversationID: convID,
            userInput: command,
            registry: mainVM,
            origin: .orb
        )
        let agentMessage = mainVM.activeStreamManager.startMessageStream(
            withConfig: config,
            userMessage: userMessage,
            // The model sees a decorated query while the persisted user message stays the clean command; `promptOverride`
            // declares that divergence so history stripping does not treat the turn as an orphan.
            promptOverride: turn.promptOverride,
            files: [],
            workflowExecutionState: workflowTicket?.state,
            onComplete: { [weak self] in
                DispatchQueue.main.async {
                    // finalize BEFORE the identity guard — see the QuickAccess twin: a superseded
                    // stream must still freeze its own record.
                    workflowTicket?.finalize()
                    guard let self, self.streamingMessageID == thisStreamID else { return }
                    self.streamingMessageID = nil
                    self.handleRunFinished()
                }
            }
        )
        agentMessage.messageSource = .orb   // [Orb] attribute voice traffic
        thisStreamID = agentMessage.id
        streamingMessageID = agentMessage.id
        currentAgentMessage = agentMessage
        // Narrate as it streams. For `.agent` profiles the executor emits the whole answer as one content event, so this
        // degrades to speak-on-completion.
        speaker.correlationTag = tag
        // Both speech paths, or half the spoken lines in a session are unattributable.
        voice.correlationTag = tag
        speaker.begin(for: agentMessage)
    }

    private func handleRunFinished() {
        guard !dismissed else { return }
        let outcome = currentAgentMessage?.terminalOutcome
        // A user-stopped run skips the announcement entirely — they know they stopped it.
        if outcome == .cancelled {
            logger.info("[ORB_RUN]\(self.tag) Run cancelled by the user — resuming listening with no announcement.")
            setStage(.passiveListening, "handleRunFinished")
            startListeningLoop()
            return
        }
        logger.info("[ORB_RUN]\(self.tag) Run finished with outcome \(outcome?.rawValue ?? "nil").")
        setStage(.announcing, "handleRunFinished")

        let handBack: () -> Void = { [weak self] in self?.returnToListening() }

        // A failed or unknown-outcome run must NOT be narrated as if it had answered: stop any
        // partial narration and say what actually happened instead.
        guard outcome == .completed || outcome == .completedWithWarnings else {
            playEarcon(.failed)
            speaker.cancel()
            speakWithWatchdog(Self.announcement(for: outcome, reason: currentAgentMessage?.terminalReason),
                              then: handBack)
            return
        }

        // Let the narration play out. A warnings outcome gets the caveat APPENDED rather than
        // substituted, so the user hears both the answer and the warning.
        let closing = outcome == .completedWithWarnings
            ? Self.announcement(for: outcome, reason: nil)
            : nil
        let narrating = speaker.finish(for: currentAgentMessage, appending: closing, onDrained: handBack)
        if !narrating {
            // Nothing was speakable — spoken responses are off, the answer was empty, or it was
            // all code. Fall back to the phrase so the turn still ends audibly.
            speakWithWatchdog(Self.announcement(for: outcome, reason: nil), then: handBack)
        }
    }

    /// Where a turn ends: the follow-up window if the user enabled one, otherwise wake-word standby
    /// (or, in hold-to-talk, a closed microphone). The window spares re-uttering the wake word before every sentence.
    private func returnToListening() {
        guard !dismissed else { return }
        // Hold-to-talk gets no follow-up window: its promise is "keeps the microphone closed until you press it", which a
        // hot window after every answer would break on every turn.
        guard let seconds = Self.followUpSeconds(
            activationMode: OrbConfigManager.shared.activationMode,
            followUp: OrbConfigManager.shared.followUp
        ) else {
            if !OrbConfigManager.shared.activationMode.listensContinuously {
                logger.info("[ORB_SESSION]\(self.tag) No follow-up window in hold-to-talk — the microphone stays closed until the shortcut is pressed. CONSEQUENCE: a follow-up needs the shortcut again; this is what the activation setting promises.")
            }
            setStage(.passiveListening, "returnToListening")
            startListeningLoop()
            return
        }
        followUpDeadline = Date().addingTimeInterval(seconds)
        setStage(.followUpWindow, "returnToListening")
        logger.info("[ORB_SESSION]\(self.tag) Follow-up window open for \(Int(seconds))s — speech now needs no wake word.")
        playEarcon(.listening)
        startListeningLoop()
    }

    /// How long the follow-up window should stay open after an answer, or nil for none. Pure.
    /// Hold-to-talk always returns nil: its promise is a microphone that stays closed until pressed.
    static func followUpSeconds(activationMode: OrbActivationMode,
                                followUp: OrbFollowUp) -> TimeInterval? {
        guard activationMode.listensContinuously else { return nil }
        return followUp.seconds
    }

    /// The window closed with nothing said.
    private func expireFollowUpWindow() {
        guard stage == .followUpWindow else { return }
        followUpDeadline = nil
        setStage(.passiveListening, "expireFollowUpWindow")
        logger.info("[ORB_SESSION]\(self.tag) Follow-up window expired with no speech. CONSEQUENCE: the wake word is required again, and in hold-to-talk the microphone closes until the shortcut is pressed.")
    }

    /// Speech arrived inside the follow-up window — treat all of it as the command.
    private func armFollowUpCapture() {
        followUpDeadline = nil
        manualCaptureBaseline = nil
        setStage(.commandCapture, "armFollowUpCapture")
        captureArmedAt = Date()
        lastCommandChange = Date()
        beginTurn()
        logger.info("[ORB_SESSION]\(self.tag) Follow-up speech detected — capturing with no wake word.")
        onRequestAttention?()
    }

    /// Re-speaks the last answer. Reuses the streaming speaker so the segmentation, the code
    /// handling and the voice settings are identical to the original narration.
    private func repeatLastAnswer() {
        guard !dismissed else { return }
        let handBack: () -> Void = { [weak self] in self?.returnToListening() }
        guard let message = currentAgentMessage else {
            setStage(.announcing, "repeatLastAnswer")
            speakWithWatchdog(String(localized: "There's nothing to repeat yet."), then: handBack)
            return
        }
        setStage(.announcing, "repeatLastAnswer")
        speaker.begin(for: message)
        if !speaker.finish(for: message, appending: nil, onDrained: handBack) {
            speakWithWatchdog(String(localized: "There's nothing to repeat yet."), then: handBack)
        }
    }

    /// What the user asked about the run that just finished.
    private enum RunNarration {
        case problems
        case changes
    }

    // Why: every exit path must speak: the trace fetch is asynchronous, so a silent return strands `.announcing`.
    /// Answers a question about the last run, out loud.
    private func narrateRun(_ kind: RunNarration) {
        guard !dismissed else { return }
        let handBack: () -> Void = { [weak self] in self?.returnToListening() }

        guard let message = currentAgentMessage else {
            setStage(.announcing, "narrateRun")
            speakWithWatchdog(String(localized: "There's no run for me to look at yet."), then: handBack)
            return
        }

        // `.executing`, not `.announcing`, for the fetch: `handleRunFinished` refuses trace reads in `.announcing`, whose only
        // closing edge, `speakWithWatchdog`, cannot be armed yet. `.executing` also keeps the loop from opening a mic.
        setStage(.executing, "narrateRun")

        Task { @MainActor [weak self] in
            guard let self, !self.dismissed else { return }
            let sentence: String
            switch kind {
            case .problems:
                let projection = await OrbRunReportLoader.projection(for: message)
                sentence = OrbRunNarration.problemSentence(projection)
            case .changes:
                // No trace fetch: the file-level truth lives on the message timeline, not in the
                // report's tool rows. See the note on `OrbRunReportLoader.changes`.
                let (effects, writeToolNames) = OrbRunReportLoader.changes(in: message)
                sentence = OrbRunNarration.changeSentence(effects: effects, writeToolNames: writeToolNames)
            }
            // Barge-in must win: a click during the silent fetch must not be followed by the narration starting anyway.
            guard !self.dismissed, self.stage == .executing else {
                self.logger.info("[ORB_SESSION]\(self.tag) Run narration abandoned — the stage moved to \(Self.name(of: self.stage)) while the trace was loading (a barge-in or a new turn). CONSEQUENCE: nothing is spoken, which is what the interrupt asked for.")
                return
            }
            self.logger.info("[ORB_SESSION]\(self.tag) Run narration (\(String(describing: kind))): \(sentence.count) character(s) spoken.")
            self.setStage(.announcing, "narrateRun")
            self.speakWithWatchdog(sentence, then: handBack)
        }
    }

    // Why: every exit speaks: silence is indistinguishable from the command not being recognised.
    /// Speaks whatever a length setting held back from the last answer.
    private func speakRemainderOfLastAnswer() {
        guard !dismissed else { return }
        let handBack: () -> Void = { [weak self] in self?.returnToListening() }
        setStage(.announcing, "speakRemainderOfLastAnswer")

        guard let message = currentAgentMessage else {
            speakWithWatchdog(String(localized: "There's nothing to go on with yet."), then: handBack)
            return
        }
        if !speaker.speakRemainder(of: message, onDrained: handBack) {
            speakWithWatchdog(String(localized: "That was the whole answer."), then: handBack)
        }
    }

    /// Starts a new turn's correlation id.
    /// Called wherever a capture is armed (wake word, click, push-to-talk, follow-up); `execute()` reuses it and stamps none.
    private func beginTurn() {
        turnID = UUID().uuidString.prefix(4).lowercased()
    }

    /// Performs a recognised control phrase instead of sending it to the model.
    private func perform(_ command: OrbVoiceCommand) {
        switch command {
        case .repeatAnswer:
            repeatLastAnswer()
        case .whatWentWrong:
            narrateRun(.problems)
        case .whatDidYouChange:
            narrateRun(.changes)
        case .tellMeMore:
            speakRemainderOfLastAnswer()
        case .newConversation:
            logger.info("[ORB_SESSION]\(self.tag) Voice command: new conversation — discarding \(self.spokenTurnCount) turn(s).")
            speaker.cancel()
            if let convID = orbConversationID {
                Task {
                    await ExecutionSuspensionService.shared.cancel(for: convID)
                    await SessionToolApprovals.shared.setAutonomous(false, conversationID: convID, origin: .orb)
                }
            }
            announcedInteractionID = nil
            spokenTurnCount = 0
            orbConversationID = nil
            currentAgentMessage = nil
            setStage(.announcing, "perform")
            speakWithWatchdog(String(localized: "Starting fresh."), then: { [weak self] in self?.returnToListening() })
        }
    }

    /// Barge-in: stop the narration and go straight back to listening.
    /// Reached by a tap always, and by voice when echo cancellation is live (a narration listener hears a stop phrase).
    /// Without echo cancellation the mic stays closed while Orb speaks, so a click is the only way to cut an answer short.
    func bargeIn(by source: String = "tap") {
        guard !dismissed, stage == .announcing else { return }
        logger.info("[ORB_SESSION]\(self.tag) Narration interrupted by the user (\(source)). CONSEQUENCE: the rest of the answer is not spoken; it stays in the chat window.")
        playEarcon(.interrupted)
        speaker.cancel()
        voice.stop()
        pendingSpeechCompletion = nil
        speechWatchdogTask?.cancel()
        speechWatchdogTask = nil
        setStage(.passiveListening, "bargeIn")
        startListeningLoop()
    }

    /// Stop button during execution. onComplete still fires (outcome .cancelled)
    /// and routes back to passive listening without the completion announcement.
    func stopExecution() {
        guard !dismissed else { return }
        speaker.cancel()
        guard let id = streamingMessageID else { return }
        mainVM?.activeStreamManager.cancelStream(for: id)
        if let convID = orbConversationID {
            Task { await ExecutionSuspensionService.shared.cancel(for: convID) }
        }
    }

    /// Each overlay presentation gets a fresh conversation (inspectable from the
    /// sidebar afterwards), created lazily on the first command.
    private func ensureConversation(titleFrom command: String, profileID: UUID) -> UUID {
        if let existing = orbConversationID { return existing }
        let title = String(localized: "Orb — \(String(command.prefix(48)))")
        let conversation = Conversation(
            id: UUID(),
            timestamp: Date(),
            userDefinedTitle: title,
            backendEntityId: profileID
        )
        persistence.addConversation(from: conversation)
        orbConversationID = conversation.id
        return conversation.id
    }

    // MARK: HITL — surfacing a parked run

    // Why: a parked agent run never fires `onComplete`, so without this the orb shows THINKING forever.
    // Re-arm before handling: `withObservationTracking` is one-shot.
    /// Watches the shared HITL queue for a park on this conversation.
    private func observeInteractions() {
        guard let center = mainVM?.interactionCenter else {
            logger.error("[ORB_HITL]\(self.tag) No InteractionCenter on the view model — a parked run cannot be surfaced. CONSEQUENCE: an agent that asks for approval hangs the orb on THINKING with no way to answer from the panel.")
            return
        }
        withObservationTracking {
            _ = center.pending
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, !self.dismissed else { return }
                // Stop observing when no conversation is bound, before the re-arm: the tracking re-arms itself and outlives the
                // conversation. Safe to drop: `execute()` arms it again on every dispatch.
                guard self.orbConversationID != nil else {
                    self.logger.debug("[ORB_HITL]\(self.tag) Interaction queue changed with no Orb conversation bound — this is the state after \"new conversation\" or a profile switch. CONSEQUENCE: observation stops here and is re-armed by the next turn's dispatch; nothing is missed because no Orb run exists to park.")
                    return
                }
                self.observeInteractions()
                self.handleInteractionChange()
            }
        }
    }

    private func handleInteractionChange() {
        // Only the missing interaction centre is an error: a nil conversation is ordinary between turns and is filtered
        // before the re-arm above.
        guard let center = mainVM?.interactionCenter else {
            logger.error("[ORB_HITL]\(self.tag) Interaction change ignored — the interaction centre is unavailable. CONSEQUENCE: a parked run will NOT be surfaced on the orb; it shows THINKING until the panel is closed.")
            return
        }
        guard let convID = orbConversationID else {
            logger.debug("[ORB_HITL]\(self.tag) Interaction change ignored — no conversation is bound. CONSEQUENCE: none; there is no Orb run that could have parked.")
            return
        }
        guard let pending = center.current(for: convID) else {
            // Not just `.awaitingApproval`: the unrecognised-utterance path spends a second in `.announcing` before returning to
            // it, so a request answered on screen during that phrase must still clear `announcedInteractionID`.
            if stage == .awaitingApproval || (stage == .announcing && announcedInteractionID != nil) {
                logger.info("[ORB_HITL]\(self.tag) Request resolved — the run continues.")
                // The user may have clicked the banner while the spoken window was open;
                // a still-armed window would leave a "yes" pointing at a resolved operation.
                disarmVoiceApproval(reason: "request resolved elsewhere")
                announcedInteractionID = nil
                setStage(.executing, "HITL resolved")
            }
            return
        }
        // The arm must follow the queue, not only the queue going empty: if the armed operation resolves while another is
        // queued, a stale id with the mic open would let "approve" commit an already-answered operation.
        if let armed = voiceApprovalOperationID, armed != pending.id {
            logger.error("[ORB_HITL]\(self.tag) The armed approval (op \(armed.uuidString.prefix(8))) is no longer the pending request (now op \(pending.id.uuidString.prefix(8))). CONSEQUENCE: disarming — a spoken approval must never commit an operation the user is not being asked about.")
            disarmVoiceApproval(reason: "a different request became pending")
        }

        guard announcedInteractionID != pending.id else { return }
        announcedInteractionID = pending.id

        let toolSuffix = pending.kind.toolName.map { ", tool \($0)" } ?? ""
        logger.notice("[ORB_HITL]\(self.tag) Run parked on \(Self.kindName(of: pending.kind)) (op \(pending.id.uuidString.prefix(8))\(toolSuffix)). CONSEQUENCE: the run is stopped until answered; the orb now shows the request instead of THINKING.")
        setStage(.awaitingApproval, "run parked on HITL")
        playEarcon(.listening)
        // Say that approval is needed, never the arguments: the user must read what they approve. A spoken approval is
        // offered only if the channel is on and the policy gave a token; the hand-back is non-empty so the stage can close.
        let voiceToken = OrbConfigManager.shared.voiceApprovals
            ? OrbApprovalPolicy.token(for: pending)
            : nil

        // A second park cuts the first prompt off, which is correct since that request is already resolved;
        // log it so the half-sentence the user heard is explained.
        if pendingSpeechCompletion != nil || voice.isSpeaking {
            logger.info("[ORB_HITL]\(self.tag) A new request arrived while the previous approval prompt was still being spoken — cutting it off. CONSEQUENCE: the first phrase stops mid-sentence and its hand-back is dropped; it described a request that has already been resolved, and the prompt for the one now on screen follows immediately.")
        }
        speakWithWatchdog(Self.approvalPrompt(for: pending)) { [weak self] in
            guard let self, !self.dismissed else { return }
            guard let voiceToken else {
                self.logger.info("[ORB_HITL]\(self.tag) Approval prompt spoken — waiting on the user. CONSEQUENCE: the run stays parked and the microphone stays closed until the banner is answered.")
                return
            }
            self.beginVoiceApproval(voiceToken)
        }
    }

    var isVoiceApprovalArmed: Bool { voiceApprovalOperationID != nil }

    /// How long a spoken "yes" stays valid.
    /// Short on purpose: an open microphone can commit an action here, so it fits someone present and listening.
    private static let voiceApprovalWindow: TimeInterval = 30

    // Why: two-stage by construction: the prompt names the tool, only a second utterance commits,
    // so one misheard word cannot authorize something the user never heard.
    /// Reads back what would run, then opens a bounded window for a spoken confirmation.
    private func beginVoiceApproval(_ token: OrbApprovalPolicy.VoiceApproval) {
        voiceApprovalToken = token
        logger.notice("[ORB_HITL]\(self.tag) Voice approval ARMED for op \(token.operationID.uuidString.prefix(8)) (\(token.toolName)), \(Int(Self.voiceApprovalWindow))s window. CONSEQUENCE: a spoken confirmation can approve THIS operation until the window closes; nothing else.")
        readBackAndListen(token, repeated: false)
    }

    // Why: one routine for the first reading and a repeat, so the authorizing sentence is never worded two ways.
    /// Speaks the read-back and re-opens the window's microphone and its expiry.
    private func readBackAndListen(_ token: OrbApprovalPolicy.VoiceApproval, repeated: Bool) {
        voiceApprovalTask?.cancel()
        let keywords = OrbConfigManager.shared.resolvedApprovalKeywords
        speakWithWatchdog(Self.approvalReadBack(token: token, keywords: keywords)) { [weak self] in
            guard let self, !self.dismissed else { return }
            // Deferred to the speech hand-back: a repeat is requested from inside `runListeningSessions`, so `listenTask` is still
            // non-nil and `startListeningLoop` would no-op; the loop has unwound by the time the phrase finishes.
            self.startListeningLoop()
        }

        // The clock restarts with the reading. A user who just asked what the operation was should
        // get a full window to answer in, not the remainder of the one they spent asking.
        voiceApprovalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.voiceApprovalWindow * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isVoiceApprovalArmed else { return }
            self.disarmVoiceApproval(reason: repeated ? "window expired after a repeat" : "window expired")
            // No answer is not a denial: the request stays open on screen (HITL is unbounded). The orb stays in
            // `.awaitingApproval` (releasing the duplex engine there is unsafe) and a press or click re-opens the window.
            self.logger.notice("[ORB_HITL]\(self.tag) Voice window closed with no answer. CONSEQUENCE: nothing approved or denied; the request stays on screen, and push-to-talk or a click re-opens the spoken window.")
            self.setStage(.announcing, "voice approval window expired")
            self.speakWithWatchdog(String(localized: "No answer, so I'll leave that one on screen. Press to talk when you want to answer.")) { [weak self] in
                self?.setStage(.awaitingApproval, "voice approval window expired")
            }
        }
    }

    /// The spoken-approval token for the request on screen, when the window is closed and could be
    /// re-opened: voice approvals on, the run parked, and the policy able to describe the request.
    private func reopenableApprovalToken() -> OrbApprovalPolicy.VoiceApproval? {
        guard stage == .awaitingApproval, !isVoiceApprovalArmed, OrbConfigManager.shared.voiceApprovals,
              let convID = orbConversationID,
              let pending = mainVM?.interactionCenter.current(for: convID) else { return nil }
        return OrbApprovalPolicy.token(for: pending)
    }

    private func reopenVoiceApproval(_ token: OrbApprovalPolicy.VoiceApproval, via trigger: String) {
        logger.notice("[ORB_HITL]\(self.tag) Voice approval RE-OPENED by \(trigger) for op \(token.operationID.uuidString.prefix(8)). CONSEQUENCE: the request is read back again and a fresh \(Int(Self.voiceApprovalWindow))s window opens.")
        playEarcon(.listening)
        beginVoiceApproval(token)
    }

    // Why: names the user's configured keywords: hard-coding "say yes" would make the feature look like a failing mic.
    /// The sentence spoken before a voice approval can commit. Pure.
    static func approvalReadBack(token: OrbApprovalPolicy.VoiceApproval,
                                 keywords: (approve: [String], deny: [String], problems: [OrbApprovalKeywords.Problem])) -> String {
        let approveWord = keywords.approve.first ?? OrbApprovalKeywords.approveDefault
        let denyWord = keywords.deny.first ?? OrbApprovalKeywords.denyDefault
        return String(localized: "That's \(OrbApprovalPolicy.spokenToolName(token.toolName)), \(token.spokenArguments). Say \(approveWord) to go ahead, or \(denyWord) to skip it.")
    }

    // Why: disarming without stopping leaves a live decoder nothing can end: no watchdog case, and VAD needs confirmed text.
    /// Disarms the spoken-approval window; every exit from it goes through here.
    /// Always closes the microphone: the armed window is the only reason `.awaitingApproval` holds a session open.
    private func disarmVoiceApproval(reason: String) {
        guard voiceApprovalToken != nil else { return }
        voiceApprovalToken = nil
        voiceApprovalTask?.cancel()
        voiceApprovalTask = nil
        logger.info("[ORB_HITL]\(self.tag) Voice approval DISARMED (\(reason)) — closing the microphone it opened. CONSEQUENCE: a spoken keyword no longer approves anything; the request stays on screen unless it was answered.")
        stopListening()
    }

    // Why: fails closed: only an explicit cancel phrase denies; a misheard denial would cancel wanted work, which is no safer.
    /// Handles what the user said inside an armed approval window.
    private func handleVoiceApprovalUtterance(_ spoken: String) {
        guard let operationID = voiceApprovalOperationID else {
            logger.info("[ORB_HITL]\(self.tag) Heard \(spoken.split(separator: " ").count) word(s) just after the approval window closed. CONSEQUENCE: they were discarded — nothing was approved or denied, and the request is still on screen.")
            return
        }
        let keywords = OrbConfigManager.shared.resolvedApprovalKeywords

        // Denial is checked first: if a word reaches both lists, the safe reading of an ambiguous instruction is "don't"
        // (`resolve` also strips collisions from the approve list).
        if OrbApprovalPolicy.isDenial(spoken, keywords: keywords.deny) || Self.isCancelPhrase(spoken) {
            disarmVoiceApproval(reason: "spoken denial")
            submitHITL("Voice DENIED", operationID: operationID,
                       consequence: "the tool does not run and the agent is told the user refused.") {
                $0.submitToolApproval(operationID: operationID, approved: false)
            }
            setStage(.executing, "voice approval denied")
            return
        }

        // The grammar for a queue of exactly one: `queueSize: 1` is deliberate, and `ordinals` drops out-of-range positions
        // so "approve three" parses to nothing. The bare keyword still commits through `isConfirmation` below.
        switch OrbApprovalPolicy.parseApprovalUtterance(
            spoken, queueSize: 1,
            approveKeywords: keywords.approve, denyKeywords: keywords.deny
        ) {
        case .denyAll, .deny:
            disarmVoiceApproval(reason: "spoken denial")
            submitHITL("Voice DENIED by a targeted phrase", operationID: operationID,
                       consequence: "the tool does not run and the agent is told the user refused.") {
                $0.submitToolApproval(operationID: operationID, approved: false)
            }
            setStage(.executing, "voice approval denied")
            return

        case .openOnScreen:
            // Asking to see it authorizes NOTHING — it moves the decision to the surface that can
            // show arguments and let the user edit them, which is the better outcome anyway.
            disarmVoiceApproval(reason: "user asked to see it on screen")
            logger.notice("[ORB_HITL]\(self.tag) Voice asked to see op \(operationID.uuidString.prefix(8)) on screen. CONSEQUENCE: nothing is approved or denied; the request stays pending and the main window is raised.")
            openInMainWindow()
            return

        case .describe:
            // Re-reads and stays armed: the one branch that must not fail closed, since a user who missed the arguments
            // is the one least able to decide, and disarming would answer "what was that?" by closing the channel.
            guard let token = voiceApprovalToken else { return }
            logger.notice("[ORB_HITL]\(self.tag) Re-reading op \(operationID.uuidString.prefix(8)) on request. CONSEQUENCE: nothing is approved or denied; the same read-back is spoken again and the window restarts.")
            readBackAndListen(token, repeated: true)
            return

        case .approve(let positions):
            // Defensive: `ordinals` cannot return anything but [1] for a queue of one, but this is
            // the one path that runs a tool, so it asserts rather than assumes.
            guard positions == [1] else {
                logger.error("[ORB_HITL]\(self.tag) Spoken approval named position(s) \(positions) with ONE request pending. CONSEQUENCE: NOTHING is approved — a target that does not resolve to the pending request must never commit it.")
                disarmVoiceApproval(reason: "approval named an unresolvable position")
                setStage(.executing, "voice approval unresolvable")
                return
            }
            approveByVoice(operationID: operationID)
            return

        case .none:
            break   // fall through to the bare commit word
        }

        guard OrbApprovalPolicy.isConfirmation(spoken, keywords: keywords.approve) else {
            // No re-ask. A second attempt at the same commit is a second chance to mishear.
            disarmVoiceApproval(reason: "utterance was not a confirmation")
            logger.notice("[ORB_HITL]\(self.tag) Heard \(spoken.count) character(s) that were not a confirmation. CONSEQUENCE: NOTHING was approved or denied — the request stays on screen for the user to answer there.")
            setStage(.announcing, "voice approval unrecognised")
            speakWithWatchdog(String(localized: "I'll leave that one on screen.")) { [weak self] in
                self?.setStage(.awaitingApproval, "voice approval unrecognised")
            }
            return
        }

        approveByVoice(operationID: operationID)
    }

    // Why: resolve one-shot via `submitToolApproval`, never `SessionToolApprovals.allow`: a misheard word must not grant durably.
    /// Approves the armed operation by voice; the only path from speech to an approval.
    /// Reachable only from `handleVoiceApprovalUtterance`, i.e. an armed window with a policy token. Do not add callers.
    private func approveByVoice(operationID: UUID) {
        disarmVoiceApproval(reason: "approved by voice")
        submitHITL("Voice APPROVED — one-shot, no durable grant", operationID: operationID,
                   consequence: "this single call runs; the next request for the same tool asks again.") {
            $0.submitToolApproval(operationID: operationID, approved: true)
        }
        playEarcon(.captured)
        setStage(.executing, "voice approval granted")
    }

    /// What Orb says when a run parks. Pure.
    static func approvalPrompt(for pending: PendingHITL) -> String {
        switch pending.kind {
        case .toolConfirmation(let confirmation):
            return String(localized: "I need your approval to run \(spokenToolName(confirmation.toolName)). It's on screen.")
        case .clarification:
            return String(localized: "I have a question for you. It's on screen.")
        case .planReview:
            return String(localized: "There's a plan for you to review. It's on screen.")
        case .gate:
            return String(localized: "I need you to choose how to continue. It's on screen.")
        }
    }

    /// `spotlight_search` reads as "spotlight search", not "spotlight underscore search".
    static func spokenToolName(_ toolName: String) -> String {
        toolName.replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespaces)
    }

    /// Log-friendly interaction kind. Pure.
    static func kindName(of kind: PendingInteraction) -> String {
        switch kind {
        case .toolConfirmation: return "toolConfirmation"
        case .clarification:    return "clarification"
        case .planReview:       return "planReview"
        case .gate:             return "gate"
        }
    }

    /// Raises the main window so the user can read and edit arguments. Guarded on the return
    /// value: the main window can be closed while the app runs from the shortcut, and a handoff
    /// into nothing is worse than no handoff.
    func openInMainWindow() {
        guard let convID = orbConversationID else { return }
        NotificationCenter.default.post(
            name: GlobalConstants.openConversationNotification,
            object: nil,
            userInfo: ["conversationID": convID.uuidString]
        )
        if AppDelegate.shared?.activateMainWindow() == true {
            logger.info("[ORB_HITL]\(self.tag) Handed off to the main window.")
        } else {
            logger.warning("[ORB_HITL]\(self.tag) No main window to hand off to. CONSEQUENCE: the request stays answerable only from the orb — the app is running from the shortcut or status item with its window closed.")
        }
    }

    // MARK: HITL passthrough (audit-logged wrappers, keyed purely by operationID)

    // Why: every decision routes through here so the log never claims a result that did not occur.
    /// Routes a HITL decision to the view model, or logs that it went nowhere.
    /// The outcome line is emitted only once the submission is actually going out (the view-model reference may be nil).
    private func submitHITL(_ decision: String, operationID: UUID, consequence: String,
                            _ submit: (MainApplicationViewModel) -> Void) {
        guard let mainVM else {
            logger.error("[ORB_HITL]\(self.tag) \(decision) for op \(operationID.uuidString.prefix(8)) went NOWHERE — the controller outlived its MainApplicationViewModel. CONSEQUENCE: the user's decision was DISCARDED, the run stays parked forever waiting on an answer that will never arrive, and the orb keeps presenting it as answerable. conversationID: \(self.orbConversationID?.uuidString.prefix(8) ?? "none")")
            return
        }
        logger.notice("[ORB_HITL]\(self.tag) \(decision) op \(operationID.uuidString.prefix(8)). CONSEQUENCE: \(consequence)")
        submit(mainVM)
    }

    func approveTool(_ pending: PendingHITL) {
        submitHITL("APPROVED from the orb\(pending.kind.toolName.map { " (tool \($0))" } ?? "")",
                   operationID: pending.id,
                   consequence: "the tool runs once; this is a one-shot resolution and grants nothing durable.") {
            $0.submitToolApproval(operationID: pending.id, approved: true)
        }
    }

    func denyTool(_ pending: PendingHITL) {
        submitHITL("DENIED from the orb\(pending.kind.toolName.map { " (tool \($0))" } ?? "")",
                   operationID: pending.id,
                   consequence: "the tool does not run and the agent is told the user refused.") {
            $0.submitToolApproval(operationID: pending.id, approved: false)
        }
    }

    func submitClarification(_ pending: PendingHITL, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Length only: the answer is free text the user typed and re-enters the agent's context.
        submitHITL("Answered clarification from the orb with \(trimmed.count) character(s)\(trimmed.isEmpty ? " (empty — treated as no answer)" : "")",
                   operationID: pending.id,
                   consequence: "the run resumes with this text in context.") {
            $0.submitClarificationResponse(operationID: pending.id, response: trimmed.isEmpty ? nil : trimmed)
        }
    }

    func resolvePlan(_ pending: PendingHITL, approved: Bool) {
        guard case .planReview(let plan) = pending.kind else {
            // Logged rather than dropped: the pending item can be replaced between the render and the tap,
            // which otherwise reads as a dead button.
            logger.error("[ORB_HITL]\(self.tag) Plan decision for op \(pending.id.uuidString.prefix(8)) IGNORED — the pending item is now a \(Self.kindName(of: pending.kind)), not a plan review. CONSEQUENCE: the click did nothing and the run stays parked; the request on screen has changed underneath the user.")
            return
        }
        submitHITL("Plan \(approved ? "APPROVED" : "REJECTED") from the orb (\(plan.subtasks.count) subtask(s))",
                   operationID: pending.id,
                   consequence: approved ? "the run proceeds with this plan." : "the run is told the plan was rejected.") {
            $0.submitPlanReview(operationID: pending.id, editedPlan: approved ? plan.subtasks : nil)
        }
    }

    func chooseGate(_ pending: PendingHITL, option: String) {
        submitHITL("Gate answered from the orb (option '\(option)')",
                   operationID: pending.id,
                   consequence: "the workflow continues down the chosen output port.") {
            $0.submitGateChoice(operationID: pending.id, option: option)
        }
    }
}

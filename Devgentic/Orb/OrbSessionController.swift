// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbSessionController.swift
//  Devgentic
//
//  [Orb MVP] The brain of the voice HUD: stage machine, wake-word listening loop,
//  and the send pipeline. Sends ride the EXACT same path as a chat-interface send —
//  the QuickAccess panel's blueprint (voiceTurn → persistence.addMessage →
//  ActiveStreamManager.startMessageStream with a per-call BackendRequestConfig) —
//  so an Orb run is indistinguishable from a typed chat turn downstream. (The first step read
//  `createUserMessage` until 2026-09-06; Orb no longer reaches that method at all.)
//
//  Voice-loop design constraints (from WhisperRecognitionService's semantics):
//  - `startStreaming` BLOCKS the calling task until the session ends; the await
//    returning is the only end-of-session signal. The loop is therefore
//    `while active { try await startStreaming { ... } ; <decide> }`.
//  - VAD auto-stop only arms once WhisperKit has CONFIRMED segments (needs >2), so
//    short commands and silent sessions never auto-stop. A watchdog task provides
//    the missing exits: silence-stability commit, empty-capture reset, and periodic
//    session recycling (WhisperKit re-transcribes its whole un-purged buffer, so
//    unbounded passive sessions degrade).
//  - Only ONE Whisper stream exists app-wide; the overlay must fully stop its
//    session on teardown or it starves composer dictation.
//

import Foundation
import AppKit
import AVFoundation
import Observation

// MARK: - Stage

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
    /// [Phase 6 · F1] Escalating detail about the run that just finished. Deliberately ON DEMAND:
    /// a run report spoken after every turn is noise, and the verdict adds nothing to an answer
    /// the user just heard in full.
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
    /// Canonical wake word — whatever the user configured, sanitized, defaulting to "orb".
    ///
    /// ⚠️ Read at USE time, never captured into a `let`. It was a `static let` until 2026-09-19,
    /// which is what made the setting impossible: every matcher below derived from it once, at
    /// type-initialization, so a word typed in Settings could never reach a running orb.
    static var wakeWord: String { OrbConfigManager.shared.wakeWord }
    /// Spoken when a run ends WELL. ⚠️ Until the reply itself is spoken (roadmap Phase 1)
    /// the announcement is the ONLY thing a voice-only user hears, so it must reflect the
    /// real outcome — see `announcement(for:reason:)`, not this constant, at the call site.
    static let completionPhrase = String(localized: "Your task is completed, let me know next")
    /// Command considered final after this much NORMALIZED-command stability (VAD's
    /// own 1.5s auto-stop usually wins when WhisperKit has confirmed segments).
    ///
    /// Forwards to the config manager at USE time rather than caching: the watchdog re-reads this
    /// on every 300ms tick, so a change in the settings pane reaches a RUNNING orb with no other
    /// plumbing. That matters because the panel keeps its session private and lives outside the
    /// SwiftUI environment — the config manager is the only channel Settings has.
    private static var commandSilenceCommit: TimeInterval {
        OrbConfigManager.shared.endpointing.seconds
    }
    /// Wake word heard but nothing said — give up capture and re-arm after this.
    private static let emptyCaptureTimeout: TimeInterval = 8.0
    /// Hard cap for a single capture session: whatever has been heard by now IS the
    /// command. Kept short because in a noisy room (fan hum) Whisper hallucinates
    /// ever-changing text at rising temperatures, so no stability window ever
    /// settles — observed on device as a capture that ran 54s until force-quit.
    /// This cap is the guarantee that capture always ends promptly.
    private static let captureHardCap: TimeInterval = 18.0
    /// Recycle passive sessions to bound WhisperKit's ever-growing audio buffer.
    private static let passiveRecycleInterval: TimeInterval = 45.0
    private static let energyBarCount = 48

    /// Minimum word count before a capture is dispatched to a profile.
    ///
    /// ⚠️ `!command.isEmpty` was the ONLY gate on the send path. Whisper hallucinates short
    /// filler on silence and steady background noise — "Thank you." is the canonical one, and
    /// this controller's own notes at `captureHardCap` record hallucination on fan hum — while
    /// the profile picker admits `.agent` profiles, which have shell and filesystem tools. So a
    /// single hallucinated token could start a tool-using run the user never asked for. Two
    /// words is the cheapest gate that does not cost real commands: a genuine one-word request
    /// to an agent is rare, and the user can simply say it again.
    static let minimumCommandWords = 2

    /// Spoken phrases that ABORT an armed capture instead of becoming the command.
    /// The audible half of the cancel path — see `cancelCapture()` for why one was needed.
    static let cancelPhrases = ["never mind", "nevermind", "cancel that", "forget it"]

    /// Short ways of saying "stop" — to a capture, or to Orb while he is speaking.
    ///
    /// ⚠️ A SEPARATE list from `cancelPhrases`, never additions to it, for two reasons:
    ///  1. `isCancelPhrase` also matches as a SUFFIX, so "stop" there would cancel "make the build
    ///     stop" and swallow a real request. These match the WHOLE utterance only.
    ///  2. `isCancelPhrase` is also what DENIES a parked tool in the spoken-approval window ("only
    ///     an explicit cancel phrase denies"). Widening it would silently widen that.
    /// Device, 2026-09-19: "stop" reached the two-word dispatch floor and was logged as a Whisper
    /// hallucination guard — the right outcome (nothing sent) for the wrong reason, in silence.
    static let stopPhrases = ["stop", "stop it", "stop talking", "cancel", "enough",
                              "quiet", "be quiet", "shush", "shut up"]

    /// Whether the WHOLE utterance is a stop phrase, said once or repeated ("stop, stop"). Pure.
    ///
    /// ⚠️ Only safe on a FINISHED utterance. Whisper re-decodes every ~1.1 s, so "stop the server"
    /// is a bare "stop" for one partial — matching this on the live path would cancel the request
    /// mid-sentence. `classifyCapture` runs it only after endpointing has settled.
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

    /// Whether a transcript heard WHILE ORB SPEAKS ends in a stop phrase. Pure.
    ///
    /// Deliberately looser than `isStopPhrase` — a suffix, not the whole utterance — because the
    /// narration listener acts on nothing else: a stray word before "stop" (a cough, residue the
    /// echo canceller let through) must not make the interrupt fail. A false match is bounded: the
    /// answer stops early, and it is still in the chat window.
    static func endsWithStopPhrase(_ transcript: String) -> Bool {
        let normalized = normalizedForStability(transcript)
        guard !normalized.isEmpty else { return false }
        return stopPhrases.contains { normalized == $0 || normalized.hasSuffix(" " + $0) }
    }

    /// Whether a microphone may stay open while Orb speaks, listening ONLY for a stop. Pure.
    ///
    /// ⚠️ Echo cancellation is the whole precondition. Without it the microphone hears Orb, and a
    /// recognizer transcribing Orb's own voice can interrupt — or, back in passive listening, wake
    /// — itself. `OrbDuplexAudio.isEchoCancelling` is the same fact that decides whether an answer
    /// renders through the shared engine at all (see `OrbStreamingSpeaker.begin`).
    /// ⚠️ WhisperKit only: Apple Speech runs its own loop and releases the duplex engine first.
    /// ⚠️ Never during an approval announcement ("I'll leave that one on screen"). Those spend a
    /// second in `.announcing` between two `.awaitingApproval` stages, and an interrupt there
    /// would drop the orb to passive listening with a run still parked.
    static func listensDuringNarration(echoCancelling: Bool,
                                       recognizerIsAppleSpeech: Bool,
                                       announcingApproval: Bool) -> Bool {
        echoCancelling && !recognizerIsAppleSpeech && !announcingApproval
    }

    /// What a transcript update from a narration listener does. Pure.
    ///
    /// ⚠️⚠️ THE SAFETY PROPERTY IS THAT NOTHING HERE FALLS THROUGH. A session opened during
    /// narration yields `.dropStale`, `.keepListening` or `.interrupt` — never the ordinary path —
    /// because the ordinary path includes the follow-up window, where ANY speech is dispatched.
    /// After the answer ends the listener is closed asynchronously, and its late updates would
    /// otherwise land in exactly that window carrying whatever it heard during the answer.
    static func narrationListenerAction(openedDuringNarration: Bool,
                                        stage: OrbStage,
                                        transcript: String) -> OrbNarrationListenerAction {
        guard openedDuringNarration else { return .notANarrationListener }
        guard stage == .announcing else { return .dropStale }
        return endsWithStopPhrase(transcript) ? .interrupt : .keepListening
    }

    /// What a FINISHED capture becomes. Pure, and the ONLY place this decision is made.
    ///
    /// ⚠️ ONE CLASSIFIER FOR BOTH LOOPS. The WhisperKit and Apple Speech loops each carried their
    /// own copy of this cascade, and the copies had already drifted — Apple's spoken cancel logged
    /// and played nothing. A stop phrase added to one copy is exactly what the other would miss.
    /// Order is load-bearing: cancel and stop come before the dispatch floor, so a one-word "stop"
    /// is a cancel and never reaches the floor.
    static func classifyCapture(_ command: String) -> OrbCaptureOutcome {
        if isCancelPhrase(command) || isStopPhrase(command) { return .cancel }
        if let voiceCommand = voiceCommand(in: command) { return .voiceCommand(voiceCommand) }
        if isDispatchable(command) { return .dispatch }
        return command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .nothingHeard : .belowFloor
    }

    /// Seconds to wait for `AVSpeechSynthesizer`'s `didFinish` before handing back anyway.
    /// Generous: it is a deadlock breaker, not a pacing control.
    private static let speechCompletionTimeout: TimeInterval = 20

    /// CoreAudio settle time before opening the mic. AVSpeechSynthesizer's output
    /// context is torn down asynchronously AFTER its didFinish delegate fires, so
    /// starting AVAudioEngine too soon races that teardown and the HAL refuses the
    /// device (`-10877`, `_StartIO ... error 35`). WhisperKit swallows that failure,
    /// so the session "succeeds" with a dead mic. Paired with
    /// `OrbVoiceOutput.releaseAudio()`, which deallocates the synthesizer first.
    private static let audioSettleDelay: TimeInterval = 1.0

    /// Releases the speech synthesisers and waits out the CoreAudio race — UNLESS the duplex
    /// engine is up and cancelling echo, in which case there is nothing to race.
    ///
    /// ⚠️ The skip is only sound because BOTH speech paths (`OrbVoiceOutput` for short phrases
    /// and `OrbStreamingSpeaker` for the answer) render through the shared engine's player
    /// node when it is warm. One remaining plain `AVSpeechSynthesizer` would reintroduce the
    /// asynchronous audio-unit teardown this delay exists to outlast, and the microphone would go
    /// quietly dead again.
    private func settleAudioBeforeCapture() async {
        // ⚠️ An ambient announcement speaks WITHOUT holding the stage, so the next session recycle
        // (every 45 s in passive listening) used to reach `voice.releaseAudio()` and deallocate
        // its synthesizer mid-sentence — silently, because `speakAmbient` arms no completion. The
        // announcement is a few seconds; letting it finish costs one delayed session.
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
        try? await Task.sleep(nanoseconds: UInt64(Self.audioSettleDelay * 1_000_000_000))
    }
    /// Consecutive dead sessions before surfacing voiceUnavailable instead of retrying.
    private static let maxDeadSessions = 4
    /// How long an OPEN session may deliver no audio before the orb says so.
    ///
    /// A healthy microphone produces energy samples within ~100ms even in a silent room, so this
    /// cannot false-positive on quiet. Kept short because the whole point is to beat the user's
    /// patience.
    static let deadAudioWarningDelay: TimeInterval = 3.0

    /// How long an Apple Speech session may deliver no audio before it is ended so the retry
    /// ladder can run.
    ///
    /// ⚠️ Only the Apple path needs this. WhisperKit's passive sessions are recycled every 45s for
    /// buffer reasons, so a dead session there always ends by itself and reaches the post-session
    /// check; `SpeechAnalyzer` needs no recycle, so a dead passive session would otherwise run
    /// FOREVER and the escalation to OFFLINE would never be reached.
    ///
    /// Safe to keep short because the signal is "the tap has delivered ZERO buffers", not
    /// "nobody spoke" — a healthy engine delivers buffers within ~100 ms in a silent room, so this
    /// cannot cut short a user who is merely thinking.
    static let deadAudioSessionLimit: TimeInterval = 12.0

    /// What to do after a session that delivered no audio at all.
    enum DeadSessionOutcome: Equatable {
        case retry(backoff: TimeInterval)
        /// Stop pretending to listen and say so.
        case giveUp
    }

    /// ⚠️ SHARED BY BOTH RECOGNIZER LOOPS, and that is the whole point of it existing.
    ///
    /// This ladder was written inline in the WhisperKit loop and simply never written in the Apple
    /// Speech one, so a wedged input device left that path re-arming forever on a healthy-looking
    /// STANDBY — with "Repair Audio…" unreachable, because it is gated on the very flags this
    /// escalation sets. Two copies of a policy is how one of them ends up missing; one pure
    /// function that both call is how the next recognizer inherits it for free.
    ///
    /// The backoff climbs so the HAL gets progressively longer to release a device another app is
    /// holding — the usual cause when a microphone opens and delivers nothing.
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
    /// True once a microphone session has opened but delivered NO audio.
    ///
    /// ⚠️ Deliberately SEPARATE from `voiceUnavailable`. The first `-10877` is often transient
    /// engine spin-up noise that the very next attempt survives, so giving up after one failure
    /// would be wrong — but saying NOTHING for four failures plus escalating backoff leaves the
    /// orb sitting on STANDBY, looking healthy, while deaf. Observed on 2026-09-04: the user
    /// closed the panel before the escalation ever fired and never learned the mic was dead.
    /// This warns immediately while the loop keeps retrying underneath.
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
    ///
    /// ⚠️ Leading wake words are stripped on BOTH paths, not only the wake-word one. Observed on
    /// device 2026-09-19: the user said the wake word three times, nothing visibly registered, they
    /// clicked the orb and carried on — and "Orba, Orba, Orba. Write an essay…" reached the model
    /// whole, because the click path only dropped the pre-arm baseline (and Whisper had rewritten
    /// that baseline out of the final text anyway). A click after an unanswered wake word is the
    /// common case, not an edge case, and the wake word is never part of what was asked.
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

    /// ⚠️ INJECTED, not `ChatPersistenceStore.shared`. Three call sites here reached the singleton
    /// directly, which meant any test touching the dispatch wrote to the real SwiftData store —
    /// so nothing did, and this surface shipped its send path with 269 tests around it and none
    /// through it. Typed as the protocol, matching every comparable type in the app
    /// (`ActiveStreamManager`, `ChatHistoryViewModel`, `MessagingCoordinator`,
    /// `SchedulerCoordinator`, and now `QuickAccessSessionViewModel`).
    ///
    /// Defaulted to `.shared` so the one production construction site
    /// (`OrbPanelController.swift:128`) is unchanged.
    @ObservationIgnored private let persistence: ChatPersistenceProtocol

    init(persistence: ChatPersistenceProtocol = ChatPersistenceStore.shared) {
        self.persistence = persistence
    }
    @ObservationIgnored private let backendConfiguration = BackendConfiguration()
    @ObservationIgnored private let voice = OrbVoiceOutput()
    /// Narrates the assistant's answer as it streams (Phase 1).
    @ObservationIgnored private let speaker = OrbStreamingSpeaker()
    /// [Phase 6 · F3] Announces main-window runs. ⚠️ Held STRONGLY here, and nowhere else.
    /// `ActiveStreamManager` keeps mirror delegates in weak boxes and silently compacts dead ones
    /// away with no log — a watcher owned by a closure or a local would simply stop working, and
    /// nothing would say so.
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
    /// [Phase 6 · F2] The operation a spoken "yes" would currently approve, and the deadline
    /// after which it no longer would.
    ///
    /// ⚠️ BOTH are required. A parked run can sit for hours, and `.awaitingApproval` has no
    /// natural closing edge — an armed window with no deadline is an open microphone in a room,
    /// indefinitely, waiting for a word a television could supply.
    /// ⚠️ The WHOLE token, not just the id: `.describe` re-reads the tool and its arguments, and
    /// rebuilding that sentence from anywhere else would let the second read-back drift from the
    /// first — in the one exchange whose entire purpose is that the user knows what they are
    /// approving.
    @ObservationIgnored private var voiceApprovalToken: OrbApprovalPolicy.VoiceApproval?
    private var voiceApprovalOperationID: UUID? { voiceApprovalToken?.operationID }
    @ObservationIgnored private var voiceApprovalTask: Task<Void, Never>?
    @ObservationIgnored private let logger = DGLogger(category: "OrbSession")

    /// Correlation identity for EVERY Orb log line.
    ///
    /// ⚠️ Orb fails acoustically and unreproducibly — a microphone that opened but delivered
    /// nothing, a wake word that never matched, a run that parked while nobody was looking. The
    /// log is the only viable debugging channel, and a log you cannot reassemble into a single
    /// session is not one. `s` identifies the panel presentation, `t` the turn within it.
    @ObservationIgnored private let sessionID = UUID().uuidString.prefix(4).lowercased()
    /// ⚠️ Stamped when a CAPTURE begins, not when a send is decided.
    ///
    /// It used to be assigned inside `execute()`, so every line produced while listening, arming
    /// on the wake word, capturing, discarding or cancelling carried the id of the LAST turn that
    /// dispatched — including the abort line, which fires before the assignment. Reconstructing a
    /// turn from the log is the entire purpose of this field, and the lines that describe why a
    /// turn never happened were filed under the previous one.
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
    /// When the current phrase started, and how long it was — used to catch a synthesizer that
    /// "finishes" instantly because it produced no audio at all.
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
    /// How many voice turns this session has sent, for the two log lines that report what a
    /// profile switch or a "new conversation" command discards.
    ///
    /// ⚠️ WAS `transcript: [ChatMessage]`, holding every user and agent message of the session.
    /// Its only real consumer was `history: transcript` on the `startMessageStream` call; once
    /// history became DERIVED (2026-09-06) nothing read the elements — only `.count`, twice — so
    /// the array was retaining full agent messages, streamed content and timeline events included,
    /// to produce an Int. An `Int` carries that signal, and the signal is worth keeping: it is
    /// what distinguishes "this voice session has said nothing" from "its turns went somewhere
    /// else".
    ///
    /// ⚠️ THE NUMBER CHANGED, and older logs are not comparable. The array was appended twice per
    /// turn — once for the user's message and once for the agent's, both inside `execute(_:)` —
    /// so `transcript.count` was about DOUBLE the turn count those lines have always claimed to
    /// report. This counts turns, once, at the user's message.
    @ObservationIgnored private var spokenTurnCount: Int = 0
    @ObservationIgnored private var streamingMessageID: UUID?
    /// Dead-mic sessions in a row (see audioSettleDelay).
    @ObservationIgnored private var consecutiveDeadSessions = 0
    /// Whether the audio engine delivered ANY samples this session. The authoritative
    /// liveness signal: a failed `_StartIO` still lets WhisperKit's loop run and end
    /// "normally", so a dead mic can look like a long, healthy, silent session
    /// (observed: 27.4s, empty transcript). Duration alone can't tell them apart.
    @ObservationIgnored private var receivedAudio = false
    /// Incremented whenever the voice loop must stop. A running loop compares its
    /// captured generation on every iteration and exits when it no longer matches —
    /// the reliable stop signal, since Task cancellation doesn't propagate out of
    /// WhisperKit's realtime loop. See `stopListening()`.
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
    /// When command capture was armed (wake word or tap). The capture hard cap
    /// measures from HERE, not from session start — a wake word spoken 15s into a
    /// passive session must still get the full capture window (first device test:
    /// wake at ~11s, session-age cap at 18s left only ~7s to speak).
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
            // ⚠️ Through the arbiter, never `voice.speak` directly: an announcement that lands
            // mid-turn would orphan the in-flight speech hand-back and park the orb.
            self?.speakAmbient(phrase, reason: reason)
        }
        watcher.correlationTag = tag
        ambientWatcher = watcher
        // ⚠️ Every panel-scoped audio type, not just the speakers. These lines are the ones a
        // device test actually reads, and they carried no session id at all.
        OrbDuplexAudio.shared.correlationTag = tag
        voice.correlationTag = tag
        speaker.correlationTag = tag
        mainVM.activeStreamManager.addMirrorDelegate(watcher)
        logger.info("[ORB_SESSION]\(self.tag) Ambient run watcher registered (announcements \(OrbConfigManager.shared.ambientAnnouncements ? "on" : "off"), threshold \(Int(OrbConfigManager.shared.ambientThresholdSeconds))s).")
    }

    /// True when a previously-chosen profile still resolves. Drives the "ask once,
    /// then go straight to the orb" behavior: the picker is a first-run step only.
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
        // ⚠️ ONE line that answers "which build is this, and how is it configured?". Without it,
        // a device test cannot distinguish "the fix is not in this binary" from "the fix is in and
        // correctly silent" — both look identical in a log. Bump `featureMarker` with any change
        // a tester is asked to verify.
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

    /// Config-bubble action: return to the picker. Stops the voice loop and any run
    /// first so the new profile starts from a clean session.
    ///
    /// ⚠️ The conversation state MUST be cleared here. Without it the newly-chosen profile
    /// inherited the previous profile's turns as LLM history and appended its run into the
    /// previous profile's conversation — so switching from a local bot to a cloud agent
    /// silently replayed the bot's transcript to the agent, and the sidebar showed one
    /// conversation whose messages came from two different backends.
    func requestProfileSwitch() {
        guard stage != .selectingProfile else { return }
        stopListening()
        // The picker can stay open indefinitely. Holding the input device — and the orange
        // indicator — while nothing listens is both rude and a needless crash-wedge window;
        // `selectProfile` warms again on the way out.
        OrbDuplexAudio.shared.releaseWhenIdle(reason: "profile picker open")
        if let id = streamingMessageID {
            mainVM?.activeStreamManager.cancelStream(for: id)
            streamingMessageID = nil
        }
        // ⚠️ SAME ORDER AS `teardown()`, AND FOR THE REASON IT DOCUMENTS: `voice.stop()` drops the
        // synthesizer's completion, so `didFinish` never drains the pending hand-back — and the
        // 20 s watchdog then fires into a session that has moved on. `drainSpeechCompletion` only
        // guards on `dismissed`, which is FALSE here because the panel is still open, so the
        // greeting's stale "start listening" closure would drag the user back out of the picker.
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

    /// Tears down the voice loop without ending the whole session (profile switch).
    ///
    /// ⚠️ `listenTask.cancel()` alone is NOT enough: `startStreaming` awaits WhisperKit's
    /// realtime loop, which swallows the CancellationError and returns normally, so the
    /// `while` loop would happily open ANOTHER mic session afterwards. Observed on device
    /// as sessions opening in the `selectingProfile` stage — and because there is exactly
    /// one Whisper stream slot app-wide, those zombie sessions fight the live one for the
    /// audio device. Bumping the generation orphans the old loop for good.
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
        // ⚠️ Synchronous, and NOT inside the Task below. The engine is panel-scoped now, so this
        // is the primary release path: a live AVAudioEngine at process death wedges coreaudiod
        // into `_StartIO error 35` — an app-wide dead microphone that survives relaunch.
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
                // ⚠️ Revoke the blanket grant with the panel. It is in-memory so it cannot survive
                // relaunch — but it WOULD survive the orb closing, and a mode the user can no
                // longer see must not still be approving tools.
                await SessionToolApprovals.shared.setAutonomous(false, conversationID: convID, origin: .orb)
            }
        }
        logger.info("[ORB_SESSION]\(self.tag) Panel torn down — voice loop stopped, run cancelled, autonomous grant revoked.")
    }

    // MARK: System power / lock

    /// Releases the microphone while the machine is asleep or the screen is locked.
    ///
    /// ⚠️ There were NO sleep, wake, or lock observers anywhere in the app, and the Orb panel
    /// is `.canJoinAllSpaces` with `hidesOnDeactivate = false` — so locking the screen left a
    /// full Whisper decoder running against the microphone indefinitely, behind the lock screen,
    /// where the orb's own recording cue is not even visible.
    private func installSystemObservers() {
        guard workspaceObservers.isEmpty, distributedObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        let pause: (Notification) -> Void = { [weak self] note in
            MainActor.assumeIsolated { self?.suspendForSystemEvent(note.name.rawValue) }
        }
        // ⚠️ WAKE IS NOT UNLOCK. `didWake` and `screensDidWake` both fire while the Mac is still
        // showing the LOGIN WINDOW. Wiring them straight to resume reopened the microphone there —
        // and because resume cleared `systemSuspended`, the real `screenIsUnlocked` that followed
        // found nothing to do, so the lock-state observer gated nothing at all.
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
        // ⚠️ All FOUR mic-holding stages. `.followUpWindow` and an armed `.awaitingApproval` also
        // keep a session open, so omitting them left Whisper recycling sessions behind the lock
        // screen — precisely what these observers were added to prevent.
        guard stage == .passiveListening || stage == .commandCapture
                || stage == .followUpWindow
                || (stage == .awaitingApproval && isVoiceApprovalArmed) else { return }
        logger.info("[ORB_SESSION]\(self.tag) Releasing the microphone for system event \(event). CONSEQUENCE: the wake word cannot fire until the system wakes — an in-flight run keeps executing, only listening stops.")
        // A capture armed before the machine slept is stale by definition — the user walked away.
        if stage == .commandCapture {
            manualCaptureBaseline = nil
            setStage(.passiveListening, "suspendForSystemEvent")
        }
        // ⚠️⚠️ #10 — DISARM BEFORE STOPPING. `.awaitingApproval` is the one stage the spoken
        // approval work newly made hold the microphone open, and an armed window survives a screen
        // lock: for its remaining seconds a bystander at a locked Mac could say the approve
        // keyword and commit a tool. Disarming also closes the session, so it must come first.
        if isVoiceApprovalArmed {
            logger.notice("[ORB_HITL]\(self.tag) Disarming the spoken approval for \(event) — the request stays on screen and must be answered there. CONSEQUENCE: nobody can approve it by speaking at a locked or sleeping Mac.")
            disarmVoiceApproval(reason: "system event: \(event)")
        }
        stopListening()
        // ⚠️ Non-optional. These observers exist because a decoder once ran against the
        // microphone behind the lock screen; a panel-scoped engine that survived sleep would
        // hold the device — and its indicator — with nothing even listening.
        OrbDuplexAudio.shared.release(reason: "system suspend")
    }

    /// A display or system wake. ⚠️ Resumes ONLY if the screen is not locked — otherwise the
    /// microphone would reopen at the login window, which is what these observers exist to prevent.
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
        // ⚠️ `fetchSharedProfiles`, not `fetchProfiles`. The type filter below is NOT sufficient:
        // bot/agent is exactly what a workflow node owns, so the unfiltered list offered every
        // node's private configuration here as if it were one of the user's chat profiles — and
        // selecting one persists its id to UserDefaults, making a node's row the remembered Orb
        // profile until the node is deleted and its row collected out from under it.
        let all: [BackendProfileModel]
        do {
            all = try BackendProfileStore.shared.fetchSharedProfiles()
        } catch {
            // Swallowed into `?? []` before, which renders as an empty picker — indistinguishable
            // from a user who genuinely has no profiles, and it sends them to create one they
            // already have.
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
        // ⚠️ ORDER IS THE WHOLE POINT. Voice processing is healthy when its engine is the first
        // audio client and dead when it follows a speech synthesiser's teardown, so the engine is
        // warmed and AWAITED before Orb says a word. Greeting first would rebuild the exact
        // failure this phase exists to remove.
        Task { [weak self] in
            guard let self else { return }
            await OrbDuplexAudio.shared.warm(reason: "panel open")
            guard !self.dismissed else { return }
            // ⚠️⚠️ THE OTHER HALF OF THE COLD-OPEN FIX. The shortcut opens the panel and arms
            // capture in one gesture, and `beginPushToTalk` runs SYNCHRONOUSLY after `show()` —
            // before this Task ever gets to speak. Without this guard the greeting would start on
            // top of the capture that press just armed, and its hand-back would then drag the
            // stage back to `.passiveListening`, cancelling the user's own turn mid-sentence.
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
        // ⚠️ Both edges of `.announcing` live HERE, not at the six places that enter it: the funnel
        // is the one place a new entry point cannot forget. Exit first — it only ever closes.
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
        // A session still open from before this narration (a passive session, when the answer was
        // started from a tap) holds a transcript that is not about this answer. End it; the loop
        // then reopens as a narration listener.
        if isSessionActive, !sessionOpenedDuringNarration {
            Task { _ = await WhisperRecognitionService.shared.stopStreaming() }
        }
        startListeningLoop()   // a no-op when a loop is already running — it picks the stage up itself
    }

    /// Exit edge of `.announcing`: the narration listener must never outlive the narration.
    ///
    /// ⚠️⚠️ THE SAFETY HALF. The follow-up window treats ANY speech as the next command, and
    /// `liveTranscript` is reset only when a new session opens. A listener carried across this
    /// edge would hand the window whatever it heard during the answer — Orb's own voice, if the
    /// echo canceller leaked — as a command to dispatch. So: clear the transcript, end the
    /// session, and let the loop open a fresh one (it discards this one unclassified).
    private func closeNarrationListener(_ origin: String) {
        guard sessionOpenedDuringNarration else { return }
        liveTranscript = ""
        lastNormalizedCommand = ""
        guard isSessionActive else { return }
        logger.info("[ORB_ASR]\(self.tag) Closing the narration listener (\(origin)). CONSEQUENCE: nothing it heard is carried into \(Self.name(of: self.stage)); a fresh session opens.")
        Task { _ = await WhisperRecognitionService.shared.stopStreaming() }
    }

    /// Whether entering `stage` should hand the input device back. Pure.
    ///
    /// ⚠️⚠️ THIS FUNCTION EXISTS TO RECORD A REJECTED DESIGN, not just the accepted one. The
    /// obvious reading of "release the engine on long idles" is to release on the LONGEST parks —
    /// `.awaitingApproval` (a run stopped to ask the user something can sit for hours) and
    /// `.executing`. Both were reviewed against the source and both are unsafe:
    ///
    ///  1. The guard everyone reaches for — "release only when no spoken-approval window is armed"
    ///     — is DEAD CODE. Arming happens inside the approval prompt's speech hand-back, one to two
    ///     seconds AFTER `setStage(.awaitingApproval)`, so `isVoiceApprovalArmed` is false at every
    ///     entry. The hook would fire on 100% of parks, including the spoken-approval parks it was
    ///     written to exclude, moments before the microphone that can authorise a tool call opens.
    ///  2. The release lands on a LIVE NARRATION QUEUE. A run parks mid-answer, `OrbDuplexSpeaker`
    ///     holds the player node across its own FIFO, and `stopEngine` stops that node underneath
    ///     it — the render never terminates, the 8 s watchdog hands back, the pump starts the next
    ///     sentence, and `player.play()` on a stopped engine is "a crash, not a silent no-op"
    ///     (`OrbDuplexAudio.playbackTarget`). Cancelling the speaker first is not an out: that
    ///     latches `cancelled` and drops the rest of the answer for the whole run.
    ///  3. The paired re-warm is REFUSED on the commonest exit. `stopListening()` does not await
    ///     `stopStreaming`, so `VoiceSessionLedger`'s owner is still `.orb` when `warm()` checks
    ///     it; the warm returns false with an info-level line and nothing retries. The session runs
    ///     cold for the rest of the panel, silently.
    ///
    /// `.voiceUnavailable` survives all three: nothing is narrating, voice input has already been
    /// declared dead so the engine is provably useless, and the stage has exactly one automatic
    /// exit — `retryVoice()` — where the re-warm can be awaited before anything listens.
    ///
    /// Adding a stage here means solving 1–3 for it first.
    static func releasesEngineOnEntry(to stage: OrbStage) -> Bool {
        if case .voiceUnavailable = stage { return true }
        return false
    }

    /// Gives the input device back when voice input has been declared unavailable.
    ///
    /// ⚠️ HOOKED ON THE STAGE FUNNEL, NOT ON EIGHT CALL SITES. There are eight places that enter
    /// `.voiceUnavailable` across the two recognizer loops, and a release wired at seven of them is
    /// the "two copies of a policy, one of them missing" shape that produced the Apple Speech
    /// dead-mic gap. `setStage` is documented as the ONLY way the stage changes, so it is the only
    /// place this cannot be forgotten.
    ///
    /// ⚠️ WHY THIS STAGE AND NOT THE OTHER LONG PARKS. `.voiceUnavailable` is the one place the
    /// engine is provably useless — voice input has already been declared dead — and it has no
    /// timer, so an OFFLINE orb left overnight is the longest-lived warm-engine window there is.
    /// It also actively helps on the `.sessionBusy` cause, where Orb was holding the very device
    /// the composer is trying to claim. Releasing in `.awaitingApproval` or `.executing` was
    /// considered and REJECTED — see the note on `retryVoice()`.
    ///
    /// ⚠️ NEVER WHILE SPEECH IS IN FLIGHT. `OrbDuplexSpeaker` holds the player node across its
    /// own queue, and `stopEngine` stops that node underneath it: the render never terminates, the
    /// 8 s watchdog hands back, the pump starts the next sentence, and `player.play()` on a stopped
    /// engine is — in this subsystem's own words — "a crash, not a silent no-op". The engine stays
    /// up in that case; the panel teardown still releases it.
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

    /// Plays a short system sound marking a turn boundary.
    ///
    /// ⚠️ `NSSound`, deliberately not `AVAudioPlayer` or a synthesizer: it does not hold a
    /// CoreAudio OUTPUT context open, so it cannot re-arm the documented -10877 microphone race
    /// the way `AVSpeechSynthesizer` does. A retired system sound name yields nil and therefore
    /// simply no sound — never a failure.
    private func playEarcon(_ cue: OrbEarcon) {
        guard OrbConfigManager.shared.earcons.plays(cue) else { return }
        NSSound(named: cue.systemSoundName)?.play()
    }

    // MARK: Speech hand-back

    /// Speaks `phrase` and GUARANTEES `then` runs exactly once.
    ///
    /// ⚠️ `.welcoming` and `.announcing` each had exactly ONE exit: `AVSpeechSynthesizer`'s
    /// `didFinish` delegate, which has no timeout and no failure path. A synthesizer that never
    /// fires it — a voice asset that fails to load, an output device pulled mid-phrase — parked
    /// the stage machine permanently with the microphone CLOSED and no in-UI recovery: the orb
    /// sat on INITIALIZING or COMPLETE forever and only closing the panel got out.
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

    /// [Phase 6 · S1] Speaks something NOBODY asked for — and refuses rather than interrupt.
    ///
    /// ⚠️ WHY THIS IS NOT `speakWithWatchdog`. That method writes a single `pendingSpeechCompletion`
    /// optional, and nil-ing it out IS the exactly-once guarantee. A second call while one is in
    /// flight silently discards the first hand-back, and the watchdog then fires for the SECOND
    /// phrase — so the orphaned stage transition never happens and the orb parks forever. Ambient
    /// announcements are the first thing in Orb that can speak concurrently with a turn, so
    /// they must yield instead of overwriting.
    ///
    /// A dropped announcement is a non-event; a parked orb is a bug report.
    @discardableResult
    private func speakAmbient(_ phrase: String, reason: String) -> Bool {
        guard !dismissed else { return false }
        if pendingSpeechCompletion != nil || voice.isSpeaking || speaker.isSpeaking {
            logger.info("[ORB_SESSION]\(self.tag) Ambient announcement DROPPED (\(reason)) — Orb is already speaking. CONSEQUENCE: this one is never spoken; interrupting would orphan the in-flight turn's hand-back and park the orb.")
            return false
        }
        // Only the idle stages. Announcing over a command capture would eat the user's words, and
        // over an approval it would talk across something they are being asked to decide.
        // ⚠️ NOT `.followUpWindow`. That is the one stage where ANY transcript is treated as a
        // command, and with no echo cancellation Orb hears his own announcement, arms capture,
        // and dispatches "your task in the main window finished" to the model as if the user had
        // said it. Rule 4 says "not while speaking OR LISTENING FOR A COMMAND" — this is the
        // listening half.
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
        // ⚠️ A synthesizer whose audio unit is dead still calls didFinish — immediately, having
        // played nothing. Observed on device as `AVAudioBuffer mBuffers[0].mDataByteSize (0)`
        // with a wedged coreaudiod: the greeting "completed" in milliseconds and Orb advanced
        // as though it had spoken. AVFoundation reports the zero-byte buffer, we do not, so from
        // this log alone the greeting looked fine. Roughly 40 ms per character is far slower than
        // any real voice, so anything faster did not play.
        // Real speech runs at roughly 60-80ms per character. 30ms/char is still twice as fast as
        // any voice, and the 0.25s floor catches a SHORT phrase — "Hello Raj" is 9 characters, so
        // a per-character rule alone gave it a 90ms budget and the failure (~100-200ms) slipped
        // through. Observed 2026-09-04: the greeting produced a zero-byte buffer and this said
        // nothing.
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
    ///
    /// The wedge survives quitting the app, so without this the only remedy is a terminal — an
    /// unreasonable ask for a feature whose failure mode is silence.
    func repairAudio() {
        // ⚠️ Release BEFORE the daemon restarts. Restarting coreaudiod under a live engine is how
        // the wedge got created in the first place.
        let wasWarm = OrbDuplexAudio.shared.isWarm
        OrbDuplexAudio.shared.release(reason: "audio repair")
        let outcome = OrbAudioRepair.run(logger: logger, tag: tag)
        guard outcome == .repaired else {
            // ⚠️ Both the alert and the administrator prompt are DECLINABLE, and this early return
            // used to leave the engine torn down for the life of the panel — so cancelling a
            // repair silently cost echo cancellation on every later turn, for a dialog the user
            // was invited to dismiss.
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

    /// [Batch 1 · #46] Called when the activation mode changes while the panel is OPEN.
    ///
    /// ⚠️ Without this the switch was one-directional. Continuous → hold is handled inside the
    /// loop (it closes the microphone on the next iteration), but hold → continuous unregistered
    /// the shortcut and started no loop, so the orb read STANDBY and the wake word did nothing —
    /// and clicking it then wedged the session in LISTENING with no session behind it.
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

    /// [Batch 1 · #47] Called when the user switches the spoken-approval channel OFF.
    ///
    /// ⚠️ Must close the microphone too, not just disarm. `.awaitingApproval` keeps the mic open
    /// for as long as the window is armed, so disarming alone would leave it hot with nothing
    /// listening for it.
    func cancelVoiceApproval(reason: String) {
        guard isVoiceApprovalArmed else { return }
        disarmVoiceApproval(reason: reason)
        logger.notice("[ORB_HITL]\(self.tag) Spoken approval withdrawn mid-window (\(reason)). CONSEQUENCE: the microphone is closed and the request stays on screen to be answered there.")
    }

    /// [Batch 1 · #49] Called when the Tool approvals picker changes while the orb is open.
    ///
    /// ⚠️ The autonomous grant is applied per DISPATCH and otherwise revoked only at teardown, so
    /// a mid-run change never reached the run in flight — the picker said "Ask me" while every
    /// remaining tool call kept auto-approving.
    func toolApprovalsChanged() {
        guard !dismissed, let convID = orbConversationID else { return }
        let autonomous = OrbConfigManager.shared.toolApprovals == .autonomous
        logger.notice("[ORB_HITL]\(self.tag) Tool approvals changed to \(OrbConfigManager.shared.toolApprovals.rawValue) mid-session — applying to the run in flight. CONSEQUENCE: \(autonomous ? "remaining tool calls in this conversation are auto-approved" : "the blanket grant is revoked NOW; the next tool call asks").")
        Task { await SessionToolApprovals.shared.setAutonomous(autonomous, conversationID: convID, origin: .orb) }
    }

    /// Re-entry point from the voiceUnavailable stage.
    ///
    /// ⚠️ MUST WARM, AND MUST AWAIT IT. Entering `.voiceUnavailable` now releases the engine, so
    /// this is the matching re-warm — and a fire-and-forget `Task` would lose the race with
    /// `startListeningLoop`, leaving `borrow()` to return nil and the session silently running
    /// without echo cancellation for the rest of the panel. `selectProfile` is the template: warm
    /// first, then listen.
    ///
    /// ⚠️ THE TWO PARKS THAT ARE DELIBERATELY NOT RELEASED. `.awaitingApproval` and `.executing`
    /// are longer-lived still, and releasing there was reviewed and rejected on three concrete
    /// grounds: the "only when no approval window is armed" guard is DEAD CODE (arming happens in
    /// the approval prompt's hand-back, one to two seconds AFTER the stage is set, so the flag is
    /// false at every entry); the release lands on a live narration queue and reaches
    /// `player.play()` on a stopped engine; and the paired re-warm is refused deterministically on
    /// the commonest exit, because `stopListening()` does not await `stopStreaming`, so
    /// `activeVoiceOwner` is still `.orb` when `warm()` checks it — leaving the session cold for
    /// good with only an info-level line. Do not add them without solving all three.
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
        // ⚠️ Hold-to-talk keeps the microphone CLOSED at rest — that is the entire point of it
        // being the default. The loop then runs only while the shortcut is held, which is why
        // `beginPushToTalk()` sets `.commandCapture` BEFORE calling this.
        // ⚠️ `.awaitingApproval` while armed belongs here too. Without it, hold-to-talk — the
        // DEFAULT mode — returned immediately from `beginVoiceApproval`'s call, so the approval
        // window opened no microphone at all and spoken approval was simply inert.
        guard OrbConfigManager.shared.activationMode.listensContinuously
                || stage == .commandCapture
                || stage == .followUpWindow
                || (stage == .awaitingApproval && isVoiceApprovalArmed) else {
            // ⚠️ Four callers log a success sentence ("Resuming voice input…") immediately BEFORE
            // calling this. Returning silently made the log positively assert that listening had
            // resumed while no microphone ever opened — the single most misleading line in the
            // subsystem, because it sends a reader looking at CoreAudio.
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
        // [Phase 5] Apple Speech runs an ENTIRELY separate loop. Deliberately an early branch and
        // not an interleaved one: the WhisperKit path below took four phases to get right, and an
        // untested recognizer must not be able to change its behaviour. With the setting on its
        // default this line is the only cost.
        // ⚠️ Re-read on EVERY iteration, not once on entry. `runAppleSpeechSessions` owns its own
        // `while` and returns only on a dispatchable command — so the escape hatch failed exactly
        // when it was needed, with Apple Speech producing nothing usable and the user switching
        // back to WhisperKit to recover.
        if #available(macOS 26.0, *), OrbConfigManager.shared.recognizer.isAppleSpeech {
            // ⚠️ Apple Speech builds its OWN engine through the same builder, and `AVAudioNode`
            // allows one tap per bus. Two input engines on one device is what breaks capture, so
            // the duplex engine must let go before this branch runs — including when the user
            // switches recognizer mid-panel, which this loop re-reads every iteration.
            OrbDuplexAudio.shared.release(reason: "Apple Speech recognizer selected")
            return await runAppleSpeechSessions(generation: generation)
        }
        let service = WhisperRecognitionService.shared
        while !dismissed, generation == listenGeneration {
            // Only the wake-word and capture stages should hold the mic open. Without
            // this, a stage change (profile switch, execution) would leave the loop
            // opening sessions in a stage that has no use for them.
            // ⚠️ `.awaitingApproval` is admitted ONLY while a voice-approval window is armed.
            // The stage itself has no closing edge — a parked run can sit for hours — so an
            // unconditional guard here would hold the microphone open in an empty room.
            guard stage == .passiveListening || stage == .commandCapture || stage == .followUpWindow
                    || (stage == .awaitingApproval && isVoiceApprovalArmed)
                    || (stage == .announcing && narrationListenerAdmissible)
            else { return nil }
            // ⚠️ Hold-to-talk must not drift back into always-open listening. The stage can return
            // to `.passiveListening` while this loop is still running — an expired follow-up
            // window is exactly that path — and without this the microphone would silently stay
            // open for the rest of the session, defeating the whole point of the default mode.
            if !OrbConfigManager.shared.activationMode.listensContinuously,
               stage != .commandCapture, stage != .followUpWindow {
                logger.info("[ORB_SESSION]\(self.tag) Closing the microphone — hold-to-talk has no idle listening.")
                return nil
            }
            guard case .loaded = service.loadingState else {
                setStage(.voiceUnavailable(reason: String(localized: "No speech model is loaded. Download a Whisper model from the composer's voice settings, then retry.")), "runListeningSessions")
                return nil
            }
            // ⚠️ The wake word is English orthography matched as a whole word. A recognizer
            // transcribing another script can never produce a match, and the failure is
            // silent — the orb looks alive and simply ignores the user forever.
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
            // ⚠️ RE-READ THE STAGE. The settle above can take a second, and a push-to-talk key can
            // be released inside it — the release cannot stop a session that has not opened yet,
            // so without this the loop went on to open the microphone for a key nobody is holding.
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
            // ⚠️ The follow-up window is measured from when the microphone is actually LIVE, not
            // from when the answer ended. Declaring it at the end of speech spends its first
            // second inside the settle delay above — deaf — and the user starts talking the
            // moment Orb stops. A 5s window that is really 4s of listening is a window that
            // seems to ignore people.
            if stage == .followUpWindow, let seconds = OrbConfigManager.shared.followUp.seconds {
                followUpDeadline = Date().addingTimeInterval(seconds)
            }
            isSessionActive = true
            startWatchdog()
            logger.info("[ORB_ASR]\(self.tag) Mic session opening in \(Self.name(of: self.stage)) (mode: \(OrbConfigManager.shared.activationMode.rawValue), model: \(service.activeModelName), endpointing: \(String(format: "%.1f", Self.commandSilenceCommit))s).")

            do {
                // Blocks until VAD auto-stop, the watchdog's stopStreaming, or an
                // external stop (model switch in Settings). All paths return here.
                // [V2] `.sessionBusy` (composer/QuickAccess already recording) lands in
                // the catch below → `.voiceUnavailable`, no spin-loop.
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

            // ⚠️ Report the outcome BEFORE the dismissed guard. Same bug class as the dead-mic
            // check: a user who closes the panel because nothing seemed to happen is exactly the
            // case you most need the log for, and `dismissed` short-circuits everything below.
            // Observed 2026-09-04: the service reported "transcript: 15 chars, audio: yes" while
            // Orb logged nothing at all about what it heard.
            let heard = liveTranscript
            logger.info("[ORB_ASR]\(self.tag) Mic session closed after \(String(format: "%.1f", Date().timeIntervalSince(self.sessionStart)))s in \(Self.name(of: self.stage)) — audio: \(self.receivedAudio ? "yes" : "NONE"), heard \(Self.wordCount(heard)) word(s), wake word matched: \(Self.wakeWordRange(in: heard) != nil).")
            logger.debug("[ORB_ASR]\(self.tag) Transcript: \"\(heard)\"")

            guard !dismissed, generation == listenGeneration else { return nil }

            // ⚠️ A NARRATION LISTENER'S AUDIO IS NEVER CLASSIFIED — and this sits BEFORE the dead-
            // audio check on purpose. The listener is closed the instant the answer ends, often
            // before its first buffer, and counting that as a dead microphone would put a false
            // NO AUDIO warning on a healthy orb after every short answer.
            if sessionOpenedDuringNarration {
                sessionOpenedDuringNarration = false
                logger.info("[ORB_ASR]\(self.tag) Narration listener closed (now \(Self.name(of: self.stage))) — its audio is discarded, never classified. CONSEQUENCE: whatever the next stage needs opens a FRESH session with an empty transcript.")
                continue
            }

            // No samples at all → the engine never really started, however long the
            // session appeared to run. Back off and retry; give up with a real message
            // rather than pretending to listen forever.
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

            // ⚠️ Checked BEFORE `.commandCapture`. Inside an armed window the utterance is a
            // decision about a parked tool, never a new request — forwarding it to the model
            // would send "yes" as a prompt and leave the run parked.
            if stage == .awaitingApproval, isVoiceApprovalArmed {
                let spoken = commandPreview
                logger.info("[ORB_ASR]\(self.tag) Approval window heard \(spoken.split(separator: " ").count) word(s).")
                // ⚠️ D-23: silence is not an answer. A session that ended with nothing heard keeps
                // the window listening until its own 30 s expiry, on both recognizers.
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
                    // ⚠️ Audible. This path used to be silent while the tap cancel played an
                    // earcon — and a spoken "stop" that produces no sound reads as "not heard".
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
    ///
    /// Structurally simpler than the WhisperKit one for a real reason: `SpeechAnalyzer` reports
    /// finality explicitly, so there is no stability window to wait out, no 45s session recycle
    /// (nothing re-decodes a growing buffer) and no blocking call to unwind. The 2.2s the
    /// WhisperKit path spends deciding "you stopped talking" simply does not exist here.
    @available(macOS 26.0, *)
    private func runAppleSpeechSessions(generation: Int) async -> String? {
        guard OrbSpeechRecognizer.isAvailable else {
            logger.error("[ORB_APPLE_ASR]\(self.tag) SpeechTranscriber is unavailable on this Mac. CONSEQUENCE: Orb cannot listen in Apple Speech mode — switch the recognizer back to WhisperKit in Developer settings.")
            setStage(.voiceUnavailable(reason: String(localized: "Apple's speech recognizer isn't available on this Mac. Switch the recognizer back to WhisperKit in Orb settings.")), "runAppleSpeechSessions")
            return nil
        }

        while !dismissed, generation == listenGeneration {
            // ⚠️ THE ESCAPE HATCH. Re-read the recognizer every iteration: this loop returns only
            // on a dispatchable command, so with Apple Speech producing nothing usable (the
            // documented degraded-locale mode) it would re-arm forever and switching back to
            // WhisperKit in Settings would never take effect — precisely when the user needs it.
            guard OrbConfigManager.shared.recognizer.isAppleSpeech else {
                // Checked at the TOP of an iteration, so no recognizer exists yet to stop — the
                // previous iteration already tore its own down.
                logger.notice("[ORB_APPLE_ASR]\(self.tag) Recognizer switched away from Apple Speech — leaving the Apple loop. CONSEQUENCE: the caller re-enters and the next session opens on WhisperKit.")
                return nil
            }
            // ⚠️ `.awaitingApproval` is admitted ONLY while a voice-approval window is armed.
            // The stage itself has no closing edge — a parked run can sit for hours — so an
            // unconditional guard here would hold the microphone open in an empty room.
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

            // The synthesizers still hold CoreAudio output until duplex PLAYBACK lands (Phase 4b),
            // so the settle handshake stays. It is not free, but a dead microphone is worse.
            await settleAudioBeforeCapture()
            guard !dismissed, generation == listenGeneration else { return nil }
            // ⚠️ RE-READ THE STAGE. The settle above can take a second, and a push-to-talk key can
            // be released inside it — the release cannot stop a session that has not opened yet,
            // so without this the loop went on to open the microphone for a key nobody is holding.
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
            // ⚠️ The WhisperKit loop sets this and the Apple loop did not, so `sessionStart` was
            // whatever a previous session left behind — and every age-based check below would have
            // measured from the wrong instant.
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

            // The only timers that survive: the capture hard cap, and the follow-up window's own
            // expiry. Everything else the WhisperKit watchdog does exists to compensate for
            // missing finality, which this recognizer supplies.
            let bound = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }

                    // ⚠️⚠️ THE DEAD-MICROPHONE NET, AND IT HAS TO LIVE HERE. This loop has no
                    // passive recycle — `SpeechAnalyzer` needs none — so a passive session with a
                    // wedged input device NEVER ENDS, and a post-session check would never run. The
                    // ticker is the only observer while a session is open, exactly as
                    // `startWatchdog` is on the WhisperKit path.
                    //
                    // ⚠️ Keyed on the TAP, not on transcription: this recognizer reports no buffer
                    // energy, so "no text" is equally consistent with a quiet room. See
                    // `OrbSpeechRecognizer.hasReceivedAudio`.
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

            // ⚠️ The same ladder the WhisperKit loop runs, and it was absent here entirely: warn on
            // the FIRST dead session, keep retrying with escalating backoff, and surface OFFLINE
            // rather than re-arming forever. Without it a wedged input device left the orb on a
            // healthy-looking STANDBY indefinitely — and "Repair Audio…", the only remedy for a
            // wedge that survives relaunching the app, is gated on exactly these two flags, so it
            // was unreachable in the mode where the wedge was happening.
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
                // ⚠️ D-23: silence is not an answer. A session that ended with nothing heard keeps
                // the window listening until its own 30 s expiry, on both recognizers.
                if spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    logger.info("[ORB_ASR]\(self.tag) Approval session ended with nothing heard. CONSEQUENCE: listening again — the window stays open until it expires.")
                    continue
                }
                handleVoiceApprovalUtterance(spoken)
                return nil
            }

            if stage == .commandCapture {
                let command = commandPreview
                // ⚠️ The SAME classifier as the WhisperKit loop. This block was its own copy and had
                // already drifted: its spoken cancel logged nothing and played nothing.
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

                // ⚠️ Detect a dead microphone DURING the session, not only after it returns.
                // Observed 2026-09-04: the engine failed with -10877, WhisperKit's realtime loop
                // kept spinning, and the user closed the panel before `startStreaming` ever
                // returned — so the post-session `!receivedAudio` check was never reached and the
                // orb showed a healthy STANDBY the entire time it was deaf. The watchdog is the
                // ONLY observer running while a session is hung, which makes it the only place
                // this can be caught.
                if !self.receivedAudio, !self.micTroubleDetected, age > Self.deadAudioWarningDelay {
                    self.micTroubleDetected = true
                    self.logger.warning("[ORB_ASR]\(self.tag) No audio after \(String(format: "%.1f", age))s of an OPEN mic session — the engine started but is delivering nothing. CONSEQUENCE: the orb now shows NO AUDIO and offers Repair Audio in its right-click menu; retries continue underneath.")
                }

                // ⚠️ Every `stopStreaming()` below must name its cause. Five distinct endings —
                // silence-commit, empty-capture timeout, the hard cap, follow-up expiry and the
                // passive recycle — used to collapse into one identical "Mic session closed" line,
                // which made a device log unable to answer the first question anyone asks: why did
                // it stop listening?
                @MainActor func endSession(_ cause: String) async {
                    self.logger.info("[ORB_ASR]\(self.tag) Ending the mic session — \(cause). CONSEQUENCE: the session closes and its transcript is classified; the loop decides whether to reopen.")
                    _ = await WhisperRecognitionService.shared.stopStreaming()
                }

                switch self.stage {
                case .commandCapture:
                    // Judged on the NORMALIZED command timeline (see lastCommandChange)
                    // so punctuation/case churn from Whisper's re-decodes can't reset
                    // the window. The hard cap runs on CAPTURE age, not session age.
                    let commandIdle = Date().timeIntervalSince(self.lastCommandChange)
                    let captureAge = Date().timeIntervalSince(self.captureArmedAt)
                    let hasCommand = !self.commandPreview.isEmpty
                    // While the push-to-talk key is HELD, the user is still speaking by
                    // definition — only the hard cap may end the capture. Otherwise a pause for
                    // breath would send half a sentence.
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
                    // ⚠️ WITHOUT THIS CASE THE FEATURE CANNOT WORK. `default: return` exited on the
                    // first tick, so nothing ever ended the mic session — and a one-word "approve"
                    // is only processed once the session closes. The utterance was captured and
                    // then sat there forever.
                    let idle = Date().timeIntervalSince(self.lastCommandChange)
                    let hasWord = !self.commandPreview.isEmpty
                    if hasWord && idle > Self.commandSilenceCommit {
                        await endSession("approval answer stable for \(String(format: "%.1f", idle))s")
                        return
                    }
                    // ⚠️ D-23: NO 8 s empty-capture end here. It made the real window on WhisperKit
                    // 8 s, not the advertised 30 s — silence ended the session and the empty
                    // utterance was read as "not a confirmation". The window's own 30 s expiry
                    // (`readBackAndListen`) closes the microphone.
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
        // ⚠️ A NARRATION LISTENER ACTS ON A STOP PHRASE AND NOTHING ELSE — not the wake word, not
        // the follow-up window, not capture. And once the narration has ended (the session is
        // closing asynchronously) its updates are stale and dropped outright, so nothing heard
        // during the answer can reach a stage that dispatches. See `closeNarrationListener`.
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

        // A spoken cancel aborts the capture rather than becoming the command. Checked before
        // the wake-word arm so it can only ever fire on an ALREADY-armed capture.
        // ⚠️ Multi-word cancels ONLY on this live path. `stopPhrases` are checked when the capture
        // FINISHES (`classifyCapture`): a partial transcript of "stop the server" is a bare "stop".
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

    /// Case- and punctuation-insensitive form used for the stability window. Whisper's
    /// temperature-fallback re-decodes constantly reshuffle punctuation and casing (and
    /// hallucinate filler on steady background noise); comparing this form keeps the
    /// silence-commit timer from resetting on cosmetic churn.
    static func normalizedForStability(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Mishearings to accept alongside a wake word, keyed by that word. A recognizer that never
    /// matches leaves the user with no way to talk to the HUD at all, so matching is deliberately
    /// generous — a false positive only arms command capture, which the user can see and ignore.
    ///
    /// ⚠️ KEYED BY THE WORD, because a homophone list does not survive a rename. When the wake
    /// word changed from a six-letter name to "orb" (2026-09-19) the OLD name's homophones
    /// ("jarvus", "travis", …) rode along untouched — none contained the old name literally, so
    /// no textual sweep could have caught them — and "Travis" armed the orb while "Orba", the
    /// mishearing actually produced that session, did not. Pinned by
    /// `OrbWakeWordTests.testNoHomophoneOfTheOldNameSurvives`.
    ///
    /// ⚠️ ONLY the shipped default has entries, and that is not an omission: these are words a
    /// recognizer was *observed* producing on device, not words derived by rule. A custom wake
    /// word gets none until someone hears one — guessing would widen the match on a hunch.
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

    /// Range of the first accepted wake-word variant in `text`, matched as a WHOLE WORD, if any.
    ///
    /// ⚠️ Never a bare substring. A three-letter wake word matched by substring fires inside
    /// "absorb", "forbid" and "orbit" — and slicing after the substring turned "Orba. Orba."
    /// into the prompt "a. Orba", which the model answered as a question about a puzzle game
    /// (device, 2026-09-19).
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

    /// `command` with every LEADING wake word removed, trimmed of punctuation. Pure.
    ///
    /// ⚠️ Repeated leading wake words are the common case. Observed on device 2026-09-04: Whisper
    /// returned "Orb. Orb, write an essay on technology." — the user said it twice because the
    /// first attempt did not visibly register — and stripping only the first occurrence sent
    /// "Orb, write an essay on technology" to the model. Deliberately LEADING-only: a wake word
    /// later in the sentence is part of the request ("tell Orb about it") and must survive.
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

    /// Phrases that control ORB rather than being sent to the model.
    ///
    /// ⚠️ Matched on the WHOLE normalized utterance, never as a suffix. "repeat the test that
    /// failed" is a request for the model; only a bare "repeat that" is a command. Swallowing a
    /// real request because it happens to contain a control word is far worse than missing one.
    // ⚠️ "read me the answer" is a REPEAT phrase, not a fourth command. The report's answer row is
    // a 160-character preview; the message itself is the whole answer, and `repeatLastAnswer`
    // already narrates it properly. A separate command would read the user a truncated copy.
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

    /// Appended to the query the MODEL sees when the answer will be read aloud.
    ///
    /// ⚠️ ONLY THE MODEL'S COPY IS DECORATED. The hint travels as `promptOverride`, declared at
    /// `startMessageStream`; the message `voiceTurn` builds and persists carries the clean
    /// command, so the chat window, the sidebar and the conversation history all show exactly what
    /// the user said. Without this the model answers in markdown with bullet lists and fenced
    /// code — the right shape for a screen and the wrong shape for a voice.
    ///
    /// ⚠️ This said "only the `userQuery` argument is decorated. `createUserMessage` still
    /// persists the clean command" — the shape before 2026-09-06, when the divergence was an
    /// UNDECLARED mismatch between `userQuery` and the row in `history`. That mismatch is exactly
    /// what defeated the duplicate-query strip (it compared TEXT) and made every voice turn reach
    /// the model as an orphan marked "Agent never responded to this query". Decorating anything
    /// other than the override — the persisted row above all — brings that back.
    /// ⚠️ THE LENGTH REQUEST MOVES WITH THE SETTING. A sentence cap can only TRUNCATE; it cannot
    /// make the model concise. "Just the gist" implemented as a smaller cap over the same
    /// six-sentence request would end every turn in "there's more in the chat window" — the exact
    /// failure that forced the automatic cap up from 4 to 6 after the 2026-09-04 device test.
    /// Asking for the length you intend is what makes brevity a choice rather than a severed
    /// sentence.
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

    /// The two halves of a voice turn: the message that is PERSISTED and DISPLAYED, and the
    /// model-facing text when it must differ from it.
    ///
    /// ⚠️ THE ID IS THE CONTRACT. The chat window shows the clean spoken command; the model gets
    /// the command plus a spoken-style hint. Those are two different STRINGS that must remain ONE
    /// message — `BackendOrchestrationService` strips the current question out of history by ID,
    /// and if the persisted row and the row handed to the send path were ever different objects
    /// the strip would miss, the question would survive into the blob, and `pairTurns` would emit
    /// it as an orphan marked "Agent never responded to this query". That is exactly the defect
    /// every voice turn shipped with while the strip compared TEXT.
    ///
    /// `promptOverride` is nil when the decoration is a no-op (`.preferSilent`), so a divergence
    /// exists in the type only when it exists in fact.
    ///
    /// `static` + internal so the contract is testable without a `MainApplicationViewModel` —
    /// constructing one runs `ChatOpsCoordinator.bootstrap()`, which opens real Telegram/Discord/
    /// Slack connections when the developer has them enabled. Same reason
    /// `SchedulerCoordinator.prepareScheduledRequest` and `MessagingCoordinator.deliverCheckpoint`
    /// are extracted. Pinned by `OrbDispatchTests`.
    ///
    /// - Parameter fileProcessorService: only reached for attachments, and a voice turn never has
    ///   any (`files: []`) — required by the shared factory, unused on this path.
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

    /// Whether the configured ASR language can EVER produce a wake-word match. Pure.
    ///
    /// ⚠️ `wakeWordVariants` is English orthography matched case-insensitively as whole words, and
    /// the ASR language is the composer's shared `AppSettings.speechLanguageKey`. Set it to a
    /// non-Latin-script language and the recognizer returns text no variant can match — the orb
    /// looks alive and simply never responds, with no error logged anywhere. Callers must fall
    /// back to click-to-speak rather than leaving the user with no way in.
    static func wakeWordCanMatch(language: String?) -> Bool {
        guard let language, !language.isEmpty else { return true }   // unset ⇒ auto-detect
        return language.lowercased().hasPrefix("en")
    }

    /// The phrase spoken when a run ends. Pure — the honesty guarantee for a voice-only user.
    ///
    /// ⚠️ Only `.cancelled` used to be branched, so `.failed` and `.completedWithWarnings` both
    /// announced "Your task is completed". Because the reply itself is not spoken yet, this
    /// phrase is the ONLY channel a voice-only user has, and it was reporting success on runs
    /// that had errored out or been truncated by the circuit breaker.
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
            // ⚠️ The offer, not a trace fetch. Loading the run here would leave the orb silent in
            // `.announcing` for an unmeasured interval on the one path where the user most needs
            // an immediate answer. `what went wrong` does the work, on request.
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
        /// Parked on a request whose spoken window has closed: the press re-opens THAT window
        /// (read-back, then a fresh 30 s to answer) instead of capturing a new command (D-23).
        case reopenVoiceApproval
    }

    /// ⚠️⚠️ `.welcoming` IS ADMITTED, AND IT IS THE COMMON CASE — NOT AN EDGE ONE.
    ///
    /// `AppDelegate.orbPushToTalkDown` opens the panel and arms capture in ONE gesture:
    /// `show()` then `beginPushToTalk()`, consecutive statements. `show()` runs `begin()`
    /// SYNCHRONOUSLY, and `begin()` resolves the remembered profile straight into `selectProfile`,
    /// which sets `.welcoming` on its first line. So the stage this method sees on a cold open is
    /// never `.passiveListening` — it is `.welcoming`, which the old guard rejected silently.
    /// Hold-to-talk is the DEFAULT activation mode and this shortcut is its only way in, so every
    /// cold open lost the whole first utterance and logged nothing explaining it.
    ///
    /// A held push-to-talk key is an explicit "I want to talk now", which outranks the greeting.
    /// - Parameter canReopenApproval: the run is parked on a request that can be answered by voice
    ///   and no window is armed. ⚠️ D-23: once the 30 s window closed there was no way back to the
    ///   voice channel — every press was refused as "a turn is already in flight".
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
            // ⚠️ `pushToTalkHeld` stays false: the window runs on its own clock, and the key-up must
            // not treat this as a command capture.
            if let token = reopenableApprovalToken() { reopenVoiceApproval(token, via: "push-to-talk") }
            return
        case .refuse(let reason):
            // ⚠️ Never silent. The old guard returned with no line at all, so a device log of the
            // most common failure in the subsystem contained nothing that even mentioned the press.
            logger.info("[ORB_SESSION]\(self.tag) Push-to-talk pressed in \(Self.name(of: self.stage)) — \(reason). CONSEQUENCE: this press raises the orb but captures NOTHING; nothing spoken while it is held will be heard.")
            return
        case .cutGreetingAndArm:
            // ⚠️ ORDER, AND IT IS THE SAME ORDER `teardown()` DOCUMENTS: drop the hand-back before
            // stopping the synthesizer. `voice.stop()` cancels the pending completion so
            // `didFinish` never drains it, and the 20 s watchdog would otherwise fire into a turn
            // that has moved on — dragging the user out of a capture that is already running.
            //
            // ⚠️ On a cold open the greeting has not STARTED yet: this method runs synchronously
            // after `show()`, before `selectProfile`'s Task gets to speak. `pushToTalkHeld` is
            // what stops that Task, so it must be set — see the guard in `selectProfile`.
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
            // ⚠️ Also never silent. A release that commits nothing is the second half of the
            // same invisible failure: the press was refused, so there is no capture to end.
            logger.info("[ORB_SESSION]\(self.tag) Push-to-talk released in \(Self.name(of: self.stage)) with no capture armed. CONSEQUENCE: nothing is sent — whatever was said while the key was held was never being recorded.")
            return
        }
        logger.info("[ORB_SESSION]\(self.tag) Push-to-talk released — committing \(Self.wordCount(self.commandPreview)) word(s).")
        if isSessionActive {
            Task { _ = await WhisperRecognitionService.shared.stopStreaming() }
        } else {
            // ⚠️ THE SESSION HAS NOT OPENED YET. `isSessionActive` is not set until after the
            // permission check and the 1 s settle, so a tap released inside that window stopped
            // NOTHING and the loop went on to open the microphone for a key that was no longer
            // held — in the one mode whose entire contract is a closed mic at rest.
            logger.info("[ORB_SESSION]\(self.tag) Released before the session opened — abandoning the capture rather than opening the microphone for a key that is no longer held. CONSEQUENCE: nothing is captured or sent; the orb returns to standby.")
            manualCaptureBaseline = nil
            setStage(.passiveListening, "endPushToTalk")
        }
    }

    /// Click-to-speak: arms command capture without the wake word, mid-session.
    /// The safety net for when Whisper never renders the wake word recognizably.
    func armManualCapture() {
        // ⚠️ `!dismissed` — see `beginPushToTalk`, which has always had it. A view can outlive the
        // teardown that closed its panel (an in-flight gesture, a retained hosting view), and
        // `setStage` now has a SIDE EFFECT: entering `.voiceUnavailable` releases the app-scoped
        // audio engine. A dead controller reaching that would release an engine a NEW panel had
        // warmed. Nothing does today; the guard is what keeps that true.
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
        // ⚠️ The loop is NOT running at rest in hold-to-talk — the default mode. Without this a
        // click gave a hot-mic orb, a listening earcon and a dead microphone, escapable only by
        // right-click Cancel. `startListeningLoop` is a no-op when a loop is already live, so the
        // wake-word mode is unaffected.
        startListeningLoop()
    }

    /// Discards an armed capture WITHOUT sending it and returns to wake-word scanning.
    ///
    /// ⚠️ There was no abort path at all: `commitCaptureNow()` sends, and nothing cancelled.
    /// A user watching a mis-transcription had no way to stop it reaching a profile with shell
    /// and filesystem tools. The session is ended too, so the discarded speech cannot leak into
    /// the next command through WhisperKit's cumulative transcript.
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

        // Re-applied every turn, not only at conversation creation: the setting can change while
        // the orb is open, and a stale autonomous grant is exactly the kind of invisible state
        // this feature must not have.
        let approvals = OrbConfigManager.shared.toolApprovals
        logger.info("[ORB_RUN]\(self.tag) Dispatching \(Self.wordCount(command)) word(s) to \"\(config.profile.displayName)\" (approvals: \(approvals.rawValue), conv \(convID.uuidString.prefix(8))).")
        Task { await SessionToolApprovals.shared.setAutonomous(approvals.isAutonomous, conversationID: convID, origin: .orb) }
        observeInteractions()
        // Bind the profile so restart-resume, ChatOps, and the sidebar all resolve it.
        persistence.updateBackendForConversation(
            id: convID, backendType: nil, backendEntityId: config.profile.id
        )

        // Best of both worlds: the orb stays wordless while the actual run — streamed
        // text, tool timeline, and any HITL banner — plays out in the real chat
        // interface behind the panel. Reuses the existing notification the QuickAccess
        // handoff posts, which MainApplicationView already observes.
        NotificationCenter.default.post(
            name: GlobalConstants.openConversationNotification,
            object: nil,
            userInfo: ["conversationID": convID.uuidString]
        )

        // Both halves built together so the persisted row and the model's copy cannot drift
        // apart — see `voiceTurn`. A voice turn carries no attachments, so the factory's
        // file-processing dependency is never exercised here.
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

        // Identity guard for the completion closure: onComplete fires on EVERY
        // termination (success, error, cancel) — a stale stream's late completion
        // must not clobber a newer one's state. Captured var is filled right after
        // the call returns (streaming starts in an internal Task, so no race).
        var thisStreamID: UUID?
        // Workflow bookkeeping. ⚠️ Currently ALWAYS nil here: the profile picker filters to
        // `.bot`/`.agent` (:178, :257), so a workflow cannot be selected by voice. Kept for a
        // uniform call shape across every `startMessageStream` site — see the QuickAccess twin.
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
            // ⚠️ The MODEL sees a decorated query; the persisted user message above is the clean
            // command, so the chat window shows exactly what was said. `promptOverride` DECLARES
            // that divergence — it used to be an undeclared mismatch between `userQuery` and the
            // message in `history`, which is precisely what defeated
            // `BackendOrchestrationService`'s duplicate-query strip (it compared TEXT) and made
            // every voice turn arrive as an orphan marked "Agent never responded to this query".
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
        // Narrate as it streams. ⚠️ For `.agent` profiles the executor emits the whole answer as
        // ONE content event, so this degrades to speak-on-completion — correct, but the reason
        // agent answers feel less live than bot answers.
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

    /// Where a turn ends: the follow-up window if the user enabled one, otherwise wake-word
    /// standby — or, in hold-to-talk, a closed microphone.
    ///
    /// The follow-up window is what makes this feel like a conversation: re-uttering the wake word
    /// before every sentence is the most conspicuous thing that separates a voice TRIGGER from a
    /// voice assistant.
    private func returnToListening() {
        guard !dismissed else { return }
        // ⚠️ HOLD-TO-TALK GETS NO FOLLOW-UP WINDOW. The activation row promises "keeps the
        // microphone closed until you press it", and that promise is the whole reason the mode
        // exists and is the default on a laptop. A 5 s hot window after every answer — with the
        // orange indicator lit and nothing held down — contradicts it on every single turn. Two
        // defaults that were each defensible alone combined into a claim the app did not honour;
        // the privacy promise is the one that wins.
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

    /// How long the follow-up window should stay open after an answer, or nil for none. Pure, so
    /// the product promise it encodes can be pinned by a test.
    ///
    /// ⚠️ Hold-to-talk always returns nil. The activation row promises "keeps the microphone
    /// closed until you press it"; a 5 s hot window after every answer — orange indicator lit,
    /// nothing held down — is the opposite of that, and it was the shipped default.
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

    /// [Phase 6 · F1] What the user asked about the run that just finished.
    private enum RunNarration {
        case problems
        case changes
    }

    /// Answers a question about the last run, out loud.
    ///
    /// ⚠️ EVERY exit path must speak. `perform` is synchronous and the trace fetch is not, so this
    /// enters `.announcing` immediately and hands back from inside the task — a path that returns
    /// without speaking leaves the stage with no closing edge and the orb parked forever.
    private func narrateRun(_ kind: RunNarration) {
        guard !dismissed else { return }
        let handBack: () -> Void = { [weak self] in self?.returnToListening() }

        guard let message = currentAgentMessage else {
            setStage(.announcing, "narrateRun")
            speakWithWatchdog(String(localized: "There's no run for me to look at yet."), then: handBack)
            return
        }

        // ⚠️ `.executing`, NOT `.announcing`, for the fetch. `handleRunFinished` explicitly refuses
        // to do a trace read inside `.announcing` — that stage's only closing edge is
        // `speakWithWatchdog`, which cannot be armed until there is something to say, so the whole
        // fetch window sat unwatched while the orb claimed to be speaking. `.executing` also keeps
        // the loop from opening a microphone underneath it.
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
            // ⚠️ Barge-in must win. The user hears silence during the fetch and clicks the orb;
            // without this the narration then starts anyway, over an interrupt they just made.
            guard !self.dismissed, self.stage == .executing else {
                self.logger.info("[ORB_SESSION]\(self.tag) Run narration abandoned — the stage moved to \(Self.name(of: self.stage)) while the trace was loading (a barge-in or a new turn). CONSEQUENCE: nothing is spoken, which is what the interrupt asked for.")
                return
            }
            self.logger.info("[ORB_SESSION]\(self.tag) Run narration (\(String(describing: kind))): \(sentence.count) character(s) spoken.")
            self.setStage(.announcing, "narrateRun")
            self.speakWithWatchdog(sentence, then: handBack)
        }
    }

    /// Speaks whatever a length setting held back from the last answer.
    ///
    /// ⚠️ Every exit speaks. Saying nothing here is indistinguishable from the command not being
    /// recognised, and this is the command a user reaches for precisely because they did not get
    /// enough the first time.
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
    ///
    /// ⚠️ Called wherever a CAPTURE is armed — wake word, click, push-to-talk, follow-up — so the
    /// lines describing why a turn never dispatched are filed under that turn rather than under
    /// the previous one. `execute()` reuses whatever this set; it does not stamp its own.
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
    ///
    /// Reached by a TAP always, and by VOICE when echo cancellation is live — a narration listener
    /// hears a stop phrase (`openNarrationListenerIfAdmissible`). Without AEC the microphone stays
    /// closed while Orb speaks, and a click is the only way to cut a long answer short.
    /// ⚠️ Until 2026-09-27 this said it was tap-only pending AEC. AEC had been live on hardware
    /// since 2026-09-05; nothing had admitted the listening loop to `.announcing`.
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

    /// Watches the shared HITL queue for a park on THIS conversation.
    ///
    /// ⚠️ Without this the feature deadlocks. An agent run that parks for approval never fires
    /// `onComplete`, so `handleRunFinished` never runs, the stage stays `.executing`, and the
    /// listening loop has already returned with the microphone closed — the orb showed THINKING
    /// forever and only closing the panel recovered. Re-arms BEFORE handling, because
    /// `withObservationTracking` is one-shot and a second park enqueued during the handler would
    /// otherwise go unobserved.
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
                // ⚠️ STOP OBSERVING WHEN NOTHING IS BOUND, and stop BEFORE the re-arm.
                //
                // The tracking re-arms itself, so it outlives the conversation it was armed for:
                // "new conversation" and a profile switch both clear `orbConversationID` while
                // leaving this loop running. Every HITL raised anywhere in the app then woke a
                // handler with nothing to do — which used to emit an ERROR claiming a parked run
                // would hang the orb, on a session that had no run at all.
                //
                // Dropping the re-arm here is safe because `execute()` arms it on every dispatch,
                // after `ensureConversation` — so the next turn restores it, and until then this
                // costs nothing.
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
        // ⚠️ Only the missing centre is an ERROR. A nil conversation is the ordinary state between
        // turns and is now filtered before the re-arm above; it reaches this guard only if a future
        // caller bypasses that path, so it is reported without claiming a run is hanging. The old
        // line asserted "a parked run will NOT be surfaced… it shows THINKING until the panel is
        // closed" for BOTH cases — false for the common one, and at error level, which sent readers
        // hunting a deadlock that did not exist.
        guard let center = mainVM?.interactionCenter else {
            logger.error("[ORB_HITL]\(self.tag) Interaction change ignored — the interaction centre is unavailable. CONSEQUENCE: a parked run will NOT be surfaced on the orb; it shows THINKING until the panel is closed.")
            return
        }
        guard let convID = orbConversationID else {
            logger.debug("[ORB_HITL]\(self.tag) Interaction change ignored — no conversation is bound. CONSEQUENCE: none; there is no Orb run that could have parked.")
            return
        }
        guard let pending = center.current(for: convID) else {
            // ⚠️ NOT JUST `.awaitingApproval`. The unrecognised-utterance path spends a second in
            // `.announcing` saying "I'll leave that one on screen" and then returns to
            // `.awaitingApproval` — so a request answered on screen during that phrase skipped
            // this branch entirely, leaving `announcedInteractionID` set and the panel collapsed
            // into an approval layout with nothing pending.
            if stage == .awaitingApproval || (stage == .announcing && announcedInteractionID != nil) {
                logger.info("[ORB_HITL]\(self.tag) Request resolved — the run continues.")
                // ⚠️ The user may have clicked the banner while the spoken window was open. A
                // still-armed window would leave a "yes" pointing at a resolved operation.
                disarmVoiceApproval(reason: "request resolved elsewhere")
                announcedInteractionID = nil
                setStage(.executing, "HITL resolved")
            }
            return
        }
        // ⚠️⚠️ #9 — THE ARM MUST FOLLOW THE QUEUE. Disarming only when the queue went EMPTY meant
        // that if the armed operation resolved while another request was already queued,
        // `current(for:)` returned the NEW one, the empty branch never ran, and
        // `voiceApprovalOperationID` kept pointing at the resolved operation — with the mic still
        // open. A spoken "approve" then committed an operation that was already answered, while a
        // completely different request sat on screen. Nothing else compares these two ids.
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
        // ⚠️ Say that approval is NEEDED, never the arguments. The user must READ what they are
        // approving — a spoken paraphrase of a shell command is exactly how a misheard approval
        // becomes an executed one.
        // ⚠️ The hand-back is NOT empty. An empty closure here leaves `.awaitingApproval` with no
        // closing edge: today the microphone is closed in that stage so nothing is stranded, but
        // the moment duplex listening reaches it (Phase 4) nothing would ever close the mic —
        // which is the parked-forever shape the HITL observer exists to prevent. Logging the edge
        // also makes "the prompt finished speaking" visible in a log-only device test.
        // [Phase 6 · F2] A spoken approval is offered ONLY when the user switched the channel on
        // AND the policy produced a token. Everything else keeps the original behaviour: say that
        // approval is needed, name nothing, and leave it on screen.
        let voiceToken = OrbConfigManager.shared.voiceApprovals
            ? OrbApprovalPolicy.token(for: pending)
            : nil

        // ⚠️ [#13] A SECOND PARK CUTS THE FIRST PROMPT OFF, and that is correct — but it must not
        // be silent. This branch is only reached when `announcedInteractionID != pending.id`, i.e.
        // the request the in-flight phrase describes has ALREADY been resolved, so finishing the
        // sentence would announce something that is no longer on screen. `speakWithWatchdog`
        // overwrites `pendingSpeechCompletion`, dropping the first prompt's hand-back — which is
        // also right here, because that hand-back would arm a voice window for a resolved
        // operation. What was wrong was that the user heard half a sentence with nothing in the
        // log to explain it.
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
    ///
    /// Short on purpose. This is the window in which an open microphone can commit an action, so
    /// it is sized for a person who is present and listening — not for one who wandered off.
    private static let voiceApprovalWindow: TimeInterval = 30

    /// Reads back what would run, then opens a bounded window for a spoken confirmation.
    ///
    /// ⚠️ TWO-STAGE BY CONSTRUCTION. The first utterance (the prompt) names the tool and its
    /// arguments; only the SECOND one commits. A single-stage "say yes to approve" would let one
    /// misheard word authorize something the user never heard described.
    private func beginVoiceApproval(_ token: OrbApprovalPolicy.VoiceApproval) {
        voiceApprovalToken = token
        logger.notice("[ORB_HITL]\(self.tag) Voice approval ARMED for op \(token.operationID.uuidString.prefix(8)) (\(token.toolName)), \(Int(Self.voiceApprovalWindow))s window. CONSEQUENCE: a spoken confirmation can approve THIS operation until the window closes; nothing else.")
        readBackAndListen(token, repeated: false)
    }

    /// Speaks the read-back and re-opens the window's microphone and its expiry.
    ///
    /// ⚠️ ONE ROUTINE FOR BOTH THE FIRST READING AND A REPEAT, so the sentence that authorizes a
    /// tool cannot be worded two ways. A user who asks "what is it again?" must hear the SAME
    /// arguments in the same order — a second, separately-built sentence is a second chance to
    /// describe the operation differently from the one that will actually run.
    private func readBackAndListen(_ token: OrbApprovalPolicy.VoiceApproval, repeated: Bool) {
        voiceApprovalTask?.cancel()
        let keywords = OrbConfigManager.shared.resolvedApprovalKeywords
        speakWithWatchdog(Self.approvalReadBack(token: token, keywords: keywords)) { [weak self] in
            guard let self, !self.dismissed else { return }
            // ⚠️ Deferred to the speech hand-back for a REASON on the repeat path: a repeat is
            // requested from inside `runListeningSessions`, so `listenTask` is still non-nil at
            // that moment and `startListeningLoop` would silently no-op. By the time the phrase
            // has finished the loop has unwound and cleared it.
            self.startListeningLoop()
        }

        // The clock restarts with the reading. A user who just asked what the operation was should
        // get a full window to answer in, not the remainder of the one they spent asking.
        voiceApprovalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.voiceApprovalWindow * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isVoiceApprovalArmed else { return }
            self.disarmVoiceApproval(reason: repeated ? "window expired after a repeat" : "window expired")
            // ⚠️ D-23: no answer is NOT a denial — the request stays open on screen (HITL is
            // unbounded). What was missing was saying so, and a way back: the orb sat in
            // `.awaitingApproval` with a closed mic and refused every press. It stays in that stage
            // (releasing the duplex engine there is unsafe), but a press or click re-opens the window.
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

    /// The sentence spoken before a voice approval can commit. Pure.
    ///
    /// ⚠️ IT NAMES THE USER'S REAL KEYWORDS. Hard-coding "say yes" while the user has configured
    /// something else is the one bug that makes this feature simply not work — and it would look
    /// like the microphone failing, not like a wrong word.
    static func approvalReadBack(token: OrbApprovalPolicy.VoiceApproval,
                                 keywords: (approve: [String], deny: [String], problems: [OrbApprovalKeywords.Problem])) -> String {
        let approveWord = keywords.approve.first ?? OrbApprovalKeywords.approveDefault
        let denyWord = keywords.deny.first ?? OrbApprovalKeywords.denyDefault
        return String(localized: "That's \(OrbApprovalPolicy.spokenToolName(token.toolName)), \(token.spokenArguments). Say \(approveWord) to go ahead, or \(denyWord) to skip it.")
    }

    /// ⚠️ Closes the microphone's only reason to be open in this stage. Every exit from the
    /// window — approved, refused, unrecognised, expired, resolved elsewhere — goes through here.
    /// ⚠️ ALWAYS closes the microphone. The armed window is the ONLY reason `.awaitingApproval`
    /// holds a session open, so disarming without stopping left a live decoder with nothing that
    /// could end it: the session watchdog has no `.awaitingApproval` case once the window is gone,
    /// and WhisperKit's VAD auto-stop needs confirmed text, which a silent room never produces.
    /// The expiry path always did this; every other exit did not.
    private func disarmVoiceApproval(reason: String) {
        guard voiceApprovalToken != nil else { return }
        voiceApprovalToken = nil
        voiceApprovalTask?.cancel()
        voiceApprovalTask = nil
        logger.info("[ORB_HITL]\(self.tag) Voice approval DISARMED (\(reason)) — closing the microphone it opened. CONSEQUENCE: a spoken keyword no longer approves anything; the request stays on screen unless it was answered.")
        stopListening()
    }

    /// Handles what the user said inside an armed approval window.
    ///
    /// ⚠️ FAILS CLOSED, AND DENYING IS ALSO AN ACTION. Anything that is not an unambiguous
    /// confirmation leaves the request PENDING on screen rather than denying it — a misheard
    /// denial would cancel work the user wanted, which is a different harm, not a safer one.
    /// Only an explicit cancel phrase denies.
    private func handleVoiceApprovalUtterance(_ spoken: String) {
        guard let operationID = voiceApprovalOperationID else {
            logger.info("[ORB_HITL]\(self.tag) Heard \(spoken.split(separator: " ").count) word(s) just after the approval window closed. CONSEQUENCE: they were discarded — nothing was approved or denied, and the request is still on screen.")
            return
        }
        let keywords = OrbConfigManager.shared.resolvedApprovalKeywords

        // ⚠️ DENIAL IS CHECKED FIRST. If a word somehow reaches both lists, the safe reading of an
        // ambiguous instruction to run a tool is "don't" — and `resolve` has already stripped
        // collisions out of the approve list for the same reason.
        if OrbApprovalPolicy.isDenial(spoken, keywords: keywords.deny) || Self.isCancelPhrase(spoken) {
            disarmVoiceApproval(reason: "spoken denial")
            submitHITL("Voice DENIED", operationID: operationID,
                       consequence: "the tool does not run and the agent is told the user refused.") {
                $0.submitToolApproval(operationID: operationID, approved: false)
            }
            setStage(.executing, "voice approval denied")
            return
        }

        // ⚠️ THE GRAMMAR, FOR A QUEUE OF EXACTLY ONE. `queueSize: 1` is not a placeholder — F2
        // arms one operation at a time by construction, and `ordinals` DROPS out-of-range
        // positions rather than clamping them, so "approve three" here parses to nothing rather
        // than quietly becoming "approve the only one". The bare keyword still commits through
        // `isConfirmation` below; this only adds a TARGET to the same vocabulary, so a user who
        // changed their commit word changes this too.
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
            // ⚠️ Re-reads and STAYS ARMED. This is the one branch that must not fail closed: a
            // user who did not catch the arguments is the user least able to make the decision,
            // and disarming here would answer "what was that?" by silently closing the channel.
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

    /// ⚠️⚠️ THE ONLY PATH FROM SPEECH TO AN APPROVAL, and it is reachable only from
    /// `handleVoiceApprovalUtterance`, which is reachable only from an armed window, which is
    /// armed only when `OrbApprovalPolicy` produced a token. Do not add another caller.
    ///
    /// ⚠️ It calls `submitToolApproval` — a ONE-SHOT resolution — and never
    /// `SessionToolApprovals.allow`. A durable "allow for this chat" grant created from a
    /// misheard word would survive the conversation AND the app restart, which is precisely the
    /// harm this whole channel is shaped to avoid.
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

    /// `fs_smart_search` reads as "fs smart search", not "fs underscore smart underscore search".
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

    // ⚠️ The section header called these "audit-logged" and none of them logged. The decision does
    // survive downstream (`MessagingCoordinator` logs the submission), but with no `[s:…]` tag and
    // no record of WHICH SURFACE answered — so a log could not tell an orb click from a
    // main-window click from a spoken approval, which is the first question about any approval.

    /// Routes a HITL decision to the view model, or reports that it went NOWHERE.
    ///
    /// ⚠️ THE LINES ABOVE EACH CALL SITE ALREADY STATED AN OUTCOME — "the tool runs once", "the run
    /// resumes with this text in context" — and were emitted BEFORE a bare `mainVM?.submitX(…)`
    /// with no else branch. When that weak reference is nil the submission never happens, so the
    /// log did not merely go quiet: it asserted a result that did not occur. A log that lies is
    /// worse than one that is missing, because it ends the investigation.
    ///
    /// Every decision now routes through here, so the claim is only made once the submission is
    /// actually going out, and a new decision kind cannot reintroduce the silent path.
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
        // ⚠️ Length only — the answer is free text the user typed and re-enters the agent's context.
        submitHITL("Answered clarification from the orb with \(trimmed.count) character(s)\(trimmed.isEmpty ? " (empty — treated as no answer)" : "")",
                   operationID: pending.id,
                   consequence: "the run resumes with this text in context.") {
            $0.submitClarificationResponse(operationID: pending.id, response: trimmed.isEmpty ? nil : trimmed)
        }
    }

    func resolvePlan(_ pending: PendingHITL, approved: Bool) {
        guard case .planReview(let plan) = pending.kind else {
            // ⚠️ This dropped the click with no line ANYWHERE. The pending item can be replaced
            // between the render and the tap, and the button then simply does nothing — which
            // reads as a dead button, not as a race.
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

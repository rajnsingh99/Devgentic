//
//  JarvisSessionController.swift
//  Devgentic
//
//  [Jarvis MVP] The brain of the voice HUD: stage machine, wake-word listening loop,
//  and the send pipeline. Sends ride the EXACT same path as a chat-interface send —
//  the QuickAccess panel's blueprint (createUserMessage → persistence.addMessage →
//  ActiveStreamManager.startMessageStream with a per-call BackendRequestConfig) —
//  so a Jarvis run is indistinguishable from a typed chat turn downstream.
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
import AVFoundation
import Observation

// MARK: - Stage

enum JarvisStage: Equatable {
    /// Pick which Bot/Agent profile powers the session (always asked on open).
    case selectingProfile
    /// Greeting TTS is playing.
    case welcoming
    /// Wake-word scan — say "Jarvis" to arm command capture.
    case passiveListening
    /// Wake word heard; capturing the command until the user stops talking.
    case commandCapture
    /// A run is streaming through the chat pipeline.
    case executing
    /// Completion TTS is playing.
    case announcing
    /// Voice input can't run (no model / mic denied / session failure).
    case voiceUnavailable(reason: String)
}

// MARK: - Controller

@MainActor @Observable
final class JarvisSessionController {

    // MARK: Tunables

    static let wakeWord = "jarvis"
    static let completionPhrase = "Your task is completed, let me know next"
    /// Command considered final after this much NORMALIZED-command stability (VAD's
    /// own 1.5s auto-stop usually wins when WhisperKit has confirmed segments).
    private static let commandSilenceCommit: TimeInterval = 2.2
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
    private static let profileMemoryKey = "jarvisProfileID"

    /// CoreAudio settle time before opening the mic. AVSpeechSynthesizer's output
    /// context is torn down asynchronously AFTER its didFinish delegate fires, so
    /// starting AVAudioEngine too soon races that teardown and the HAL refuses the
    /// device (`-10877`, `_StartIO ... error 35`). WhisperKit swallows that failure,
    /// so the session "succeeds" with a dead mic. Paired with
    /// `JarvisVoiceOutput.releaseAudio()`, which deallocates the synthesizer first.
    private static let audioSettleDelay: TimeInterval = 1.0
    /// Consecutive dead sessions before surfacing voiceUnavailable instead of retrying.
    private static let maxDeadSessions = 4

    // MARK: Observable state (drives the HUD)

    private(set) var stage: JarvisStage = .selectingProfile
    private(set) var liveTranscript: String = ""
    private(set) var energyLevels: [Float] = []
    private(set) var profiles: [BackendProfileModel] = []
    private(set) var selectedProfile: BackendProfileModel?
    private(set) var currentAgentMessage: ChatMessage?
    /// The profile remembered from the last Jarvis session (pre-highlighted in the picker).
    private(set) var rememberedProfileID: UUID?

    /// The command as it stands right now: everything spoken after the wake word, or —
    /// when capture was armed by clicking — everything spoken after the arm point.
    var commandPreview: String {
        if let baseline = manualCaptureBaseline {
            return Self.strippingPrefix(baseline, from: liveTranscript)
        }
        return Self.extractCommand(from: liveTranscript)
    }

    /// Normalized 0…1 audio level for the core visual.
    var audioLevel: CGFloat {
        guard let last = energyLevels.last else { return 0 }
        return CGFloat(min(1.0, max(0.0, last / 0.25)))
    }

    /// Pending HITL for the Jarvis conversation (agent profiles can park mid-run).
    var pendingInteraction: PendingHITL? {
        guard let convID = jarvisConversationID, let center = mainVM?.interactionCenter else { return nil }
        return center.current(for: convID)
    }

    var isExecuting: Bool { streamingMessageID != nil }

    // MARK: Private state

    @ObservationIgnored private weak var mainVM: MainApplicationViewModel?
    @ObservationIgnored private let backendConfiguration = BackendConfiguration()
    @ObservationIgnored private let voice = JarvisVoiceOutput()
    @ObservationIgnored private let logger = DGLogger(category: "JarvisSession")

    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var isSessionActive = false
    @ObservationIgnored private var sessionStart = Date()
    @ObservationIgnored private var lastTranscriptChange = Date()
    @ObservationIgnored private var dismissed = false

    @ObservationIgnored private var jarvisConversationID: UUID?
    @ObservationIgnored private var transcript: [ChatMessage] = []   // oldest-first
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
    }

    /// True when a previously-chosen profile still resolves. Drives the "ask once,
    /// then go straight to the orb" behavior: the picker is a first-run step only.
    var hasRememberedProfile: Bool { Self.rememberedProfile() != nil }

    private static func rememberedProfile() -> BackendProfileModel? {
        guard let idString = UserDefaults.standard.string(forKey: profileMemoryKey),
              let id = UUID(uuidString: idString),
              let profile = try? BackendProfileStore.shared.fetchProfile(byId: id),
              profile.profileType == .bot || profile.profileType == .agent
        else { return nil }
        return profile
    }

    func begin() {
        loadProfiles()
        // Remembered profile → skip the picker entirely and start listening.
        // A deleted/renamed-away profile falls back to the picker rather than failing later.
        if let remembered = Self.rememberedProfile() {
            logger.info("Jarvis resuming with remembered profile \"\(remembered.displayName)\".")
            selectProfile(remembered)
        } else {
            stage = .selectingProfile
        }
    }

    /// Config-bubble action: return to the picker. Stops the voice loop and any run
    /// first so the new profile starts from a clean session.
    func requestProfileSwitch() {
        guard stage != .selectingProfile else { return }
        stopListening()
        if let id = streamingMessageID {
            mainVM?.activeStreamManager.cancelStream(for: id)
            streamingMessageID = nil
        }
        voice.stop()
        loadProfiles()
        stage = .selectingProfile
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
        listenGeneration &+= 1
        watchdogTask?.cancel()
        watchdogTask = nil
        listenTask?.cancel()
        listenTask = nil
        voice.stop()
        if isSessionActive {
            Task { _ = await WhisperRecognitionService.shared.stopStreaming() }
            isSessionActive = false
        }
        if let id = streamingMessageID {
            mainVM?.activeStreamManager.cancelStream(for: id)
            streamingMessageID = nil
        }
        if let convID = jarvisConversationID {
            Task { await ExecutionSuspensionService.shared.cancel(for: convID) }
        }
    }

    // MARK: Profile selection

    func loadProfiles() {
        // ⚠️ `fetchSharedProfiles`, not `fetchProfiles`. The type filter below is NOT sufficient:
        // bot/agent is exactly what a workflow node owns, so the unfiltered list offered every
        // node's private configuration here as if it were one of the user's chat profiles — and
        // selecting one persists its id to UserDefaults, making a node's row the remembered Jarvis
        // profile until the node is deleted and its row collected out from under it.
        let all = (try? BackendProfileStore.shared.fetchSharedProfiles()) ?? []
        // Same restriction as QuickAccess: only chat-style profiles make sense here.
        profiles = all.filter { $0.profileType == .bot || $0.profileType == .agent }
        if let idString = UserDefaults.standard.string(forKey: Self.profileMemoryKey) {
            rememberedProfileID = UUID(uuidString: idString)
        }
    }

    func selectProfile(_ profile: BackendProfileModel) {
        guard !dismissed else { return }
        selectedProfile = profile
        backendConfiguration.selectedProfileID = profile.id
        UserDefaults.standard.set(profile.id.uuidString, forKey: Self.profileMemoryKey)
        stage = .welcoming
        voice.speak(greetingLine) { [weak self] in
            guard let self, !self.dismissed else { return }
            self.stage = .passiveListening
            self.startListeningLoop()
        }
    }

    // MARK: Greeting

    static var greetingName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespaces)
        guard let first = full.split(separator: " ").first, !first.isEmpty else { return "there" }
        return String(first)
    }

    var greetingLine: String { "Hello \(Self.greetingName)" }

    // MARK: Voice loop

    /// Re-entry point from the voiceUnavailable stage.
    func retryVoice() {
        guard !dismissed, listenTask == nil else { return }
        consecutiveDeadSessions = 0
        stage = .passiveListening
        startListeningLoop()
    }

    private func startListeningLoop() {
        guard listenTask == nil, !dismissed else { return }
        listenGeneration &+= 1
        let generation = listenGeneration
        listenTask = Task { @MainActor [weak self] in
            let command = await self?.runListeningSessions(generation: generation)
            // A superseded loop must not clear a NEWER loop's task handle, nor
            // execute a command the user has since navigated away from.
            guard let self, self.listenGeneration == generation else { return }
            self.listenTask = nil
            guard !self.dismissed else { return }
            if let command, !command.isEmpty {
                await self.execute(command)
            }
        }
    }

    /// Runs bounded listening sessions back-to-back until a command is captured,
    /// voice becomes unavailable, or this loop is superseded/torn down.
    private func runListeningSessions(generation: Int) async -> String? {
        let service = WhisperRecognitionService.shared
        while !dismissed, generation == listenGeneration {
            // Only the wake-word and capture stages should hold the mic open. Without
            // this, a stage change (profile switch, execution) would leave the loop
            // opening sessions in a stage that has no use for them.
            guard stage == .passiveListening || stage == .commandCapture else { return nil }
            guard case .loaded = service.loadingState else {
                stage = .voiceUnavailable(reason: "No speech model is loaded. Download a Whisper model from the composer's voice settings, then retry.")
                return nil
            }
            let granted = await AVAudioApplication.requestRecordPermission()
            guard !dismissed, generation == listenGeneration else { return nil }
            guard granted else {
                stage = .voiceUnavailable(reason: "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone.")
                return nil
            }

            // Fully release the speech synthesizer's audio unit, then let CoreAudio
            // settle, before claiming the input device.
            voice.releaseAudio()
            try? await Task.sleep(nanoseconds: UInt64(Self.audioSettleDelay * 1_000_000_000))
            guard !dismissed, generation == listenGeneration else { return nil }

            liveTranscript = ""
            energyLevels = []
            manualCaptureBaseline = nil
            receivedAudio = false
            lastNormalizedCommand = ""
            sessionStart = Date()
            lastTranscriptChange = Date()
            lastCommandChange = Date()
            isSessionActive = true
            startWatchdog()
            logger.info("Jarvis mic session opening (stage: \(String(describing: self.stage))).")

            do {
                // Blocks until VAD auto-stop, the watchdog's stopStreaming, or an
                // external stop (model switch in Settings). All paths return here.
                // [V2] `.sessionBusy` (composer/QuickAccess already recording) lands in
                // the catch below → `.voiceUnavailable`, no spin-loop.
                try await service.startStreaming(owner: .jarvis) { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.handleTranscriptUpdate(state)
                    }
                }
            } catch {
                isSessionActive = false
                watchdogTask?.cancel()
                logger.error("Jarvis listening session failed to start: \(error.localizedDescription)")
                stage = .voiceUnavailable(reason: "The voice session failed to start. Check that a speech model is loaded, then retry.")
                return nil
            }

            isSessionActive = false
            watchdogTask?.cancel()
            guard !dismissed, generation == listenGeneration else { return nil }

            // No samples at all → the engine never really started, however long the
            // session appeared to run. Back off and retry; give up with a real message
            // rather than pretending to listen forever.
            let duration = Date().timeIntervalSince(sessionStart)
            if !receivedAudio {
                consecutiveDeadSessions += 1
                logger.warning("Jarvis mic session delivered NO audio in \(String(format: "%.1f", duration))s (attempt \(self.consecutiveDeadSessions)/\(Self.maxDeadSessions)) — audio engine likely failed to start.")
                guard consecutiveDeadSessions < Self.maxDeadSessions else {
                    stage = .voiceUnavailable(reason: "The microphone opened but delivered no audio. Another app may be holding the input device — quit apps using the mic (or check your input device in System Settings → Sound), then retry.")
                    return nil
                }
                // Escalating backoff gives the HAL time to release the device.
                let backoff = Double(consecutiveDeadSessions) * 0.8
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                continue
            }
            consecutiveDeadSessions = 0
            logger.info("Jarvis mic session ended after \(String(format: "%.1f", duration))s — transcript: \"\(self.liveTranscript)\"")

            if stage == .commandCapture {
                // commandPreview honors whichever way capture was armed (wake word or click).
                let command = commandPreview
                if !command.isEmpty { return command }
                // Armed but nothing followed — re-arm.
                stage = .passiveListening
            }
            // Passive session ended (recycle / non-wake speech) — loop restarts it.
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

                switch self.stage {
                case .commandCapture:
                    // Judged on the NORMALIZED command timeline (see lastCommandChange)
                    // so punctuation/case churn from Whisper's re-decodes can't reset
                    // the window. The hard cap runs on CAPTURE age, not session age.
                    let commandIdle = Date().timeIntervalSince(self.lastCommandChange)
                    let captureAge = Date().timeIntervalSince(self.captureArmedAt)
                    let hasCommand = !self.commandPreview.isEmpty
                    if (hasCommand && commandIdle > Self.commandSilenceCommit)
                        || (!hasCommand && commandIdle > Self.emptyCaptureTimeout)
                        || captureAge > Self.captureHardCap {
                        _ = await WhisperRecognitionService.shared.stopStreaming()
                        return
                    }
                case .passiveListening:
                    if age > Self.passiveRecycleInterval {
                        _ = await WhisperRecognitionService.shared.stopStreaming()
                        return
                    }
                default:
                    return
                }
            }
        }
    }

    private func handleTranscriptUpdate(_ state: StreamingTranscriptionState) {
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

        if stage == .passiveListening, Self.wakeWordRange(in: text) != nil {
            stage = .commandCapture
            manualCaptureBaseline = nil
            lastTranscriptChange = Date()
            lastCommandChange = Date()
            captureArmedAt = Date()
            logger.info("Jarvis wake word detected in: \"\(text)\"")
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

    /// Accepted wake-word spellings. A small Whisper model regularly renders "Jarvis"
    /// as a near-homophone, and an unrecognized wake word leaves the user with no way
    /// to talk to the HUD at all — so matching is deliberately generous. False
    /// positives only arm command capture, which the user can see and simply not act on.
    static let wakeWordVariants = ["jarvis", "jarvus", "jervis", "javis", "jarves", "charvis", "travis"]

    /// Range of the first accepted wake-word variant in `text`, if any.
    static func wakeWordRange(in text: String) -> Range<String.Index>? {
        wakeWordVariants
            .compactMap { text.range(of: $0, options: .caseInsensitive) }
            .min { $0.lowerBound < $1.lowerBound }
    }

    /// Everything after the FIRST wake-word occurrence, stripped of leading/trailing
    /// punctuation. Falls back to the whole transcript if the wake word was rewritten
    /// out of the final text (partial → confirmed drift).
    static func extractCommand(from transcriptText: String) -> String {
        guard let range = wakeWordRange(in: transcriptText) else {
            return transcriptText.trimmingCharacters(in: commandStrippers)
        }
        return String(transcriptText[range.upperBound...]).trimmingCharacters(in: commandStrippers)
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

    /// Click-to-speak: arms command capture without the wake word, mid-session.
    /// The safety net for when Whisper never renders the wake word recognizably.
    func armManualCapture() {
        guard stage == .passiveListening else { return }
        manualCaptureBaseline = liveTranscript
        stage = .commandCapture
        lastTranscriptChange = Date()
        lastCommandChange = Date()
        captureArmedAt = Date()
        logger.info("Jarvis command capture armed manually.")
        onRequestAttention?()
    }

    /// Siri-style "I'm done talking" tap: ends the capture session immediately and
    /// commits whatever has been heard. The definitive exit when background noise
    /// keeps every automatic stability window from settling.
    func commitCaptureNow() {
        guard stage == .commandCapture, isSessionActive else { return }
        logger.info("Jarvis capture committed by user tap.")
        Task { _ = await WhisperRecognitionService.shared.stopStreaming() }
    }

    // MARK: Execution (the chat-interface send path, verbatim from QuickAccess)

    private func execute(_ command: String) async {
        guard let mainVM, !dismissed else { return }
        stage = .executing
        liveTranscript = command

        guard let config = backendConfiguration.getRequestConfig() else {
            // Selected profile was deleted mid-session — fall back to the picker.
            logger.error("Jarvis send aborted — profile not resolvable.")
            stage = .selectingProfile
            loadProfiles()
            return
        }

        let convID = ensureConversation(titleFrom: command, profileID: config.profile.id)
        // Bind the profile so restart-resume, ChatOps, and the sidebar all resolve it.
        ChatPersistenceStore.shared.updateBackendForConversation(
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

        let userMessage = await mainVM.messagingCoordinator.createUserMessage(
            conversationID: convID, query: command, files: []
        )
        await ChatPersistenceStore.shared.addMessage(userMessage, toConversation: convID)
        transcript.append(userMessage)
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
            origin: .jarvis
        )
        let agentMessage = mainVM.activeStreamManager.startMessageStream(
            withConfig: config,
            conversationID: convID,
            userQuery: command,
            history: transcript,
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
        thisStreamID = agentMessage.id
        streamingMessageID = agentMessage.id
        currentAgentMessage = agentMessage
        transcript.append(agentMessage)
    }

    private func handleRunFinished() {
        guard !dismissed else { return }
        // A user-stopped run skips the completion announcement.
        if currentAgentMessage?.terminalOutcome == .cancelled {
            stage = .passiveListening
            startListeningLoop()
            return
        }
        stage = .announcing
        voice.speak(Self.completionPhrase) { [weak self] in
            guard let self, !self.dismissed else { return }
            self.stage = .passiveListening
            self.startListeningLoop()
        }
    }

    /// Stop button during execution. onComplete still fires (outcome .cancelled)
    /// and routes back to passive listening without the completion announcement.
    func stopExecution() {
        guard let id = streamingMessageID else { return }
        mainVM?.activeStreamManager.cancelStream(for: id)
        if let convID = jarvisConversationID {
            Task { await ExecutionSuspensionService.shared.cancel(for: convID) }
        }
    }

    /// Each overlay presentation gets a fresh conversation (inspectable from the
    /// sidebar afterwards), created lazily on the first command.
    private func ensureConversation(titleFrom command: String, profileID: UUID) -> UUID {
        if let existing = jarvisConversationID { return existing }
        let title = "Jarvis — \(String(command.prefix(48)))"
        let conversation = Conversation(
            id: UUID(),
            timestamp: Date(),
            userDefinedTitle: title,
            backendEntityId: profileID
        )
        ChatPersistenceStore.shared.addConversation(from: conversation)
        jarvisConversationID = conversation.id
        return conversation.id
    }

    // MARK: HITL passthrough (audit-logged wrappers, keyed purely by operationID)

    func approveTool(_ pending: PendingHITL) {
        mainVM?.submitToolApproval(operationID: pending.id, approved: true)
    }

    func denyTool(_ pending: PendingHITL) {
        mainVM?.submitToolApproval(operationID: pending.id, approved: false)
    }

    func submitClarification(_ pending: PendingHITL, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        mainVM?.submitClarificationResponse(operationID: pending.id, response: trimmed.isEmpty ? nil : trimmed)
    }

    func resolvePlan(_ pending: PendingHITL, approved: Bool) {
        guard case .planReview(let plan) = pending.kind else { return }
        mainVM?.submitPlanReview(operationID: pending.id, editedPlan: approved ? plan.subtasks : nil)
    }

    func chooseGate(_ pending: PendingHITL, option: String) {
        mainVM?.submitGateChoice(operationID: pending.id, option: option)
    }
}

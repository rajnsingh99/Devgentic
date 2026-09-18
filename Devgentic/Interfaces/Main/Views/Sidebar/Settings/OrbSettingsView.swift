// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbSettingsView.swift
//  Devgentic
//
//  Settings pane for the Orb voice HUD. Reads/writes OrbConfigManager (UserDefaults-
//  backed) and asks AppDelegate to re-register the Carbon shortcut when activation changes.
//
//  Two deliberate shapes, both from the settings design review:
//
//  • DURATIONS ARE NAMED STEPS, NOT SLIDERS. No `Slider` appears inside a SettingsCard/
//    SettingsRow anywhere in this app, and more importantly the effective end-of-speech is
//    min(our window, WhisperKit's own ~1.5s VAD) — so a slider's bottom third would be
//    visibly inert. Quick/Normal/Relaxed states the floor instead of hiding it.
//
//  • ROWS WHOSE BEHAVIOUR IS NOT BUILT YET SHOW A "Soon" BADGE RATHER THAN A LIVE CONTROL.
//    The pane exists so the user knows what Orb will and won't do; hiding future rows
//    would serve tidiness over that goal, and a working-looking toggle over a feature that
//    does not exist is the exact complaint the pane is meant to prevent.
//

import SwiftUI
import AVFoundation

struct OrbSettingsView: View {
    @Environment(\.appTheme) private var theme
    @State private var config = OrbConfigManager.shared
    @State private var speech = WhisperRecognitionService.shared
    @State private var downloadService = WhisperModelDownloadService.shared
    @AppStorage(AppSettings.speechModelKey) private var whisperModel: String = "base.en"
    @State private var isProbing = false
    @State private var probeResult: String?
    /// A model the user picked that is not on disk. Surfaces the reason instead of persisting an
    /// id that would leave the app with no recognizer on next launch.
    @State private var pendingModelDownload: String?
    @State private var isMicProbing = false
    @State private var micProbeResult: String?

    /// Drives the default-profile picker, seeded from / persisted to the same key the orb reads.
    @State private var profileConfig = BackendConfiguration()
    @State private var showingProfilePopup = false

    /// Private synthesizer for the voice preview — deliberately not SpeechService.shared, which
    /// would pop the chat Read-Aloud island over the history.
    @State private var previewVoice = OrbVoiceOutput()
    @State private var micPermission: AVAudioApplication.recordPermission = AVAudioApplication.shared.recordPermission

    /// Rate multipliers. 0 is the sentinel for "same as Read Aloud".
    private let rateOptions: [Float] = [0, 0.75, 1.0, 1.25, 1.5]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                orbCard
                listeningCard
                conversationCard
                developerCard
                statusCard
            }
            .padding(24)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .onAppear {
            profileConfig.selectedProfileID = config.profileID
            micPermission = AVAudioApplication.shared.recordPermission
            downloadService.refreshDownloadedModels()
        }
    }

    // MARK: - Orb

    private var orbCard: some View {
        SettingsCard(title: "Orb", icon: "atom", theme: theme) {
            HStack(spacing: 8) {
                SoonBadge(text: "Experimental", theme: theme)
                Text("A voice HUD you can talk to. Speech is transcribed on this Mac and discarded — no audio is recorded or stored.")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

            SettingsRow(
                title: "Enable Orb",
                description: "Turn off to remove the Orb button from the chat composer, release its global shortcut, and close the orb if it is open.",
                theme: theme
            ) {
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(theme.accentColor)
            }
        }
    }

    // MARK: - Listening

    private var listeningCard: some View {
        SettingsCard(title: "Listening", icon: "waveform.badge.mic", theme: theme) {
            SettingsRow(
                title: "How Orb starts listening",
                description: "Hold a shortcut keeps the microphone closed until you press it — the recommended setting on a laptop. The other two keep a speech model listening the whole time the orb is open, which costs battery and keeps the microphone live.",
                theme: theme
            ) {
                Picker("", selection: activationBinding) {
                    ForEach(OrbActivationMode.allCases) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            if config.activationMode == .holdShortcut {
                rowDivider
                SettingsRow(
                    title: "Global Shortcut",
                    description: "Hold to speak, release to send. Works from any app, and opens the orb if it is closed.",
                    theme: theme
                ) {
                    HStack(spacing: 8) {
                        HotkeyRecorderView(
                            currentDescription: config.shortcutDescription,
                            onRecorded: { code, mods in
                                config.setShortcut(carbonKeyCode: code, carbonModifiers: mods)
                                AppDelegate.shared?.applyOrbHotkeyConfig()
                            },
                            // Pause the live shortcut while the recorder is armed, so pressing the
                            // CURRENT combo to re-record it is captured here instead of firing.
                            onRecordingStateChanged: { recording in
                                AppDelegate.shared?.setOrbHotkeyPaused(recording)
                            }
                        )
                        .disabled(!config.isEnabled)
                        .opacity(config.isEnabled ? 1 : 0.5)

                        Button("Reset") {
                            config.resetShortcutToDefault()
                            AppDelegate.shared?.applyOrbHotkeyConfig()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                        .help("Reset to ⌥J")
                    }
                }
            }

            rowDivider
            SettingsRow(
                title: "Wait after you stop speaking",
                description: "How long Orb waits before deciding your command is finished. Speech recognition stops on its own after about 1.5 seconds of silence, so Quick is the shortest wait that has any effect.",
                theme: theme
            ) {
                Picker("", selection: endpointingBinding) {
                    ForEach(OrbEndpointing.allCases) { option in
                        Text(option.localizedTitle).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }

            rowDivider
            SettingsRow(
                title: "Keep listening after an answer (listening modes only)",
                description: "Leaves the microphone hot briefly once Orb finishes speaking, so a follow-up needs no wake word and no shortcut. The orb turns green while the window is open.",
                theme: theme
            ) {
                Picker("", selection: followUpBinding) {
                    ForEach(OrbFollowUp.allCases) { option in
                        Text(option.localizedTitle).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            rowDivider
            SettingsRow(
                title: "Sounds",
                description: "Short tones marking when Orb starts listening and when it accepts what you said. Full adds cues for a failed run and for interrupting an answer.",
                theme: theme
            ) {
                Picker("", selection: earconsBinding) {
                    ForEach(OrbEarcons.allCases) { option in
                        Text(option.localizedTitle).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }
        }
    }

    // MARK: - Conversation

    private var conversationCard: some View {
        SettingsCard(title: "Conversation", icon: "bubble.left.and.bubble.right", theme: theme) {
            SettingsRow(
                title: "Spoken responses",
                description: "Read the answer aloud as it arrives. Just the gist asks for a one or two sentence answer; Automatic reads the opening of a long answer and leaves the rest on screen. Either way, say \"tell me more\" to hear the part that was left out. Code is never read out — Orb says it is in the chat window instead.",
                theme: theme
            ) {
                Picker("", selection: spokenResponsesBinding) {
                    ForEach(OrbSpokenResponses.allCases) { option in
                        Text(option.localizedTitle).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 175)
            }

            rowDivider
            SettingsRow(
                title: "Orb voice",
                description: "The voice used for Orb's spoken phrases. Leave it on “Same as Read Aloud” to follow the chat voice, or pick one so the two are independent.",
                theme: theme
            ) {
                HStack(spacing: 8) {
                    Picker("", selection: voiceBinding) {
                        Text("Same as Read Aloud").tag("")
                        ForEach(SpeechService.availableVoices) { voice in
                            Text("\(voice.name) (\(voice.locale))").tag(voice.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)

                    Picker("", selection: rateBinding) {
                        ForEach(rateOptions, id: \.self) { rate in
                            Text(rate == 0 ? "Default" : String(format: "%.2g×", rate)).tag(rate)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)

                    Button {
                        previewVoice.speak("Hello. Your task is completed, let me know next.")
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.accentColor)
                    .help("Preview this voice")
                }
            }

            rowDivider
            SettingsRow(
                title: "Tool approvals",
                description: "Ask me shows the request on the orb and waits — you read the tool and its arguments before approving. Autonomous approves everything for the voice conversation so a long run never stops; it is never persisted and is revoked when the orb closes.",
                isWarning: config.toolApprovals.isAutonomous,
                theme: theme
            ) {
                Picker("", selection: approvalsBinding) {
                    ForEach(OrbToolApprovals.allCases) { option in
                        Text(option.localizedTitle).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            rowDivider
            SettingsRow(
                title: "Default profile",
                description: "The profile Orb speaks to. Only Bots and Agents can be chosen. Changing it here takes effect the next time you open the orb.",
                theme: theme
            ) {
                BackendPickerButton(
                    profileThemeColor: selectedProfile?.profileType.displayColor ?? theme.secondaryText,
                    profileButtonText: selectedProfile?.displayName ?? "Choose profile",
                    backendConfiguration: profileConfig,
                    allowedProfileTypes: QuickAccessSessionViewModel.allowedProfileTypes,
                    showingPopup: $showingProfilePopup
                )
                .onChange(of: profileConfig.selectedProfileID) { _, newID in
                    config.profileID = newID
                }
            }
        }
    }

    // MARK: - Developer

    /// Gated on the app's existing developer-mode flag. These are escape hatches from silent
    /// failures, not preferences — which is why they are not in the main pane.
    @ViewBuilder private var developerCard: some View {
        if UserDefaults.standard.bool(forKey: AppSettings.developerModeKey) {
            SettingsCard(title: "Developer", icon: "wrench.and.screwdriver", theme: theme) {
                SettingsRow(
                    title: "Duplex audio (echo cancellation)",
                    description: "Route Orb through one app-owned audio engine with echo cancellation, instead of letting the speech engine own the microphone. Untested on real hardware — if voice stops working, turn this off. Watch the ORB_AUDIO log lines.",
                    isWarning: true,
                    theme: theme
                ) {
                    Toggle("", isOn: duplexBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(theme.warningColor)
                }

                rowDivider
                SettingsRow(
                    title: "Duplex speech test",
                    description: "Renders one sentence through the app's own audio engine — the path that makes barge-in possible. `write(_:toBufferCallback:)` has no documented completion contract, so this run is what establishes it. You should hear three sentences.",
                    theme: theme
                ) {
                    HStack(spacing: 8) {
                        if isProbing {
                            ProgressView().controlSize(.small)
                        } else {
                            TactileButton(
                                title: "Run Test",
                                icon: "play.fill",
                                variant: .secondary
                            ) {
                                isProbing = true
                                // The probe builds its own engine. Running it while the orb holds
                                // a warm one would measure contention, not the thing under test.
                                OrbDuplexAudio.shared.release(reason: "duplex speech test")
                                Task {
                                    probeResult = await OrbDuplexProbe.run(logger: DGLogger(category: "OrbSettings"))
                                    isProbing = false
                                }
                            }
                        }
                    }
                }

                if let probeResult {
                    rowDivider
                    readoutRow(
                        title: "Last test result",
                        description: "Full detail is in the OrbDuplex log.",
                        value: probeResult,
                        isWarning: probeResult.lowercased().contains("no audio") || probeResult.lowercased().contains("couldn't")
                    )
                }

                rowDivider
                SettingsRow(
                    title: "Microphone test",
                    description: "Opens the microphone twice — once with echo cancellation, once without — and reports how much audio each one captured. Echo cancellation can report a healthy engine and still deliver nothing; this is what tells the two apart. Takes about five seconds.",
                    theme: theme
                ) {
                    HStack(spacing: 8) {
                        if isMicProbing {
                            ProgressView().controlSize(.small)
                        } else {
                            TactileButton(
                                title: "Run Test",
                                icon: "play.fill",
                                variant: .secondary
                            ) {
                                isMicProbing = true
                                // Same reason as above: this probe's whole value is that its
                                // engine is the only one on the device.
                                OrbDuplexAudio.shared.release(reason: "microphone test")
                                Task {
                                    micProbeResult = await OrbMicProbe.run(logger: DGLogger(category: "OrbSettings"))
                                    isMicProbing = false
                                }
                            }
                        }
                    }
                }

                if let micProbeResult {
                    rowDivider
                    readoutRow(
                        title: "Last microphone result",
                        description: "Full detail is in the OrbMicProbe log.",
                        value: micProbeResult,
                        isWarning: micProbeResult.lowercased().contains("broken") || micProbeResult.lowercased().contains("no microphone")
                    )
                }

                rowDivider
                SettingsRow(
                    title: "Approve by voice",
                    description: "Lets you approve a pending tool by saying the word below instead of clicking. Orb reads back exactly what would run first, and only offers this for read-only tools whose arguments he can say out loud — anything that changes something, runs code, or reports its own safety is spoken aloud and left on screen for you to approve there.",
                    isWarning: config.voiceApprovals,
                    theme: theme
                ) {
                    Toggle("", isOn: voiceApprovalsBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(theme.warningColor)
                }

                if config.voiceApprovals {
                    rowDivider
                    SettingsRow(
                        title: "Words that approve",
                        description: "What you say to go ahead. Separate several with commas. Orb matches the whole phrase, so \"approve\" won't fire on \"don't approve that\".",
                        theme: theme
                    ) {
                        TextField("", text: approvalKeywordsBinding, prompt: Text(OrbApprovalKeywords.approveDefault))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }

                    rowDivider
                    SettingsRow(
                        title: "Words that deny",
                        description: "What you say to skip it. A word listed in both places always denies — an ambiguous answer should never run a tool.",
                        theme: theme
                    ) {
                        TextField("", text: denialKeywordsBinding, prompt: Text(OrbApprovalKeywords.denyDefault))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }

                    // ⚠️ Shows what Orb will ACTUALLY listen for, not what was typed. Entries
                    // are normalized and one-letter words are dropped, so a field that reads
                    // "Approve, a" listens for one word — and silently disagreeing with the text
                    // box is exactly how a user concludes the microphone is broken.
                    let resolved = config.resolvedApprovalKeywords
                    rowDivider
                    readoutRow(
                        title: "Orb will listen for",
                        description: resolved.problems.isEmpty
                            ? "Say one of these while a request is waiting."
                            : "Some of what you typed couldn't be used — one-letter words are ignored, and a word in both lists denies.",
                        value: "\(resolved.approve.joined(separator: ", ")) → approve   ·   \(resolved.deny.joined(separator: ", ")) → deny",
                        isWarning: !resolved.problems.isEmpty
                    )
                }

                rowDivider
                SettingsRow(
                    title: "Announce finished tasks",
                    description: "While the orb is open, Orb tells you when a task you started by typing in the main window finishes. He stays quiet about his own runs, scheduled tasks, and anything that finishes quickly — and never interrupts himself mid-sentence.",
                    theme: theme
                ) {
                    Toggle("", isOn: ambientBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                if config.ambientAnnouncements {
                    rowDivider
                    SettingsRow(
                        title: "Announce tasks longer than",
                        description: "Shorter tasks finish while you're still watching, so announcing them tells you nothing you can't already see.",
                        theme: theme
                    ) {
                        Picker("", selection: ambientThresholdBinding) {
                            ForEach(OrbAmbientThreshold.allCases) { option in
                                Text(option.localizedTitle).tag(option)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }

                rowDivider
                SettingsRow(
                    title: "Speech recognizer",
                    description: "Apple Speech reports when you have finished speaking, so Orb can send immediately instead of waiting out the pause above — but it has not been tested on real hardware. Dictation in the composer always uses WhisperKit.",
                    isWarning: config.recognizer.isAppleSpeech,
                    theme: theme
                ) {
                    Picker("", selection: recognizerBinding) {
                        ForEach(OrbRecognizer.allCases) { option in
                            Text(option.localizedTitle).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 185)
                }

                // ⚠️ BOTH recognizers need a DOWNLOADED model, and both fail quietly without one:
                // WhisperKit refuses to start, Apple Speech transcribes degraded without erroring.
                // The choice therefore belongs next to the recognizer picker, not buried elsewhere.
                rowDivider
                if config.recognizer.isAppleSpeech {
                    appleSpeechLanguageRow
                } else {
                    whisperModelRow
                }
            }
        }
    }

    // MARK: - Recognizer models

    /// WhisperKit's model. Shared with composer dictation by design — there is ONE app-wide
    /// WhisperKit instance holding ONE loaded model, so an Orb-private choice would force a
    /// reload on every orb open and fight the composer. Saying so is better than pretending.
    @ViewBuilder private var whisperModelRow: some View {
        SettingsRow(
            title: "Speech model",
            description: "The Whisper model used for recognition. Shared with dictation in the composer — this app loads one speech model at a time, so changing it here changes it there too.",
            isWarning: !downloadService.isModelDownloaded(whisperModel),
            theme: theme
        ) {
            HStack(spacing: 8) {
                Picker("", selection: whisperModelBinding) {
                    ForEach(WhisperModelCatalog.availableModels) { model in
                        Text(downloadService.isModelDownloaded(model.id)
                             ? "\(model.displayName)"
                             : "\(model.displayName) — \(model.size), not downloaded")
                            .tag(model.id)
                    }
                }
                .labelsHidden()
                .frame(width: 240)

                if let pendingModelDownload {
                    Text("Download \(pendingModelDownload) first — Orb keeps using \(whisperModel).")
                        .font(theme.fontCaption2)
                        .foregroundStyle(theme.warningColor)
                }

                if downloadService.isDownloading, downloadService.downloadingModelId == whisperModel {
                    ProgressView(value: downloadService.downloadProgress)
                        .frame(width: 70)
                } else if !downloadService.isModelDownloaded(whisperModel) {
                    TactileButton(
                        title: "Download",
                        icon: "arrow.down.circle",
                        variant: .secondary
                    ) {
                        downloadService.downloadModel(whisperModel)
                    }
                }
            }
        }
    }

    /// Apple Speech's model IS its language — see OrbAppleSpeechAssets for why this must be
    /// explicit rather than defaulted to the system locale and hoped for.
    @ViewBuilder private var appleSpeechLanguageRow: some View {
        if #available(macOS 26.0, *) {
            let assets = OrbAppleSpeechAssets.shared
            let chosen = config.speechLocale
            SettingsRow(
                title: "Language",
                description: "Apple Speech uses a separate on-device model for each language, and recognises poorly — without reporting an error — if that model isn't downloaded. Download the language before switching the recognizer over.",
                isWarning: !assets.isInstalled(chosen) && !assets.supported.isEmpty,
                theme: theme
            ) {
                HStack(spacing: 8) {
                    Picker("", selection: localeBinding) {
                        Text("System (\(Locale.current.identifier))").tag("")
                        ForEach(assets.supported, id: \.identifier) { locale in
                            Text(assets.isInstalled(locale)
                                 ? (locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                 : "\(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier) — not downloaded")
                                .tag(locale.identifier)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)

                    if assets.isInstalling {
                        ProgressView(value: assets.installProgress).frame(width: 70)
                    } else if !assets.isInstalled(chosen) {
                        TactileButton(
                            title: "Download",
                            icon: "arrow.down.circle",
                            variant: .secondary
                        ) {
                            Task { await assets.install(chosen) }
                        }
                    }
                }
            }
            .task { await assets.refresh() }
        } else {
            SettingsRow(
                title: "Language",
                description: "Apple Speech needs macOS 26 or later.",
                isWarning: true,
                theme: theme
            ) { EmptyView() }
        }
    }

    // MARK: - Status & Recovery

    private var statusCard: some View {
        SettingsCard(title: "Status & Recovery", icon: "stethoscope", theme: theme) {
            readoutRow(
                title: "Microphone",
                description: "Orb cannot hear anything without this.",
                value: micPermissionText,
                isWarning: micPermission != .granted
            )
            rowDivider
            // ⚠️ Under Apple Speech, Orb never touches WhisperKit — the Apple branch runs an
            // entirely separate loop. Reporting an unloaded Whisper model as a WARNING there made
            // the one card whose job is "why isn't this working?" raise a false alarm about a
            // healthy session, which is the fastest way to teach someone to ignore the card.
            readoutRow(
                title: config.recognizer.isAppleSpeech ? "Speech model (not in use)" : "Speech model",
                description: config.recognizer.isAppleSpeech
                    ? "Orb is running on Apple Speech, which does not use this model. It is still what the composer's dictation uses."
                    : "Shared with dictation in the composer. Change it in the Developer card above.",
                value: speechModelText,
                isWarning: !isModelLoaded && !config.recognizer.isAppleSpeech
            )
            rowDivider
            readoutRow(
                title: "Voice input in use by",
                description: "Only one part of the app can hold the microphone at a time. If Orb says voice is busy, this is what has it.",
                value: speech.activeVoiceOwner?.displayName ?? String(localized: "nothing right now"),
                isWarning: false
            )

            rowDivider
            SettingsRow(
                title: "Recovery",
                description: "Check microphone access, restart the macOS audio system if the microphone opens but hears nothing, or reset every Orb setting — including the orb's remembered position, which is the only way back if it is stranded off-screen.",
                theme: theme
            ) {
                HStack(spacing: 8) {
                    TactileButton(
                        title: "Check Access",
                        icon: "mic.badge.checkmark",
                        variant: .secondary
                    ) {
                        Task {
                            _ = await AVAudioApplication.requestRecordPermission()
                            micPermission = AVAudioApplication.shared.recordPermission
                        }
                    }

                    // Reachable WITHOUT the orb: the wedge can leave the panel unable to show
                    // anything useful, and it survives relaunching the app.
                    TactileButton(
                        title: "Repair Audio",
                        icon: "wrench.and.screwdriver",
                        variant: .secondary
                    ) {
                        _ = OrbAudioRepair.run(logger: DGLogger(category: "OrbSettings"))
                    }

                    TactileButton(
                        title: "Privacy Settings",
                        icon: "hand.raised",
                        variant: .secondary
                    ) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }

                    TactileButton(
                        title: "Reset",
                        icon: "arrow.counterclockwise",
                        variant: .destructive
                    ) {
                        config.resetAll()
                        profileConfig.selectedProfileID = nil
                        AppDelegate.shared?.applyOrbHotkeyConfig()
                    }
                }
            }
        }
    }

    // MARK: - Row helpers

    private var rowDivider: some View {
        Divider().background(theme.dividerColor.opacity(0.3))
    }

    /// A row whose behaviour has not shipped yet: no control, a "Soon" badge, and copy that
    /// says what it will do. See the file header for why these are shown rather than hidden.
    private func comingSoonRow(title: LocalizedStringKey, description: LocalizedStringKey) -> some View {
        SettingsRow(title: title, description: description, theme: theme) {
            SoonBadge(text: "Soon", theme: theme)
        }
    }

    private func readoutRow(title: LocalizedStringKey,
                            description: LocalizedStringKey,
                            value: String,
                            isWarning: Bool) -> some View {
        SettingsRow(title: title, description: description, theme: theme) {
            Text(value)
                .font(theme.fontCodeCaption)
                .foregroundColor(isWarning ? theme.warningColor : theme.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill((isWarning ? theme.warningColor : theme.accentColor).opacity(0.10))
                )
                .fixedSize()
        }
    }

    // MARK: - Derived text

    private var micPermissionText: String {
        switch micPermission {
        case .granted:  return String(localized: "Allowed")
        case .denied:   return String(localized: "Denied")
        default:        return String(localized: "Not yet asked")
        }
    }

    private var isModelLoaded: Bool {
        if case .loaded = speech.loadingState { return true }
        return false
    }

    private var speechModelText: String {
        let name = speech.activeModelName
        switch speech.loadingState {
        case .loaded:      return "\(name) · " + String(localized: "loaded")
        case .downloading: return "\(name) · " + String(localized: "downloading")
        case .preparing:   return "\(name) · " + String(localized: "preparing")
        case .error:       return "\(name) · " + String(localized: "failed to load")
        case .idle:        return "\(name) · " + String(localized: "not loaded")
        }
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { config.isEnabled },
            set: { newValue in
                config.isEnabled = newValue
                AppDelegate.shared?.applyOrbHotkeyConfig()
            }
        )
    }

    private var activationBinding: Binding<OrbActivationMode> {
        Binding(
            get: { config.activationMode },
            set: { newValue in
                config.activationMode = newValue
                // The shortcut is registered ONLY in hold-to-talk mode, so a mode change is also
                // a registration change.
                AppDelegate.shared?.applyOrbHotkeyConfig()
                // ⚠️ And a RUNNING session has to be told. Without this, switching from
                // hold-to-talk to a listening mode unregistered the shortcut and started no loop:
                // the orb read STANDBY, the wake word did nothing, and clicking it wedged the
                // session in LISTENING with no microphone behind it.
                OrbPanelController.shared.session?.activationModeChanged()
            }
        )
    }

    /// ⚠️ This writes the APP-WIDE speech-model key, so it must behave exactly as the General
    /// pane's picker does for the same key. It did neither of the two things that picker does:
    ///
    ///  • **Post `speechModelChangedNotification`.** `WhisperRecognitionService` reloads ONLY on
    ///    that notification and reads the key just once at startup — so choosing a model here
    ///    changed the persisted value and nothing else. The pane then contradicted itself: the
    ///    picker showed the new model while Status & Recovery, three rows down, correctly still
    ///    reported the old one as loaded.
    ///  • **Refuse a model that is not downloaded.** General reverts and offers the download;
    ///    here the id was persisted regardless, so the NEXT LAUNCH came up naming a model that is
    ///    not on disk and neither Orb nor composer dictation had a recognizer at all.
    private var whisperModelBinding: Binding<String> {
        Binding(get: { whisperModel }, set: { newValue in
            guard newValue != whisperModel else { return }
            guard downloadService.isModelDownloaded(newValue) else {
                // Leave the stored model alone; the row's Download button is right beside this.
                pendingModelDownload = newValue
                return
            }
            whisperModel = newValue
            NotificationCenter.default.post(
                name: GlobalConstants.speechModelChangedNotification,
                object: newValue
            )
        })
    }

    private var localeBinding: Binding<String> {
        Binding(get: { config.speechLocaleIdentifier }, set: { config.speechLocaleIdentifier = $0 })
    }

    private var recognizerBinding: Binding<OrbRecognizer> {
        Binding(get: { config.recognizer }, set: { newValue in
            config.recognizer = newValue
            // Apple Speech builds its own engine; ours must not still be holding the device.
            if newValue.isAppleSpeech {
                OrbDuplexAudio.shared.release(reason: "recognizer switched to Apple Speech")
            }
        })
    }

    private var approvalKeywordsBinding: Binding<String> {
        Binding(get: { config.approvalKeywordsRaw }, set: { config.approvalKeywordsRaw = $0 })
    }

    private var denialKeywordsBinding: Binding<String> {
        Binding(get: { config.denialKeywordsRaw }, set: { config.denialKeywordsRaw = $0 })
    }

    private var voiceApprovalsBinding: Binding<Bool> {
        Binding(get: { config.voiceApprovals }, set: { newValue in
            config.voiceApprovals = newValue
            // ⚠️ The off edge must reach an ALREADY-ARMED window. The setting is read once, when
            // the run parks; nothing re-reads it. Without this the microphone stayed hot and the
            // next thing said in the room could still commit a tool — through a channel the UI
            // now says is switched off.
            if !newValue { OrbPanelController.shared.session?.cancelVoiceApproval(reason: "voice approvals switched off") }
        })
    }

    private var ambientBinding: Binding<Bool> {
        Binding(get: { config.ambientAnnouncements }, set: { config.ambientAnnouncements = $0 })
    }

    private var ambientThresholdBinding: Binding<OrbAmbientThreshold> {
        Binding(get: { config.ambientThreshold }, set: { config.ambientThreshold = $0 })
    }

    private var duplexBinding: Binding<Bool> {
        Binding(get: { config.duplexAudioEnabled }, set: { newValue in
            config.duplexAudioEnabled = newValue
            // ⚠️ Turning it off must release immediately. The engine is panel-scoped, so an open
            // orb would otherwise keep holding the device while the next turn has WhisperKit
            // build its own engine on top of it — two input engines, no capture.
            if newValue {
                // The ON edge was missing entirely: the engine is only warmed at panel open, so a
                // developer enabling duplex to test it got "Duplex is ON but the engine is cold"
                // on every turn while the toggle read on.
                Task { await OrbDuplexAudio.shared.rebuild(reason: "duplex audio switched on") }
            } else {
                OrbDuplexAudio.shared.release(reason: "duplex audio switched off")
            }
        })
    }

    private var approvalsBinding: Binding<OrbToolApprovals> {
        Binding(get: { config.toolApprovals }, set: { newValue in
            config.toolApprovals = newValue
            // ⚠️ The autonomous grant is applied per DISPATCH and revoked only at teardown, so a
            // change made mid-run was invisible to the run in flight — the picker read "Ask me"
            // while every remaining tool call kept auto-approving. This row's warning styling
            // implies it governs that danger; now it does.
            OrbPanelController.shared.session?.toolApprovalsChanged()
        })
    }

    private var followUpBinding: Binding<OrbFollowUp> {
        Binding(get: { config.followUp }, set: { config.followUp = $0 })
    }

    private var earconsBinding: Binding<OrbEarcons> {
        Binding(get: { config.earcons }, set: { config.earcons = $0 })
    }

    private var spokenResponsesBinding: Binding<OrbSpokenResponses> {
        Binding(get: { config.spokenResponses }, set: { config.spokenResponses = $0 })
    }

    private var endpointingBinding: Binding<OrbEndpointing> {
        Binding(get: { config.endpointing }, set: { config.endpointing = $0 })
    }

    private var voiceBinding: Binding<String> {
        Binding(get: { config.narratorVoiceID }, set: { config.narratorVoiceID = $0 })
    }

    private var rateBinding: Binding<Float> {
        Binding(get: { config.narratorRate }, set: { config.narratorRate = $0 })
    }

    private var selectedProfile: BackendProfileModel? {
        guard let id = profileConfig.selectedProfileID else { return nil }
        return try? BackendProfileStore.shared.fetchProfile(byId: id)
    }
}

// MARK: - Soon badge

/// Small capsule marking a row whose feature has not shipped. Matches the badge already used
/// in NotificationSettingsSection so the two read as one vocabulary.
private struct SoonBadge: View {
    let text: LocalizedStringKey
    let theme: any Theme

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(theme.secondaryText.opacity(0.5))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(theme.secondaryText.opacity(0.08))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(theme.secondaryText.opacity(0.15), lineWidth: 0.5)
            )
    }
}

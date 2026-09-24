// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbConfigManager.swift
//  Devgentic
//
//  Single source of truth for Orb configuration. Modeled on QuickAccessConfigManager:
//  an @Observable singleton over UserDefaults, reachable BOTH from AppDelegate (which
//  registers the Carbon shortcut outside any SwiftUI environment) and from the settings pane.
//
//  Why a config manager rather than reading UserDefaults at each site: OrbPanelController
//  keeps its session PRIVATE and the panel lives outside the SwiftUI environment, so there is
//  no back channel from Settings to a running orb. This type IS the channel — which is why
//  OrbSessionController's tunables forward to it at USE time rather than caching at start.
//
//  Not @MainActor (matching QuickAccessConfigManager, diverging from ChatOpsConfigManager):
//  AppDelegate reads it from nonisolated lifecycle/hotkey code. The backing store is
//  thread-safe UserDefaults and all access happens on the main thread, so plain @Observable is
//  sufficient — but Observation's access()/withMutation() are NOT thread-safe, so this type is
//  deliberately MAIN-THREAD-CONFINED and the setters assert it in debug builds.
//

import Foundation
import Observation
import SwiftUI
import HotKey

// MARK: - Activation

/// How the user starts an Orb turn.
///
/// The default is `.holdShortcut`, NOT the wake word the MVP shipped with. Wake-word standby
/// keeps a full Whisper decoder running against the room for as long as the orb is open — a
/// battery, thermal and privacy cost that should be an explicit opt-in on a laptop, not the
/// default. Hold-to-talk keeps the microphone CLOSED at rest.
enum OrbActivationMode: String, CaseIterable, Identifiable {
    /// Microphone closed at rest; the global shortcut opens it for exactly as long as it is held.
    case holdShortcut
    /// Always listening, scanning for "Orb". The MVP behaviour.
    case wakeWord
    /// Always listening, but only a click on the orb arms a command — the wake word is ignored.
    case clickOrb

    var id: String { rawValue }

    /// ⚠️ Never render `rawValue`: `Text(someString)` binds the non-localizing `StringProtocol`
    /// overload and escapes the String Catalog. See SettingsCategory's note.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .holdShortcut: return "Hold a shortcut"
        // ⚠️ Interpolated, not the literal "Orb": the wake word is user-configurable, and a label
        // naming a word the matcher is not listening for is the one mistake this pane cannot make.
        case .wakeWord:     return "Say “\(OrbConfigManager.shared.wakeWord)”"
        case .clickOrb:     return "Click the orb"
        }
    }

    /// Whether this mode keeps the microphone open while idle.
    var listensContinuously: Bool { self != .holdShortcut }
}

// MARK: - Endpointing

/// How long Orb waits after you stop speaking before deciding the command is finished.
///
/// ⚠️ Named steps, not a seconds slider, for two independent reasons. (1) House style: no
/// `Slider` appears inside a `SettingsCard`/`SettingsRow` anywhere in this app. (2) The
/// effective end-of-speech is `min(this, WhisperKit's own VAD)`, and WhisperKit auto-stops
/// after ~1.5s of silence once it has confirmed segments — so every value below the `.quick`
/// floor does nothing at all. A slider whose bottom third is visibly inert is worse than none.
enum OrbEndpointing: String, CaseIterable, Identifiable {
    case quick
    case normal
    case relaxed

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .quick:   return 1.5
        case .normal:  return 2.2
        case .relaxed: return 4.0
        }
    }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .quick:   return "Quick"
        case .normal:  return "Normal"
        case .relaxed: return "Relaxed"
        }
    }
}

// MARK: - Ambient threshold

/// How long a main-window run must take before it is worth interrupting for.
///
/// ⚠️ Named steps, not a slider — the pane's standing rule. A number of seconds would also imply
/// a precision this has no use for: the real question is "was I still watching, or had I switched
/// away", and that has about three answers.
enum OrbAmbientThreshold: String, CaseIterable, Identifiable {
    case brief
    case standard
    case long

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        // Roughly where a person stops watching a progress indicator and switches away.
        case .brief:    return 10
        case .standard: return 20
        case .long:     return 60
        }
    }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .brief:    return "10 seconds"
        case .standard: return "20 seconds"
        case .long:     return "1 minute"
        }
    }
}

// MARK: - Spoken responses

/// Whether Orb reads the assistant's answer aloud.
///
/// `.automatic` is the default and the interesting one: speak short answers in full, summarize
/// long ones down to their opening, and never read a code fence aloud. The MVP behaviour was
/// effectively `.preferSilent` — it spoke one fixed phrase and left the answer on screen.
enum OrbSpokenResponses: String, CaseIterable, Identifiable {
    /// One or two sentences, asked for at the SOURCE. ⚠️ Not "Automatic with a smaller cap": a cap
    /// can only truncate, so a short cap over a six-sentence answer ends every single turn in
    /// "there's more in the chat window", which reads as broken narration rather than as a choice.
    /// This mode asks the model for a short answer, so the cap almost never fires — and
    /// "tell me more" is there when the gist was not enough.
    case gist
    /// Read the whole answer, however long.
    case preferSpoken
    /// Read short answers in full; for a long one, read the opening and stop.
    case automatic
    /// Never read the answer — just say the run finished, as the MVP did.
    case preferSilent

    var id: String { rawValue }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .gist:         return "Just the gist"
        case .preferSpoken: return "Read the whole answer"
        case .automatic:    return "Automatic"
        case .preferSilent: return "Stay silent"
        }
    }

    var speaksAnswer: Bool { self != .preferSilent }

    /// Sentences spoken before `.automatic` stops and defers to the chat window. Nil means no cap.
    ///
    /// ⚠️ A cap is not a substitute for barge-in — it is the honest interim while the microphone
    /// is still closed during speech. Once full duplex lands, the user interrupting IS the cap.
    var sentenceCap: Int? {
        switch self {
        // A backstop, not the mechanism: the style hint below is what keeps the answer short.
        case .gist: return 2
        case .preferSpoken: return nil
        // ⚠️ Raised 4 → 6 after the 2026-09-04 device test, where BOTH turns hit the cap and the
        // user heard 4 of ~10 sentences. A cap that binds on almost every answer reads as the
        // narration being broken rather than as a deliberate bound. Paired with the brevity
        // request in `spokenStyleHint`, which shortens the answer at the source — a cap can only
        // truncate, it cannot make the model concise.
        case .automatic:    return 6
        case .preferSilent: return 0
        }
    }
}

// MARK: - Follow-up

/// How long the microphone stays hot after an answer so a follow-up needs no wake word.
///
/// ⚠️ Deliberately a small fixed set rather than a duration slider. Three independent design
/// passes proposed 0s, 7s and 8s as "the" default, which is the clearest possible evidence that
/// no continuous value is defensible — every shipping assistant treats this as on/off with a
/// vendor-chosen length.
enum OrbFollowUp: String, CaseIterable, Identifiable {
    case off
    case short
    case long

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .off:   return nil
        case .short: return 5
        case .long:  return 10
        }
    }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .off:   return "Off"
        case .short: return "5 seconds"
        case .long:  return "10 seconds"
        }
    }
}

// MARK: - Earcons

/// Short system sounds marking the edges of a turn.
///
/// Without them the orb's state changes are visual only — and the user is, by design, often not
/// looking at it. "Did it hear me?" is the single most common doubt in a voice UI, and a 60ms
/// tone answers it better than any animation.
enum OrbEarcons: String, CaseIterable, Identifiable {
    /// No sounds at all.
    case off
    /// Only the two that answer "did it hear me?" — capture start and capture committed.
    case subtle
    /// Adds failure and interruption cues.
    case full

    var id: String { rawValue }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .off:    return "Off"
        case .subtle: return "Subtle"
        case .full:   return "Full"
        }
    }

    func plays(_ cue: OrbEarcon) -> Bool {
        switch self {
        case .off:    return false
        case .subtle: return cue == .listening || cue == .captured
        case .full:   return true
        }
    }
}

/// The cues themselves, mapped to macOS system sounds so the feature ships no audio assets.
enum OrbEarcon: String {
    case listening   // the microphone just opened for you
    case captured    // your command was accepted
    case failed      // the run failed
    case interrupted // you cut the answer short

    /// ⚠️ System sound, not a bundled asset: it follows the user's alert-volume preference and
    /// is already familiar. `NSSound(named:)` returns nil if a name is ever retired, which the
    /// caller treats as "no sound" rather than a failure.
    var systemSoundName: String {
        switch self {
        case .listening:   return "Tink"
        case .captured:    return "Pop"
        case .failed:      return "Basso"
        case .interrupted: return "Funk"
        }
    }
}

// MARK: - Tool approvals

/// What Orb does when an agent run stops to ask permission.
///
/// ⚠️ Neither mode approves a tool BY VOICE. `.ask` shows the request on a surface where the tool
/// name and its arguments are readable; `.autonomous` is a standing choice the user made in
/// Settings, not an answer to a question they were asked out loud. That distinction is the whole
/// safety argument: an ASR transcript must never be what authorizes code execution.
enum OrbToolApprovals: String, CaseIterable, Identifiable {
    /// Show the request and wait. The default.
    case ask
    /// Approve everything for the Orb conversation, so a long run never stops.
    case autonomous

    var id: String { rawValue }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .ask:        return "Ask me"
        case .autonomous: return "Autonomous"
        }
    }

    var isAutonomous: Bool { self == .autonomous }
}

// MARK: - Recognizer

/// Which speech recognizer Orb listens with.
///
/// ⚠️ Default is `.whisperKit` — today's shipped, device-proven path. Apple Speech is the better
/// engine on paper (streaming results with an explicit `isFinal`, no per-turn restart, no model
/// download, no growing buffer) and it is what removes the 2.2s endpointing wait, but it has
/// never been run against a real microphone here. It stays Developer-mode until it has.
///
/// The composer and QuickAccess are deliberately NOT covered by this: they keep WhisperKit
/// unconditionally. Its per-model UX, offline guarantee and multilingual quality are the reasons
/// it was chosen, and none of that changes because a voice HUD wants lower latency.
enum OrbRecognizer: String, CaseIterable, Identifiable {
    case whisperKit
    case appleSpeech

    var id: String { rawValue }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .whisperKit:  return "WhisperKit (current)"
        case .appleSpeech: return "Apple Speech (experimental)"
        }
    }

    var isAppleSpeech: Bool { self == .appleSpeech }
}

// MARK: - Manager

@Observable
final class OrbConfigManager {

    nonisolated(unsafe) static let shared = OrbConfigManager()

    /// Debug tripwire: all mutation must happen on the main thread (see the type note).
    /// ⚠️ `assert` is STRIPPED IN RELEASE, so it was the only enforcement of this type's
    /// documented main-thread confinement and it does not exist in a shipped build. The paired
    /// `logger.error` is what makes an off-main mutation visible in the field.
    @ObservationIgnored private static let logger = DGLogger(category: "OrbConfig")

    private func assertMainThread() {
        guard !Thread.isMainThread else { return }
        // The assert stays for the debug crash; the log is what survives into release.
        Self.logger.error("[ORB_CONFIG] Mutated OFF the main thread. CONSEQUENCE: Observation's access()/withMutation() are not thread-safe — settings reads can tear and the UI can miss the change entirely. This is a caller bug; find it, do not silence this line.")
        assert(false, "OrbConfigManager must be mutated on the main thread (Observation is not thread-safe).")
    }

    /// Default shortcut: ⌥J. Deliberately not ⌥Space — that is QuickAccess's default, and two
    /// features fighting for one combo is a support ticket.
    static let defaultCombo = KeyCombo(key: .j, modifiers: .option)

    /// ⚠️⚠️ COMPUTED and routed through `TestHost.defaults`, not `let defaults = .standard`.
    ///
    /// Two reasons, both load-bearing. Under an XCTest host `UserDefaults.standard` is the
    /// SHIPPING APP's domain, so this singleton read — and WROTE — the developer's real Orb
    /// settings during an ordinary `test-without-building` run; `OrbWakeWordTests` failed on the
    /// author's machine and nowhere else because of it. And it is computed rather than stored
    /// because a stored property would resolve when this singleton is first touched, which can be
    /// during app launch — before the test bundle loads — pinning the real domain for the run.
    private var defaults: UserDefaults { TestHost.defaults }

    private init() {}

    // MARK: Enable

    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return defaults.object(forKey: AppSettings.orbEnabledKey) as? Bool ?? true
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.isEnabled) {
                defaults.set(newValue, forKey: AppSettings.orbEnabledKey)
            }
        }
    }

    // MARK: Activation

    var activationMode: OrbActivationMode {
        get {
            access(keyPath: \.activationMode)
            guard let raw = defaults.string(forKey: AppSettings.orbActivationModeKey),
                  let mode = OrbActivationMode(rawValue: raw)
            else { return .holdShortcut }
            return mode
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.activationMode) {
                defaults.set(newValue.rawValue, forKey: AppSettings.orbActivationModeKey)
            }
        }
    }

    // MARK: Shortcut (persisted as two Carbon UInt32s)

    var carbonKeyCode: UInt32 {
        get {
            access(keyPath: \.carbonKeyCode)
            // Non-trapping: `UInt32(v)` traps on a negative or oversized value, and this is read
            // at launch, so a corrupt or externally-written default (`defaults write … -1`) would
            // crash-loop the app with no in-app recovery. Fall back to the default combo instead.
            if let v = defaults.object(forKey: AppSettings.orbShortcutCodeKey) as? Int,
               let code = UInt32(exactly: v) {
                return code
            }
            return Self.defaultCombo.carbonKeyCode
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.carbonKeyCode) {
                defaults.set(Int(newValue), forKey: AppSettings.orbShortcutCodeKey)
            }
        }
    }

    var carbonModifiers: UInt32 {
        get {
            access(keyPath: \.carbonModifiers)
            if let v = defaults.object(forKey: AppSettings.orbShortcutModifiersKey) as? Int,
               let mods = UInt32(exactly: v) {
                return mods
            }
            return Self.defaultCombo.carbonModifiers
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.carbonModifiers) {
                defaults.set(Int(newValue), forKey: AppSettings.orbShortcutModifiersKey)
            }
        }
    }

    var keyCombo: KeyCombo { KeyCombo(carbonKeyCode: carbonKeyCode, carbonModifiers: carbonModifiers) }

    /// Human-readable shortcut, e.g. "⌥J".
    var shortcutDescription: String { keyCombo.description }

    func setShortcut(carbonKeyCode: UInt32, carbonModifiers: UInt32) {
        self.carbonKeyCode = carbonKeyCode
        self.carbonModifiers = carbonModifiers
    }

    func resetShortcutToDefault() {
        setShortcut(carbonKeyCode: Self.defaultCombo.carbonKeyCode,
                    carbonModifiers: Self.defaultCombo.carbonModifiers)
    }

    // MARK: Endpointing

    var endpointing: OrbEndpointing {
        get {
            access(keyPath: \.endpointing)
            guard let raw = defaults.string(forKey: AppSettings.orbEndpointingKey),
                  let value = OrbEndpointing(rawValue: raw)
            else { return .normal }
            return value
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.endpointing) {
                defaults.set(newValue.rawValue, forKey: AppSettings.orbEndpointingKey)
            }
        }
    }

    // MARK: Spoken responses

    var spokenResponses: OrbSpokenResponses {
        get {
            access(keyPath: \.spokenResponses)
            guard let raw = defaults.string(forKey: AppSettings.orbSpokenResponsesKey),
                  let value = OrbSpokenResponses(rawValue: raw)
            else { return .automatic }
            return value
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.spokenResponses) {
                defaults.set(newValue.rawValue, forKey: AppSettings.orbSpokenResponsesKey)
            }
        }
    }

    // MARK: Duplex audio (developer)

    /// Route Orb through one app-owned `AVAudioEngine` with echo cancellation, instead of
    /// letting WhisperKit own the microphone.
    ///
    /// ⚠️ DEFAULT OFF, and deliberately not a normal setting. The failure mode of this subsystem
    /// is a microphone that reports a healthy session and hears nothing, and the path has never
    /// been exercised on a real audio device. It is an escape hatch for a device test, not a
    /// preference — which is why it lives behind Developer mode and why the legacy path is kept
    /// alive rather than deleted.
    var duplexAudioEnabled: Bool {
        get {
            access(keyPath: \.duplexAudioEnabled)
            return defaults.object(forKey: AppSettings.orbDuplexAudioKey) as? Bool ?? false
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.duplexAudioEnabled) {
                defaults.set(newValue, forKey: AppSettings.orbDuplexAudioKey)
            }
        }
    }

    // MARK: Ambient announcements (Phase 6 · F3)

    /// Whether Orb speaks up about runs the user started by TYPING, while the orb is open.
    ///
    /// ⚠️ DEFAULT OFF, and that is a deliberate product choice rather than caution about the code.
    /// This is the only feature that makes Orb talk UNPROMPTED, about work the user never asked
    /// him to narrate. On by default it reads as the assistant interrupting; opt-in, it reads as
    /// the reason to leave the orb open at all.
    var ambientAnnouncements: Bool {
        get {
            access(keyPath: \.ambientAnnouncements)
            return defaults.object(forKey: AppSettings.orbAmbientAnnouncementsKey) as? Bool ?? false
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.ambientAnnouncements) {
                defaults.set(newValue, forKey: AppSettings.orbAmbientAnnouncementsKey)
            }
        }
    }

    /// Only runs longer than this are worth interrupting for. Defaults to 20 seconds — below it
    /// the user is still watching the window and an announcement tells them nothing they can't see.
    var ambientThreshold: OrbAmbientThreshold {
        get {
            access(keyPath: \.ambientThreshold)
            guard let raw = defaults.string(forKey: AppSettings.orbAmbientThresholdKey),
                  let value = OrbAmbientThreshold(rawValue: raw)
            else { return .standard }
            return value
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.ambientThreshold) {
                defaults.set(newValue.rawValue, forKey: AppSettings.orbAmbientThresholdKey)
            }
        }
    }

    var ambientThresholdSeconds: TimeInterval { ambientThreshold.seconds }

    // MARK: Voice approvals (Phase 6 · F2)

    /// Whether a spoken "yes" may approve a pending tool — for the narrow set that qualifies.
    ///
    /// ⚠️ DEFAULT OFF, and this one is a security surface rather than a convenience. Even switched
    /// on, `OrbApprovalPolicy` admits only read-only, non-server-declared tools whose arguments
    /// can be read back aloud; everything else is spoken and routed to the main window. The toggle
    /// does not widen that set — it only decides whether the narrow channel exists at all.
    var voiceApprovals: Bool {
        get {
            access(keyPath: \.voiceApprovals)
            return defaults.object(forKey: AppSettings.orbVoiceApprovalsKey) as? Bool ?? false
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.voiceApprovals) {
                defaults.set(newValue, forKey: AppSettings.orbVoiceApprovalsKey)
            }
        }
    }

    /// What the user says to approve. Comma-separated; defaults to "approve".
    var approvalKeywordsRaw: String {
        get {
            access(keyPath: \.approvalKeywordsRaw)
            return defaults.string(forKey: AppSettings.orbApprovalKeywordsKey) ?? OrbApprovalKeywords.approveDefault
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.approvalKeywordsRaw) {
                defaults.set(newValue, forKey: AppSettings.orbApprovalKeywordsKey)
            }
        }
    }

    /// What the user says to deny. Comma-separated; defaults to "deny".
    var denialKeywordsRaw: String {
        get {
            access(keyPath: \.denialKeywordsRaw)
            return defaults.string(forKey: AppSettings.orbDenialKeywordsKey) ?? OrbApprovalKeywords.denyDefault
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.denialKeywordsRaw) {
                defaults.set(newValue, forKey: AppSettings.orbDenialKeywordsKey)
            }
        }
    }

    /// ⚠️ The ONLY thing that should be matched against. Never match the raw strings: they are
    /// unvalidated, un-normalized user text, and a keyword that differs by a capital letter or a
    /// stray comma would look correct in Settings and never fire at the microphone.
    var resolvedApprovalKeywords: (approve: [String], deny: [String], problems: [OrbApprovalKeywords.Problem]) {
        OrbApprovalKeywords.resolve(approveRaw: approvalKeywordsRaw, denyRaw: denialKeywordsRaw)
    }

    // MARK: Recognizer (developer)

    var recognizer: OrbRecognizer {
        get {
            access(keyPath: \.recognizer)
            guard let raw = defaults.string(forKey: AppSettings.orbRecognizerKey),
                  let value = OrbRecognizer(rawValue: raw)
            else { return .whisperKit }
            return value
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.recognizer) {
                defaults.set(newValue.rawValue, forKey: AppSettings.orbRecognizerKey)
            }
        }
    }

    // MARK: Wake word

    /// The word the wake-word mode listens for. User-configurable.
    ///
    /// ⚠️ SANITIZED on the way in, because it is compiled into a regular expression and matched
    /// against ASR output. `sanitizedWakeWord` is the whole contract: no regex metacharacters, no
    /// empty string, no one-letter word. A one-letter wake word would fire on nearly every
    /// utterance; an unsanitized one could not be escaped into a pattern safely.
    ///
    /// ⚠️ Read at USE time by `OrbSessionController.wakeWord`, never cached — so a change here
    /// reaches a RUNNING orb with no other plumbing, exactly like `endpointing`.
    /// ⚠️ Stored VERBATIM and sanitized on READ, the same shape as `approvalKeywordsRaw`, and for
    /// the same reason: the text field binds to this. Sanitizing in the setter would rewrite the
    /// field under the user's cursor — "O" is below the two-character floor, so typing a fresh
    /// word one letter at a time would snap the field back to "orb" on the first keystroke.
    var wakeWordRaw: String {
        get {
            access(keyPath: \.wakeWordRaw)
            return defaults.string(forKey: AppSettings.orbWakeWordKey) ?? ""
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.wakeWordRaw) {
                defaults.set(newValue, forKey: AppSettings.orbWakeWordKey)
            }
        }
    }

    /// What the matcher listens for: the sanitized entry, or the default when it is unusable.
    /// An empty or one-letter field therefore leaves a WORKING orb, never a deaf one.
    var wakeWord: String { Self.sanitizedWakeWord(wakeWordRaw) ?? Self.defaultWakeWord }

    /// The shipped wake word. Also the only one whose mishearings are known — see
    /// `OrbSessionController.wakeWordHomophones`.
    static let defaultWakeWord = "orb"

    /// `raw` reduced to something safe to match, or nil when nothing usable is left. Pure.
    ///
    /// Lowercased (matching is case-insensitive anyway, and storing one form keeps the homophone
    /// lookup honest); everything that is not a letter, number or space is dropped; runs of
    /// whitespace collapse to one, so a multi-word phrase like "hey orb" is preserved — that is
    /// the intended escape hatch from a short word the recognizer keeps missing.
    static func sanitizedWakeWord(_ raw: String) -> String? {
        let collapsed = String(raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
        // ⚠️ Two characters is the floor. Below it the word is a fragment of ordinary speech and
        // every sentence in the room arms command capture.
        guard collapsed.count >= 2 else { return nil }
        return collapsed
    }

    // MARK: Apple Speech locale

    /// Locale identifier for Apple Speech. Empty means "follow the system".
    ///
    /// ⚠️ This is a MODEL choice, not a language preference. Apple ships one on-device model per
    /// locale and `SpeechTranscriber` runs DEGRADED — without erroring — if that model was never
    /// reserved and installed. Device test 2026-09-04: an unallocated `en_IN` turned "write an
    /// essay on technology" into "write an SM technology". Choosing and downloading here is what
    /// makes the recognizer usable, which is why it sits next to the recognizer picker.
    var speechLocaleIdentifier: String {
        get {
            access(keyPath: \.speechLocaleIdentifier)
            return defaults.string(forKey: AppSettings.orbSpeechLocaleKey) ?? ""
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.speechLocaleIdentifier) {
                defaults.set(newValue, forKey: AppSettings.orbSpeechLocaleKey)
            }
        }
    }

    /// The locale Apple Speech should use — the explicit choice, or the system's.
    var speechLocale: Locale {
        speechLocaleIdentifier.isEmpty ? .current : Locale(identifier: speechLocaleIdentifier)
    }

    // MARK: Tool approvals

    var toolApprovals: OrbToolApprovals {
        get {
            access(keyPath: \.toolApprovals)
            guard let raw = defaults.string(forKey: AppSettings.orbToolApprovalsKey),
                  let value = OrbToolApprovals(rawValue: raw)
            else { return .ask }
            return value
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.toolApprovals) {
                defaults.set(newValue.rawValue, forKey: AppSettings.orbToolApprovalsKey)
            }
        }
    }

    // MARK: Follow-up and earcons

    var followUp: OrbFollowUp {
        get {
            access(keyPath: \.followUp)
            guard let raw = defaults.string(forKey: AppSettings.orbFollowUpKey),
                  let value = OrbFollowUp(rawValue: raw)
            else { return .short }
            return value
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.followUp) {
                defaults.set(newValue.rawValue, forKey: AppSettings.orbFollowUpKey)
            }
        }
    }

    var earcons: OrbEarcons {
        get {
            access(keyPath: \.earcons)
            guard let raw = defaults.string(forKey: AppSettings.orbEarconsKey),
                  let value = OrbEarcons(rawValue: raw)
            else { return .subtle }
            return value
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.earcons) {
                defaults.set(newValue.rawValue, forKey: AppSettings.orbEarconsKey)
            }
        }
    }

    // MARK: Narrator

    /// Voice identifier for Orb's spoken phrases. Empty string is the SENTINEL for
    /// "same as chat Read Aloud", which preserves the pre-settings behaviour: OrbVoiceOutput
    /// read `speechPlaybackVoiceKey` directly, so changing the voice for reading a chat message
    /// silently changed the assistant's voice too.
    var narratorVoiceID: String {
        get {
            access(keyPath: \.narratorVoiceID)
            return defaults.string(forKey: AppSettings.orbNarratorVoiceKey) ?? ""
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.narratorVoiceID) {
                defaults.set(newValue, forKey: AppSettings.orbNarratorVoiceKey)
            }
        }
    }

    var usesReadAloudVoice: Bool { narratorVoiceID.isEmpty }

    /// Rate multiplier over `AVSpeechUtteranceDefaultSpeechRate`. Zero means "same as Read Aloud".
    var narratorRate: Float {
        get {
            access(keyPath: \.narratorRate)
            let stored = defaults.object(forKey: AppSettings.orbNarratorRateKey) as? Float ?? 0
            // Clamp: an externally-written default must not produce silence or a garbled rush.
            guard stored > 0 else { return 0 }
            return min(max(stored, 0.5), 2.0)
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.narratorRate) {
                defaults.set(newValue, forKey: AppSettings.orbNarratorRateKey)
            }
        }
    }

    // MARK: Default profile

    var profileID: UUID? {
        get {
            access(keyPath: \.profileID)
            guard let raw = defaults.string(forKey: AppSettings.orbProfileIDKey) else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            assertMainThread()
            withMutation(keyPath: \.profileID) {
                if let newValue {
                    defaults.set(newValue.uuidString, forKey: AppSettings.orbProfileIDKey)
                } else {
                    defaults.removeObject(forKey: AppSettings.orbProfileIDKey)
                }
            }
        }
    }

    // MARK: Reset

    /// Clears every Orb preference AND the panel's remembered position. The position is the
    /// reason this exists as a user-facing action: the panel is borderless with no titlebar, its
    /// origin is written only on close, and a crash or a disconnected display can strand it
    /// off-screen with no in-app way to drag it back.
    /// ⚠️ EVERY Orb key belongs here. This list fell a whole phase behind and silently skipped
    /// all five Phase 6 keys — and because their controls live only inside the Developer card,
    /// Reset was the ONLY path a non-developer had to switch off voice approvals or ambient
    /// announcements once Developer mode was turned back off. A reset that misses a key the user
    /// cannot otherwise reach is worse than no reset.
    ///
    /// ⚠️ AND IT MUST GO THROUGH `withMutation`. Every setter in this type wraps its write, which
    /// is what makes the class the documented channel from Settings to the rest of the app. The
    /// bare `removeObject` loop emitted no observation at all: the pane only *appeared* to update
    /// because the Reset button separately assigns an unrelated @Observable property. Any other
    /// observer — the composer's Orb button, the hotkey registration — saw nothing.
    func resetAll() {
        assertMainThread()
        withMutation(keyPath: \.isEnabled) {
        withMutation(keyPath: \.activationMode) {
        withMutation(keyPath: \.wakeWordRaw) {
        withMutation(keyPath: \.endpointing) {
        withMutation(keyPath: \.spokenResponses) {
        withMutation(keyPath: \.followUp) {
        withMutation(keyPath: \.earcons) {
        withMutation(keyPath: \.toolApprovals) {
        withMutation(keyPath: \.duplexAudioEnabled) {
        withMutation(keyPath: \.recognizer) {
        withMutation(keyPath: \.speechLocaleIdentifier) {
        withMutation(keyPath: \.narratorVoiceID) {
        withMutation(keyPath: \.narratorRate) {
        withMutation(keyPath: \.profileID) {
        withMutation(keyPath: \.ambientAnnouncements) {
        withMutation(keyPath: \.ambientThreshold) {
        withMutation(keyPath: \.voiceApprovals) {
        withMutation(keyPath: \.approvalKeywordsRaw) {
        withMutation(keyPath: \.denialKeywordsRaw) {
            for key in Self.allResettableKeys {
                defaults.removeObject(forKey: key)
            }
        }}}}}}}}}}}}}}}}}}}
        Self.logger.notice("[ORB_CONFIG] All \(Self.allResettableKeys.count) Orb setting(s) reset to defaults. CONSEQUENCE: observers are notified, so the composer button, the global shortcut and an open panel all pick this up without a relaunch.")
    }

    /// ⚠️ Kept beside `resetAll` and asserted by a test against `AppSettings`, so a key added in a
    /// future phase cannot silently escape the reset the way the Phase 6 keys did.
    static let allResettableKeys: [String] = [
        AppSettings.orbEnabledKey, AppSettings.orbActivationModeKey,
        AppSettings.orbWakeWordKey,
        AppSettings.orbShortcutCodeKey, AppSettings.orbShortcutModifiersKey,
        AppSettings.orbEndpointingKey, AppSettings.orbSpokenResponsesKey,
        AppSettings.orbFollowUpKey, AppSettings.orbEarconsKey,
        AppSettings.orbToolApprovalsKey, AppSettings.orbDuplexAudioKey,
        AppSettings.orbRecognizerKey, AppSettings.orbSpeechLocaleKey,
        AppSettings.orbNarratorVoiceKey,
        AppSettings.orbNarratorRateKey, AppSettings.orbProfileIDKey,
        // [Phase 6] These five were missing, and their controls are Developer-only.
        AppSettings.orbAmbientAnnouncementsKey, AppSettings.orbAmbientThresholdKey,
        AppSettings.orbVoiceApprovalsKey,
        AppSettings.orbApprovalKeywordsKey, AppSettings.orbDenialKeywordsKey,
        OrbPanelController.originXKey, OrbPanelController.originYKey,
    ]
}

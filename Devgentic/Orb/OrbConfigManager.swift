// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbConfigManager.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import Observation
import SwiftUI
import HotKey

// MARK: - Activation

/// How the user starts an Orb turn.
/// The default is `.holdShortcut`: wake-word standby keeps a Whisper decoder running (battery, thermal, privacy cost),
/// so it is an explicit opt-in; hold-to-talk keeps the microphone closed at rest.
enum OrbActivationMode: String, CaseIterable, Identifiable {
    /// Microphone closed at rest; the global shortcut opens it for exactly as long as it is held.
    case holdShortcut
    /// Always listening, scanning for "Orb". The MVP behaviour.
    case wakeWord
    /// Always listening, but only a click on the orb arms a command — the wake word is ignored.
    case clickOrb

    var id: String { rawValue }

    // Why: Never render `rawValue`: `Text(someString)` binds the non-localizing overload and escapes the String Catalog.
    /// Localized label for the case.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .holdShortcut: return "Hold a shortcut"
        // Interpolated, not a literal: the wake word is user-configurable, and the label must name the word the matcher
        // listens for.
        case .wakeWord:     return "Say “\(OrbConfigManager.shared.wakeWord)”"
        case .clickOrb:     return "Click the orb"
        }
    }

    /// Whether this mode keeps the microphone open while idle.
    var listensContinuously: Bool { self != .holdShortcut }
}

// MARK: - Endpointing

/// How long Orb waits after you stop speaking before deciding the command is finished.
/// Named steps, not a slider: the effective end of speech is `min(this, WhisperKit's VAD)`,
/// which auto-stops after ~1.5 s, so values below the `.quick` floor would do nothing.
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
/// Named steps, not a slider: the real question is 'was I still watching', which has about three answers.
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
/// `.automatic` speaks short answers in full, summarizes long ones down to their opening, and never reads a code fence
/// aloud.
enum OrbSpokenResponses: String, CaseIterable, Identifiable {
    // Why: Not 'Automatic with a smaller cap': a cap only truncates and ends every turn in 'there's more in the chat window'.
    /// One or two sentences, asked for at the source: the model is asked for a short answer, so the cap almost never fires.
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
    /// A cap is the interim for a microphone that is closed during speech; with barge-in, the user interrupting is the cap.
    var sentenceCap: Int? {
        switch self {
        // A backstop, not the mechanism: the style hint below is what keeps the answer short.
        case .gist: return 2
        case .preferSpoken: return nil
        // A cap that binds on almost every answer reads as broken narration; paired with the brevity request in
        // `spokenStyleHint`, which shortens the answer at the source (a cap can only truncate).
        case .automatic:    return 6
        case .preferSilent: return 0
        }
    }
}

// MARK: - Follow-up

/// How long the microphone stays hot after an answer so a follow-up needs no wake word.
/// A small fixed set rather than a duration slider: no continuous value is defensible as the default.
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
/// Without them the orb's state changes are visual only, and the user is often not looking at it.
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

    /// A system sound, not a bundled asset: it follows the user's alert-volume preference.
    /// `NSSound(named:)` returns nil if a name is retired, which the caller treats as 'no sound'.
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

// Why: Neither mode approves a tool by voice: an ASR transcript must never be what authorizes code execution.
/// What Orb does when an agent run stops to ask permission.
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

/// Which speech recognizer Orb listens with; the default is `.whisperKit`, the device-proven path.
/// Apple Speech stays Developer-mode until it has been run against a real microphone.
/// The composer and QuickAccess are not covered: they keep WhisperKit unconditionally.
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

    // Why: `assert` is stripped in release, so the paired `logger.error` is what makes an off-main mutation visible in the field.
    /// Debug tripwire: all mutation must happen on the main thread (see the type note).
    @ObservationIgnored private static let logger = DGLogger(category: "OrbConfig")

    private func assertMainThread() {
        guard !Thread.isMainThread else { return }
        // The assert stays for the debug crash; the log is what survives into release.
        Self.logger.error("[ORB_CONFIG] Mutated OFF the main thread. CONSEQUENCE: Observation's access()/withMutation() are not thread-safe — settings reads can tear and the UI can miss the change entirely. This is a caller bug; find it, do not silence this line.")
        assert(false, "OrbConfigManager must be mutated on the main thread (Observation is not thread-safe).")
    }

    /// Default shortcut: Option-J, deliberately not Option-Space, which is QuickAccess's default.
    static let defaultCombo = KeyCombo(key: .j, modifiers: .option)

    // Why: Under an XCTest host `.standard` is the shipping app's domain; a stored property would resolve at first touch,
    // before the test bundle loads.
    /// Computed and routed through `TestHost.defaults`, not `.standard`.
    private var defaults: UserDefaults { TestHost.defaults }

    private init() {}

    // MARK: Enable

    /// Opt-in, default off: Orb is experimental and needs the microphone.
    /// The Settings switch is also where the macOS microphone prompt is requested
    /// (`OrbSettingsView.requestMicrophoneOnEnable`).
    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return defaults.object(forKey: AppSettings.orbEnabledKey) as? Bool ?? false
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
            // Non-trapping: `UInt32(v)` traps on a negative or oversized value, and this is read at launch,
            // so a corrupt default would crash-loop the app. Fall back to the default combo.
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

    /// Routes Orb through one app-owned `AVAudioEngine` with echo cancellation instead of letting WhisperKit own the
    /// microphone.
    /// Default off and behind Developer mode: an escape hatch for device testing, with the legacy path kept alive.
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

    // MARK: Ambient announcements

    /// Whether Orb speaks up about runs the user started by typing, while the orb is open.
    /// Default off by product choice: it is the only feature that makes Orb talk unprompted.
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

    // MARK: Voice approvals

    /// Whether a spoken 'yes' may approve a pending tool, for the narrow set that qualifies. Default off.
    /// `OrbApprovalPolicy` admits only read-only, non-server-declared tools whose arguments can be read back aloud;
    /// the toggle only decides whether that channel exists.
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

    // Why: Never match the raw strings: they are unvalidated, un-normalized user text and a keyword differing by a capital
    // would never fire.
    /// The only value that should be matched against the spoken text.
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

    // Why: Sanitizing in the setter would rewrite the text field under the cursor and snap a one-letter edit back to 'orb'.
    /// The word the wake-word mode listens for; user-configurable.
    /// Stored verbatim and sanitized on read (`sanitizedWakeWord`: no regex metacharacters, empty or one-letter words);
    /// `OrbSessionController.wakeWord` reads it at use time, so a change reaches a running orb.
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
    /// Lowercased; non-letters, numbers and spaces dropped; whitespace runs collapsed, so a phrase like 'hey orb' is
    /// preserved.
    static func sanitizedWakeWord(_ raw: String) -> String? {
        let collapsed = String(raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
        // Two characters is the floor: below it the word is a fragment of ordinary speech and every sentence arms command
        // capture.
        guard collapsed.count >= 2 else { return nil }
        return collapsed
    }

    // MARK: Apple Speech locale

    /// Locale identifier for Apple Speech; empty means 'follow the system'.
    /// A model choice, not a language preference: Apple ships one on-device model per locale,
    /// and `SpeechTranscriber` runs degraded without erroring if it was never installed.
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

    /// Voice identifier for Orb's spoken phrases.
    /// Empty string is the sentinel for 'same as chat Read Aloud'.
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

    // Why: A bare `removeObject` loop emits no observation: the composer's Orb button and hotkey registration would see nothing.
    /// Clears every Orb preference and the panel's remembered position, which can be stranded off-screen by a crash or
    /// display change.
    /// Every Orb key belongs in the list, and the reset goes through `withMutation` so other observers see it.
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

    /// Kept beside `resetAll` and asserted by a test against `AppSettings`, so a new key cannot silently escape the reset.
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
        AppSettings.orbAmbientAnnouncementsKey, AppSettings.orbAmbientThresholdKey,
        AppSettings.orbVoiceApprovalsKey,
        AppSettings.orbApprovalKeywordsKey, AppSettings.orbDenialKeywordsKey,
        OrbPanelController.originXKey, OrbPanelController.originYKey,
    ]
}

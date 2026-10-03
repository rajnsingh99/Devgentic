// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AppSettings.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//

import Foundation

/// A centralized place to store keys for UserDefaults settings.
struct AppSettings {
    /// Key for the boolean value that determines if LLM responses should be streamed.
    static let useStreamingResponseKey = "useStreamingResponse"

    // Speech Recognition
    static let speechModelKey = "speechModel"
    static let speechLanguageKey = "speechLanguage"
    static let speechAutoStopOnSilenceKey = "speechAutoStopOnSilence"

    // Intelligence Core
    static let isIntelligenceCoreEnabledKey = "isIntelligenceCoreEnabled"
    static let coreIntelligenceModelKey = "coreIntelligenceModel"

    // Core Intelligence Feature Toggles
    static let ciFeatureRAGRewritingKey = "ciFeatureRAGRewriting"
    static let ciFeatureSuggestionKey = "ciFeatureSuggestion"
    static let ciFeatureMorningBriefKey = "ciFeatureMorningBrief"
    static let ciFeatureUserPersonalKey = "ciFeatureUserPersonal"
    static let ciFeatureHistoryCompactionKey = "ciFeatureHistoryCompaction"
    static let ciCustomPromptKey = "ciCustomPrompt"

    // Response Synthesis opt-in, per provider family. A run synthesizes only when the key
    // matching ITS provider family is on: an IC-sized cleanup pass measurably helps
    // small local models, but behind a large cloud model it compresses a better
    // answer than it produces. Default false — synthesis is never automatic.
    static let ciFeatureResponseSynthesisMLXKey = "ciFeatureResponseSynthesisMLX"
    static let ciFeatureResponseSynthesisOllamaKey = "ciFeatureResponseSynthesisOllama"
    static let ciFeatureResponseSynthesisRemoteKey = "ciFeatureResponseSynthesisRemote"

    // Morning Brief
    static let lastMorningBriefDateKey = "lastMorningBriefDate"
    static let morningBriefIncludeAISummaryKey = "morningBriefIncludeAISummary"

    // User Personal
    static let lastUserPersonalAnalysisDateKey = "lastUserPersonalAnalysisDate"
    static let userPersonalAnalyzedConversationIDsKey = "userPersonalAnalyzedConversationIDs"

    // Notifications
    static let notificationsEnabledKey = "notificationsEnabled"
    static let notificationChannelsKey = "notificationChannels"
    static let notificationPerConversationKey = "notificationPerConversation"

    // [CF-39] Conversation id → the ChatOps service that created it. See
    // `RemoteConversationOriginStore` for why this is not a `ConversationSD` column.
    static let remoteConversationOriginsKey = "remoteConversationOrigins"

    // Chat Font
    static let chatFontFamilyKey = "chatFontFamily"
    static let chatFontSizeKey = "chatFontSize"
    static let chatLineSpacingKey = "chatLineSpacing"

    // Chat & Execution Timeline
    static let showTimelineThoughtsKey = "showTimelineThoughts"

    // Orb — the voice HUD.
    // ⚠️ Key VALUES must stay free of "key"/"token"/"secret"/"auth"/"path": `BundleExporter`'s
    // allowlist is asserted by `ObservabilityHygieneTests.testAllowlistContainsNothingSecretShaped`,
    // which matches on the value, not the symbol. Hence `orbShortcutCode`, not `…KeyCode`.
    static let orbEnabledKey = "orbEnabled"
    static let orbActivationModeKey = "orbActivationMode"
    static let orbWakeWordKey = "orbWakeWord"
    static let orbShortcutCodeKey = "orbShortcutCode"
    static let orbShortcutModifiersKey = "orbShortcutModifiers"
    static let orbEndpointingKey = "orbEndpointing"
    static let orbSpokenResponsesKey = "orbSpokenResponses"
    static let orbFollowUpKey = "orbFollowUp"
    static let orbEarconsKey = "orbEarcons"
    static let orbToolApprovalsKey = "orbToolApprovals"
    /// Developer-mode escape hatch for the Phase 4 duplex audio graph. Default OFF.
    static let orbDuplexAudioKey = "orbDuplexAudio"
    // [Phase 6 · F3] Ambient run-completion announcements.
    static let orbAmbientAnnouncementsKey = "orbAmbientAnnouncements"
    static let orbAmbientThresholdKey = "orbAmbientThresholdSeconds"
    // [Phase 6 · F2] Spoken tool approvals.
    static let orbVoiceApprovalsKey = "orbVoiceApprovals"
    // ⚠️ DELIBERATELY NOT IN `BundleExporter.exportablePreferenceKeys`. These two hold free-form
    // text the USER TYPED, and that allowlist's contract is that none of its entries carry user
    // content. The diagnostic value is near zero — which words were configured is inferable from
    // the approval log lines, which already record counts rather than content.
    static let orbApprovalKeywordsKey = "orbApprovalKeywords"
    static let orbDenialKeywordsKey = "orbDenialKeywords"
    /// Which speech recognizer Orb uses. Developer-mode until device-proven. Default WhisperKit.
    static let orbRecognizerKey = "orbRecognizer"
    /// Locale for Apple Speech. Empty = follow the system. ⚠️ Apple's models are per-LOCALE and
    /// must be reserved + installed before use, so this is a model choice, not a preference.
    static let orbSpeechLocaleKey = "orbSpeechLocale"
    /// Empty string is the sentinel for "same voice as chat Read Aloud" — see OrbVoiceOutput.
    static let orbNarratorVoiceKey = "orbNarratorVoice"
    static let orbNarratorRateKey = "orbNarratorRate"
    /// ⚠️ Pre-existing value, written by OrbSessionController since the MVP. The STRING must
    /// not change or every user silently loses their remembered profile.
    static let orbProfileIDKey = "orbProfileID"

    // Speech Playback (Read Aloud)
    static let speechPlaybackRateKey = "speechPlaybackRate"
    static let speechPlaybackVoiceKey = "speechPlaybackVoice"
    static let speechPauseOnCodeKey = "speechPauseOnCode"

    // ChatOps — Telegram
    static let chatOpsBotTokenKey = "chatOpsBotToken"
    static let chatOpsAuthorizedChatIDKey = "chatOpsAuthorizedChatID"
    static let chatOpsSecurityTierKey = "chatOpsSecurityTier"
    static let chatOpsEnabledKey = "chatOpsEnabled"
    static let chatOpsActiveConversationIDKey = "chatOpsActiveConversationID"
    /// [Slice 3] Whether completed runs and other app notifications are announced to the paired
    /// ChatOps channels. Defaults to OFF — see `ChatOpsNotificationChannel`.
    static let chatOpsNotificationsEnabledKey = "chatOpsNotificationsEnabled"
    /// Whether macOS system notifications are delivered. Absent means ON — see
    /// `LocalNotificationChannel.isEnabled`.
    static let localNotificationsEnabledKey = "localNotificationsEnabled"

    // ChatOps — Discord
    static let chatOpsDiscordBotTokenKey = "chatOpsDiscordBotToken"
    static let chatOpsDiscordChannelIDKey = "chatOpsDiscordChannelID"
    static let chatOpsDiscordApplicationIDKey = "chatOpsDiscordApplicationID"
    static let chatOpsDiscordGuildIDKey = "chatOpsDiscordGuildID"
    static let chatOpsDiscordEnabledKey = "chatOpsDiscordEnabled"
    static let chatOpsDiscordActiveConversationIDKey = "chatOpsDiscordActiveConversationID"

    // Developer Mode
    static let developerModeKey = "developerMode"

    // Remote (first-party cloud) model visibility
    /// Key for the General Settings toggle that reveals the first-party remote
    /// providers — Gemini, OpenAI, Anthropic — in every provider picker (agent/bot/
    /// workflow/image-gen profile config and the Code interface backend selector).
    /// Default OFF: the providers ship hidden, and the toggle is the way back in.
    static let showRemoteModelsKey = "showRemoteModels"
    /// Whether remote-model providers appear in provider pickers. Absence of the key
    /// means hidden. Read by `ProfileCapabilityFilter` (Foundation-only call sites),
    /// so it is a computed UserDefaults lookup rather than an `@AppStorage` binding —
    /// views that need live re-rendering bind their own `@AppStorage` to the key.
    static var showRemoteModels: Bool {
        UserDefaults.standard.object(forKey: showRemoteModelsKey) as? Bool ?? false
    }

    // Diagnostics consent (default-ON opt-out)
    /// Opt-out for on-device error/warning diagnostics: warning+ log buffering, v2 error-
    /// analytics columns, and crash-diagnostic capture. NOTE: basic execution traces
    /// (`beginTrace`/`emit`) are NOT gated — they always record locally (30-day purge) and
    /// power the Report inspector; the Settings/PRIVACY copy says exactly that. Default-ON
    /// (absence of the key means enabled). Developer mode additionally records info/debug
    /// verbosity regardless of this flag.
    static let diagnosticsEnabledKey = "diagnosticsEnabled"

    /// One-time WelcomeView disclosure that on-device diagnostics are recorded.
    static let diagnosticsDisclosureSeenKey = "diagnosticsDisclosureSeen"

    /// Whether on-device diagnostic recording is enabled. Default-ON (opt-out).
    static var diagnosticsRecordingEnabled: Bool {
        UserDefaults.standard.object(forKey: diagnosticsEnabledKey) as? Bool ?? true
    }

    // ChatOps — Slack
    static let chatOpsSlackBotTokenKey = "chatOpsSlackBotToken"
    static let chatOpsSlackAppTokenKey = "chatOpsSlackAppToken"
    static let chatOpsSlackChannelIDKey = "chatOpsSlackChannelID"
    static let chatOpsSlackEnabledKey = "chatOpsSlackEnabled"
    static let chatOpsSlackActiveConversationIDKey = "chatOpsSlackActiveConversationID"
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AppSettings.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// A centralized place to store keys for UserDefaults settings.
struct AppSettings {
    /// Key for the boolean value that determines if LLM responses should be streamed.
    static let useStreamingResponseKey = "useStreamingResponse"

    /// The global ceiling on any one run's COMPUTE time, in seconds (local inference coordinator,
    /// phase 5). 0 = off. Absent = `LocalInferenceCoordinator.defaultGlobalCeiling`.
    static let maximumRunTimeKey = "maximumRunTimeSeconds"

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
    static let ciFeatureBriefingKey = "ciFeatureBriefing"
    static let ciFeatureUserPersonalKey = "ciFeatureUserPersonal"
    static let ciFeatureHistoryCompactionKey = "ciFeatureHistoryCompaction"
    static let ciCustomPromptKey = "ciCustomPrompt"

    // Response Synthesis opt-in, per provider family: a run synthesizes only when the key for its own family is on.
    // Default false; synthesis is never automatic.
    static let ciFeatureResponseSynthesisMLXKey = "ciFeatureResponseSynthesisMLX"
    static let ciFeatureResponseSynthesisOllamaKey = "ciFeatureResponseSynthesisOllama"
    static let ciFeatureResponseSynthesisRemoteKey = "ciFeatureResponseSynthesisRemote"

    // Briefing
    static let lastBriefingDateKey = "lastBriefingDate"
    static let briefingIncludeAISummaryKey = "briefingIncludeAISummary"

    // User Personal
    static let lastUserPersonalAnalysisDateKey = "lastUserPersonalAnalysisDate"
    static let userPersonalAnalyzedConversationIDsKey = "userPersonalAnalyzedConversationIDs"

    // Notifications
    static let notificationsEnabledKey = "notificationsEnabled"
    static let notificationChannelsKey = "notificationChannels"
    static let notificationPerConversationKey = "notificationPerConversation"

    // Conversation id → the ChatOps service that created it; see `RemoteConversationOriginStore` for why this is
    // not a `ConversationSD` column.
    static let remoteConversationOriginsKey = "remoteConversationOrigins"

    // Chat Font
    static let chatFontFamilyKey = "chatFontFamily"
    static let chatFontSizeKey = "chatFontSize"
    static let chatLineSpacingKey = "chatLineSpacing"

    // Chat & Execution Timeline
    static let showTimelineThoughtsKey = "showTimelineThoughts"

    // Orb voice HUD. Key VALUES must avoid "key"/"token"/"secret"/"auth"/"path": the `BundleExporter` allowlist test
    // matches on the value, not the symbol (hence `orbShortcutCode`, not `…KeyCode`).
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
    /// Developer-mode escape hatch for the duplex audio graph. Default off.
    static let orbDuplexAudioKey = "orbDuplexAudio"
    // Ambient run-completion announcements.
    static let orbAmbientAnnouncementsKey = "orbAmbientAnnouncements"
    static let orbAmbientThresholdKey = "orbAmbientThresholdSeconds"
    // Spoken tool approvals.
    static let orbVoiceApprovalsKey = "orbVoiceApprovals"
    // Deliberately not in `BundleExporter.exportablePreferenceKeys`: these two hold free-form user-typed text, and that
    // allowlist carries no user content.
    static let orbApprovalKeywordsKey = "orbApprovalKeywords"
    static let orbDenialKeywordsKey = "orbDenialKeywords"
    /// Which speech recognizer Orb uses. Developer-mode until device-proven. Default WhisperKit.
    static let orbRecognizerKey = "orbRecognizer"
    /// Locale for Apple Speech; empty follows the system. A model choice rather than a preference: Apple's models are
    /// per-locale and must be reserved and installed before use.
    static let orbSpeechLocaleKey = "orbSpeechLocale"
    /// Empty string is the sentinel for "same voice as chat Read Aloud" — see OrbVoiceOutput.
    static let orbNarratorVoiceKey = "orbNarratorVoice"
    static let orbNarratorRateKey = "orbNarratorRate"
    /// The persisted Orb profile id, written by `OrbSessionController`.
    /// The key string must not change, or users lose their remembered profile.
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
    /// Key for the General Settings toggle that reveals the first-party remote providers (Gemini, OpenAI, Anthropic) in every
    /// provider picker (agent/bot/workflow/image-gen config and the Code backend selector). Default off.
    static let showRemoteModelsKey = "showRemoteModels"
    /// Whether remote-model providers appear in provider pickers; an absent key means hidden.
    /// Read by Foundation-only call sites such as `ProfileCapabilityFilter`, so it is a computed UserDefaults lookup;
    /// views that need live re-rendering bind their own `@AppStorage` to the key.
    static var showRemoteModels: Bool {
        UserDefaults.standard.object(forKey: showRemoteModelsKey) as? Bool ?? false
    }

    // Diagnostics consent (default-ON opt-out)
    /// Opt-out for on-device error/warning diagnostics: warning+ log buffering, error-analytics columns and crash capture.
    /// Basic execution traces are not gated: they always record locally and power the Report inspector. Default on
    /// (an absent key means enabled); developer mode additionally records info/debug verbosity regardless.
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

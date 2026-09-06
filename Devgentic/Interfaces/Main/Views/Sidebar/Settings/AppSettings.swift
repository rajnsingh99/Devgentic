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
    /// Legacy single Response Synthesis toggle. RETAINED FOR MIGRATION ONLY — no
    /// runtime code reads it any more; see the per-family keys below.
    static let ciFeatureResponseSynthesisKey = "ciFeatureResponseSynthesis"
    static let ciFeatureHistoryCompactionKey = "ciFeatureHistoryCompaction"
    static let ciCustomPromptKey = "ciCustomPrompt"

    // Response Synthesis opt-in, per provider family (replaces the single
    // `ciFeatureResponseSynthesisKey` toggle). A run synthesizes only when the key
    // matching ITS provider family is on: an IC-sized cleanup pass measurably helps
    // small local models, but behind a large cloud model it compresses a better
    // answer than it produces. Default false — synthesis is never automatic.
    static let ciFeatureResponseSynthesisMLXKey = "ciFeatureResponseSynthesisMLX"
    static let ciFeatureResponseSynthesisOllamaKey = "ciFeatureResponseSynthesisOllama"
    static let ciFeatureResponseSynthesisRemoteKey = "ciFeatureResponseSynthesisRemote"
    /// One-shot guard so the legacy → per-family seeding runs exactly once.
    static let ciSynthPerProviderMigratedKey = "ciSynthPerProviderMigrated"

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
    static let chatFontSizeKey = "chatFontSize"
    static let chatLineSpacingKey = "chatLineSpacing"

    // Jarvis — the voice HUD.
    // ⚠️ Key VALUES must stay free of "key"/"token"/"secret"/"auth"/"path": `BundleExporter`'s
    // allowlist is asserted by `ObservabilityHygieneTests.testAllowlistContainsNothingSecretShaped`,
    // which matches on the value, not the symbol. Hence `jarvisShortcutCode`, not `…KeyCode`.
    static let jarvisEnabledKey = "jarvisEnabled"
    static let jarvisActivationModeKey = "jarvisActivationMode"
    static let jarvisShortcutCodeKey = "jarvisShortcutCode"
    static let jarvisShortcutModifiersKey = "jarvisShortcutModifiers"
    static let jarvisEndpointingKey = "jarvisEndpointing"
    static let jarvisSpokenResponsesKey = "jarvisSpokenResponses"
    static let jarvisFollowUpKey = "jarvisFollowUp"
    static let jarvisEarconsKey = "jarvisEarcons"
    static let jarvisToolApprovalsKey = "jarvisToolApprovals"
    /// Developer-mode escape hatch for the Phase 4 duplex audio graph. Default OFF.
    static let jarvisDuplexAudioKey = "jarvisDuplexAudio"
    // [Phase 6 · F3] Ambient run-completion announcements.
    static let jarvisAmbientAnnouncementsKey = "jarvisAmbientAnnouncements"
    static let jarvisAmbientThresholdKey = "jarvisAmbientThresholdSeconds"
    // [Phase 6 · F2] Spoken tool approvals.
    static let jarvisVoiceApprovalsKey = "jarvisVoiceApprovals"
    // ⚠️ DELIBERATELY NOT IN `BundleExporter.exportablePreferenceKeys`. These two hold free-form
    // text the USER TYPED, and that allowlist's contract is that none of its entries carry user
    // content. The diagnostic value is near zero — which words were configured is inferable from
    // the approval log lines, which already record counts rather than content.
    static let jarvisApprovalKeywordsKey = "jarvisApprovalKeywords"
    static let jarvisDenialKeywordsKey = "jarvisDenialKeywords"
    /// Which speech recognizer Jarvis uses. Developer-mode until device-proven. Default WhisperKit.
    static let jarvisRecognizerKey = "jarvisRecognizer"
    /// Locale for Apple Speech. Empty = follow the system. ⚠️ Apple's models are per-LOCALE and
    /// must be reserved + installed before use, so this is a model choice, not a preference.
    static let jarvisSpeechLocaleKey = "jarvisSpeechLocale"
    /// Empty string is the sentinel for "same voice as chat Read Aloud" — see JarvisVoiceOutput.
    static let jarvisNarratorVoiceKey = "jarvisNarratorVoice"
    static let jarvisNarratorRateKey = "jarvisNarratorRate"
    /// ⚠️ Pre-existing value, written by JarvisSessionController since the MVP. The STRING must
    /// not change or every user silently loses their remembered profile.
    static let jarvisProfileIDKey = "jarvisProfileID"

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

    // ChatOps — Discord
    static let chatOpsDiscordBotTokenKey = "chatOpsDiscordBotToken"
    static let chatOpsDiscordChannelIDKey = "chatOpsDiscordChannelID"
    static let chatOpsDiscordApplicationIDKey = "chatOpsDiscordApplicationID"
    static let chatOpsDiscordGuildIDKey = "chatOpsDiscordGuildID"
    static let chatOpsDiscordEnabledKey = "chatOpsDiscordEnabled"
    static let chatOpsDiscordActiveConversationIDKey = "chatOpsDiscordActiveConversationID"

    // Developer Mode
    static let developerModeKey = "developerMode"

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

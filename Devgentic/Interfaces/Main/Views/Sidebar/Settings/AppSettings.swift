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

    // Agent View
    static let agentViewVariantKey = "agentViewVariant"

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
    static let ciFeatureResponseSynthesisKey = "ciFeatureResponseSynthesis"
    static let ciFeatureHistoryCompactionKey = "ciFeatureHistoryCompaction"
    static let ciCustomPromptKey = "ciCustomPrompt"

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

    // Chat Font
    static let chatFontSizeKey = "chatFontSize"
    static let chatLineSpacingKey = "chatLineSpacing"

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

enum AgentViewVariant: String, Codable, CaseIterable, Identifiable {
    case dynamicIsland = "Dynamic Island"
    case timeline = "Timeline"
    
    var id: String { self.rawValue }
}

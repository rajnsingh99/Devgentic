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
}

enum AgentViewVariant: String, Codable, CaseIterable, Identifiable {
    case dynamicIsland = "Dynamic Island"
    case timeline = "Timeline"
    
    var id: String { self.rawValue }
}

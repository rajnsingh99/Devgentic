// Models/SettingsKeys.swift
import Foundation

// MARK: - UserDefaults Keys (for @AppStorage and manual access)
struct SettingsKeys {
    // --- Existing Keys ---
    static let selectedBackend = "selectedBackend"
    static let windowOpacity = "windowOpacity"
    static let llmModelName = "llmModelName"
    static let agentBaseURL = "agentBaseURL"
    static let agentDelegationStrategy = "agentDelegationStrategy"
    static let isOnboardingComplete = "isOnboardingComplete"

    // --- Ollama Advanced Parameters ---
    static let ollamaTemperature = "ollamaTemperature"
    static let ollamaTopK = "ollamaTopK"
    static let ollamaTopP = "ollamaTopP"
    static let ollamaRepeatPenalty = "ollamaRepeatPenalty"
    static let ollamaContextWindowSize = "ollamaContextWindowSize"
    static let ollamaGpuLayers = "ollamaGpuLayers"
    
    // --- Quick Access ---
    static let quickAccessOverlayConversationId = "quickAccessOverlayConversationId"
    static let quickAccessLastCloseTime = "quickAccessLastCloseTime"
    static let quickAccessWasExpandedOnClose = "quickAccessWasExpandedOnClose"
    
    // --- NEW: Notification Name ---
    /// Notification posted to request the AppDelegate show the Quick Access Panel.
    static let showQuickAccessPanelNotification = Notification.Name("devgentic.showQuickAccessPanel")
    // --- End New Notification Name ---
}

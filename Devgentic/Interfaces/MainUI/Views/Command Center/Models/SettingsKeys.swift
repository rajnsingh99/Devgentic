//
//  SettingsKeys.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import Foundation

// MARK: - UserDefaults Keys (for @AppStorage and manual access)
struct SettingsKeys {
    // --- Existing Keys ---
    static let selectedBackend = "selectedBackend"
    static let windowOpacity = "windowOpacity"
    // Note: llmModelName is used by OllamaService
    static let llmModelName = "llmModelName"
    static let agentBaseURL = "agentBaseURL"
    static let agentDelegationStrategy = "agentDelegationStrategy"
    static let isOnboardingComplete = "isOnboardingComplete"
    static let defaultAgentModel = "defaultAgentModel"
    static let agentPID = "agentPID"
    static let venvPythonPath = "venvPythonPath"
    static let venvName = "devgentic"
    
    // --- Ollama Advanced Parameters ---
    static let ollamaTemperature = "ollamaTemperature"
    static let ollamaTopK = "ollamaTopK"
    static let ollamaTopP = "ollamaTopP"
    static let ollamaRepeatPenalty = "ollamaRepeatPenalty"
    static let ollamaContextWindowSize = "ollamaContextWindowSize"
    static let ollamaGpuLayers = "ollamaGpuLayers"
    
    // --- Ollama File Handling Parameters ---
    // Phase 1 Keys
    static let ollamaMaxInlineChars = "ollamaMaxInlineChars"
    static let ollamaMaxAttachedFiles = "ollamaMaxAttachedFiles"
    
    // NEW: Phase 2 Keys for Strategies
    static let ollamaTextFileInclusionStrategy = "ollamaTextFileInclusionStrategy"
    static let ollamaImageHandlingStrategy = "ollamaImageHandlingStrategy"
    static let ollamaBinaryFileHandlingStrategy = "ollamaBinaryFileHandlingStrategy"

    // --- Quick Access ---
    static let quickAccessOverlayConversationId = "quickAccessOverlayConversationId"
    static let quickAccessLastCloseTime = "quickAccessLastCloseTime"
    static let quickAccessWasExpandedOnClose = "quickAccessWasExpandedOnClose"
    
    // --- Notification Name ---
    /// Notification posted to request the AppDelegate show the Quick Access Panel.
    static let showQuickAccessPanelNotification = Notification.Name("devgentic.showQuickAccessPanel")
}

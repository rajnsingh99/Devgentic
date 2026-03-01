//
//  GlobalConstants.swift
//  Devgentic
//
//  Created by Raj Singh
//

import Foundation


struct GlobalConstants {
    
    // --- Onboarding ---
    static let llmModelName = "llmModelName"
    static let agentBaseURL = "agentBaseURL"
    static let isOnboardingComplete = "isOnboardingComplete"
    static let defaultAgentModel = "defaultAgentModel"
    static let agentPID = "agentPID"
    static let venvPythonPath = "venvPythonPath"
    static let venvName = "devgentic"

    // --- Quick Access ---
    static let quickAccessOverlayConversationId = "quickAccessOverlayConversationId"
    static let quickAccessLastCloseTime = "quickAccessLastCloseTime"
    static let quickAccessWasExpandedOnClose = "quickAccessWasExpandedOnClose"
    
    // --- Backend ---
    static let selectedBackend = "selectedBackend"
    static let agentEndpoint = "/agent/chat"
    
    // --- Notification Name ---
    static let showQuickAccessPanelNotification = Notification.Name("devgentic.showQuickAccessPanel")

    // --- Speech Notifications ---
    static let toggleVoiceInputNotification = Notification.Name("devgentic.toggleVoiceInput")
    static let speechModelChangedNotification = Notification.Name("devgentic.speechModelChanged")
    static let speechLanguageChangedNotification = Notification.Name("devgentic.speechLanguageChanged")
    static let speechAutoStopChangedNotification = Notification.Name("devgentic.speechAutoStopChanged")
}

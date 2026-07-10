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
    /// [QA revival P1b] The remembered QuickAccess profile (a chat-type profile UUID). Kept
    /// separate from the main window's selection so the panel has its own sticky default.
    static let quickAccessProfileID = "quickAccessProfileID"
    /// [QA revival P1d] Panel enable flag + configurable global hotkey (Carbon key code +
    /// modifiers) + session-timeout, all read by AppDelegate before the SwiftUI env exists.
    static let quickAccessEnabled = "quickAccessEnabled"
    static let quickAccessHotkeyKeyCode = "quickAccessHotkeyKeyCode"
    static let quickAccessHotkeyModifiers = "quickAccessHotkeyModifiers"
    // Stored in SECONDS (10s–5min range, default 60). New key so old minute-valued data isn't
    // misread as seconds.
    static let quickAccessSessionTimeoutSeconds = "quickAccessSessionTimeoutSeconds"
    
    // --- Backend ---
    static let selectedBackend = "selectedBackend"
    static let agentEndpoint = "/agent/chat"
    
    // --- Diagnostics / Bug Reports ---
    /// Public issue-tracker "new issue" URL the "Report on GitHub" button in the diagnostic
    /// export opens, with `?title=&body=` query params (GitHub's new-issue format).
    /// **Set this to your public repo when you create it** — e.g.
    /// "https://github.com/<owner>/<repo>/issues/new". The app's own git remote is a private
    /// Bitbucket repo, so this is a placeholder until a public tracker exists.
    static let issueTrackerNewIssueURL = "https://github.com/devgentic/devgentic/issues/new"

    // --- Notification Name ---
    static let showQuickAccessPanelNotification = Notification.Name("devgentic.showQuickAccessPanel")
    /// [QA revival P2e] Navigate the main window to a conversation (userInfo["conversationID"]
    /// = UUID string). Posted by a notification tap (AppDelegate) and by the panel's
    /// "continue in main window" reverse-handoff. Observed in MainApplicationView.
    static let openConversationNotification = Notification.Name("devgentic.openConversation")

    // --- Speech Notifications ---
    static let toggleVoiceInputNotification = Notification.Name("devgentic.toggleVoiceInput")
    static let speechModelChangedNotification = Notification.Name("devgentic.speechModelChanged")
    static let speechLanguageChangedNotification = Notification.Name("devgentic.speechLanguageChanged")
    static let speechAutoStopChangedNotification = Notification.Name("devgentic.speechAutoStopChanged")
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    /// ⚠️ This is a PUBLIC destination: whatever the export sheet puts in the query params is
    /// pre-filled into an issue body on github.com. The bundle itself is attached by hand — only
    /// the title and a short body travel through this URL.
    static let issueTrackerNewIssueURL = "https://github.com/rajnsingh99/devgentic/issues/new"

    /// The project's public homepage — a GitHub Pages project site, live from the first release.
    ///
    /// Sent to OpenRouter as `HTTP-Referer` for app attribution (see `AgentConnect`). It is a
    /// STATIC project identifier, not telemetry: no user or machine data is derived from it, and
    /// the app already identifies itself to that provider via `X-Title`.
    ///
    /// ⚠️ Tied to the GitHub account and repo name, because GitHub Pages derives the URL from
    /// them. Attaching a custom domain later does NOT require changing this — GitHub 301-redirects
    /// this path — but RENAMING the account or repo breaks it, and breaks the Sparkle feed with it.
    static let homepageURL = "https://rajnsingh99.github.io/devgentic/"

    // --- Notification Name ---
    static let showQuickAccessPanelNotification = Notification.Name("devgentic.showQuickAccessPanel")
    /// [QA revival P2e] Navigate the main window to a conversation (userInfo["conversationID"]
    /// = UUID string). Posted by a notification tap (AppDelegate) and by the panel's
    /// "continue in main window" reverse-handoff. Observed in MainApplicationView.
    static let openConversationNotification = Notification.Name("devgentic.openConversation")
    /// Navigate the main window to a profile's editor (userInfo["profileID"] = UUID
    /// string). Posted by surfaces outside the main window's environment — e.g. the
    /// QuickAccess panel's advisory banner settings action — after activating the
    /// main window. Observed in MainApplicationView, translated into the router.
    static let openProfileSettingsNotification = Notification.Name("devgentic.openProfileSettings")

    // --- Speech Notifications ---
    static let toggleVoiceInputNotification = Notification.Name("devgentic.toggleVoiceInput")
    static let speechModelChangedNotification = Notification.Name("devgentic.speechModelChanged")
    static let speechLanguageChangedNotification = Notification.Name("devgentic.speechLanguageChanged")
    static let speechAutoStopChangedNotification = Notification.Name("devgentic.speechAutoStopChanged")
}

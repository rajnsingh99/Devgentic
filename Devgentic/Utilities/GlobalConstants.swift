// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GlobalConstants.swift
//  Devgentic
//
//  Created by Raj Singh.
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
    // Why: this is a public destination: only a title and short body travel in the URL; the bundle is attached by hand.
    /// Public issue-tracker new-issue URL opened by the diagnostic export's "Report on GitHub" button.
    /// Takes `?title=&body=` query params (GitHub's new-issue format).
    static let issueTrackerNewIssueURL = "https://github.com/rajnsingh99/devgentic/issues/new"

    // Why: tied to the GitHub account and repo name; renaming either breaks it and the Sparkle feed.
    /// The project's public homepage (a GitHub Pages site), also sent to OpenRouter as `HTTP-Referer` for app attribution.
    /// A static project identifier, not telemetry: no user or machine data is derived from it.
    static let homepageURL = "https://rajnsingh99.github.io/devgentic/"

    // Why: tied to the account and repo name like `homepageURL`: a rename breaks both.
    /// The public source repository: the AGPL "Corresponding Source" offer, as a URL.
    /// Read by the ChatOps `/help` reply so every operator of a modified build offers its source to remote users.
    static let sourceCodeURL = "https://github.com/rajnsingh99/devgentic"

    // Why: an App Store edition must strip every use of this: Apple rejects external tipping links.
    /// The GitHub Sponsors page behind "Support Development": a tip jar, not a paywall.
    /// Surfaces hide themselves while this is empty; to use another page, change this string and `.github/FUNDING.yml`.
    /// Wording is "Support", never "Donate", and never a nag (no launch popup, modal or badge).
    static let supportURL = "https://github.com/sponsors/rajnsingh99"

    /// `supportURL` as a URL, or nil while it is unset — the one gate all support UI reads.
    static var supportLink: URL? {
        supportURL.isEmpty ? nil : URL(string: supportURL)
    }

    // --- Notification Name ---
    static let showQuickAccessPanelNotification = Notification.Name("devgentic.showQuickAccessPanel")
    /// [QA revival P2e] Navigate the main window to a conversation (userInfo["conversationID"]
    /// = UUID string). Posted by a notification tap (AppDelegate) and by the panel's
    /// "continue in main window" reverse-handoff. Observed in MainApplicationView.
    static let openConversationNotification = Notification.Name("devgentic.openConversation")
    /// Navigates the main window to a profile's editor (`userInfo["profileID"]` = UUID string).
    /// Posted by surfaces outside the main window's environment, e.g. QuickAccess's advisory banner, after activating it.
    /// Observed in MainApplicationView and translated into the router.
    static let openProfileSettingsNotification = Notification.Name("devgentic.openProfileSettings")

    // --- Speech Notifications ---
    static let toggleVoiceInputNotification = Notification.Name("devgentic.toggleVoiceInput")
    static let speechModelChangedNotification = Notification.Name("devgentic.speechModelChanged")
    static let speechLanguageChangedNotification = Notification.Name("devgentic.speechLanguageChanged")
    static let speechAutoStopChangedNotification = Notification.Name("devgentic.speechAutoStopChanged")
}

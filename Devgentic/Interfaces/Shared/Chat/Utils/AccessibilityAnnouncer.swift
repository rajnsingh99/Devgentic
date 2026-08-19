//
//  AccessibilityAnnouncer.swift
//  Devgentic
//
//  VoiceOver only speaks what it is focused on. Everything this app does *to* the user
//  rather than *for* them — an agent blocking on a permission prompt, an error appearing
//  mid-conversation, an auto-reject timer running out — happens somewhere the cursor isn't,
//  and so happened in silence.
//
//  Nothing in the codebase posted an announcement before this (zero hits repo-wide for
//  AccessibilityNotification / NSAccessibility.post). The worst case it fixes: a HITL gate
//  appears, says nothing, counts down invisibly, and auto-rejects the user's own agent.
//

import SwiftUI
import AppKit
import os

private let logger = DGLogger(category: "A11yAnnouncer")

enum AccessibilityAnnouncer {

    /// How insistently VoiceOver should deliver this.
    enum Urgency {
        /// Waits for the current utterance to finish. For anything the user can ignore.
        case polite
        /// Interrupts. Reserved for things the user must act on NOW — a blocked agent, a
        /// running deadline. Overusing this makes the app hostile to listen to.
        case immediate

        var priority: NSAccessibilityPriorityLevel {
            switch self {
            case .polite: return .medium
            case .immediate: return .high
            }
        }
    }

    /// True when VoiceOver (or another assistive client) is actually listening.
    ///
    /// Guarded so we don't build announcement strings for the overwhelmingly common case
    /// where nobody is listening.
    static var isScreenReaderRunning: Bool {
        NSWorkspace.shared.isVoiceOverEnabled
    }

    /// Speaks `message` without moving VoiceOver's cursor.
    ///
    /// Posted against the key window: AppKit routes announcements through an element, and a
    /// nil/unfocused element silently drops them.
    @MainActor
    static func announce(_ message: String, urgency: Urgency = .polite) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard isScreenReaderRunning else { return }

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else {
            logger.debug("Skipped announcement — no window to post from: \(text)")
            return
        }

        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: urgency.priority.rawValue
            ]
        )
        logger.debug("📢 Announced (\(urgency == .immediate ? "immediate" : "polite")): \(text)")
    }
}

// NOTE: a `View.announceOnAppear(_:urgency:message:)` convenience lived here and was deleted
// on 2026-08-11 — it had ZERO call sites since the day it was written. Every announcement site
// (ChatSearchBar, ErrorMessageView, InteractionBannerStack ×2) calls `announce` directly from
// its own `.task(id:)`/`.onChange`, which is the same amount of code. Re-add it only when
// something actually adopts it.

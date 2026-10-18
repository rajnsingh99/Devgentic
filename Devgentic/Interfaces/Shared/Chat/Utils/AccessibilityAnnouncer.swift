// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AccessibilityAnnouncer.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit
import os

private let logger = DGLogger(category: "A11yAnnouncer")

/// Posts VoiceOver announcements for things the app does to the user rather than for them, such as a HITL gate or an
/// error appearing.
/// VoiceOver only speaks what has focus, so these events would otherwise happen in silence.
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
    /// Guarded so announcement strings are not built when nobody is listening.
    static var isScreenReaderRunning: Bool {
        NSWorkspace.shared.isVoiceOverEnabled
    }

    /// Speaks `message` without moving VoiceOver's cursor, posted against the key window since a nil element drops it.
    /// Returns whether it was actually posted, so callers do not record something nobody heard.
    @MainActor
    @discardableResult
    static func announce(_ message: String, urgency: Urgency = .polite) -> Bool {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard isScreenReaderRunning else { return false }

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else {
            logger.debug("Skipped announcement — no window to post from: \(text)")
            return false
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
        return true
    }

    // MARK: - Repeat suppression
    // Some announcement sites fire on view appearance in a LazyVStack that rebuilds constantly, so repeats within a window
    // are suppressed.

    /// How long the same key stays spoken-for: 300 s, enough to cover rebuild storms (scrolling, conversation switches).
    /// Within the window an identical key is silent whatever produced it, so callers pass a key carrying the site's
    /// identity.
    static let repeatSuppressionWindow: TimeInterval = 300

    /// Hard cap on remembered keys so a long session cannot grow this without bound; eviction is oldest-first.
    static let maxTrackedKeys = 32

    /// Maps key to when it was last actually spoken.
    /// Not scoped to a conversation or cleared on a switch: a switch is the biggest rebuild, so clearing would re-announce.
    @MainActor private static var lastAnnounced: [String: Date] = [:]

    /// Claims the right to speak `key` at `now`, recording it when granted.
    /// Split out because `announceOnce` no-ops when VoiceOver is off, which makes this the only testable form of the rule.
    @MainActor
    static func claimAnnouncement(key: String, at now: Date = Date()) -> Bool {
        lastAnnounced = lastAnnounced.filter { now.timeIntervalSince($0.value) < repeatSuppressionWindow }
        if let last = lastAnnounced[key], now.timeIntervalSince(last) < repeatSuppressionWindow {
            return false
        }
        if lastAnnounced.count >= maxTrackedKeys {
            let survivors = lastAnnounced.sorted { $0.value > $1.value }.prefix(maxTrackedKeys - 1)
            lastAnnounced = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
        }
        lastAnnounced[key] = now
        return true
    }

    /// Gives a claim back when nothing was actually spoken — otherwise a post that AppKit
    /// dropped (no window) would silence the next, successful attempt for the whole window.
    @MainActor
    static func releaseAnnouncement(key: String) {
        lastAnnounced.removeValue(forKey: key)
    }

    /// Test seam. Not called from app code — the registry is meant to survive conversation
    /// switches (see `lastAnnounced`).
    @MainActor
    static func resetRepeatSuppressionForTesting() {
        lastAnnounced.removeAll()
    }

    /// Speaks `message` at most once per `repeatSuppressionWindow` for the given `key`.
    /// For sites driven by view appearance; pass a key identifying the thing announced (an id), not its wording.
    @MainActor
    static func announceOnce(_ message: String, key: String, urgency: Urgency = .polite) {
        guard isScreenReaderRunning else { return }
        guard claimAnnouncement(key: key) else {
            logger.debug("📢 Suppressed a repeat announcement within the \(Int(repeatSuppressionWindow))s window. CONSEQUENCE: nothing is spoken now; the content is unchanged on screen and still read when the VoiceOver cursor reaches it. Key: \(key)")
            return
        }
        if !announce(message, urgency: urgency) {
            // Nothing was posted, so nothing has been said — don't hold the claim.
            releaseAnnouncement(key: key)
        }
    }
}

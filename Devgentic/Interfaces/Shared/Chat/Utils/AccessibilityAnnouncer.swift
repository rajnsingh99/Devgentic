// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    ///
    /// Returns whether the announcement was actually posted, so a caller that is tracking what
    /// it has already said doesn't record something nobody heard.
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
    //
    // Some announcement sites fire from a view's APPEARANCE (`.task(id:)`), not from an event.
    // The chat transcript is a LazyVStack, so those views are built and rebuilt constantly —
    // scrolling a row back into view, switching conversations, re-rendering a bubble. Without
    // state here, each rebuild re-posts the same sentence, and a days-old error card is spoken
    // as if the failure were happening now (CF-40).

    /// How long the same key stays spoken-for.
    ///
    /// 300s. A rebuild storm (scroll, conversation switch, body re-eval) is seconds, so five
    /// minutes covers those with room to spare.
    ///
    /// ⚠️ The cost, stated plainly because the comment that used to sit here claimed the
    /// opposite: inside the window an identical sentence is silent NO MATTER WHAT PRODUCED IT.
    /// A retry that fails the same way, a second image in one message failing for the same
    /// reason, several workflow nodes failing with identical text — this rule cannot tell any of
    /// them from a rebuild, because the key it is handed is the sentence and a sentence carries
    /// no identity. Shortening the window does NOT fix that; it only trades a silenced
    /// recurrence back for the re-announced historical card CF-40 exists to stop.
    ///
    /// The fix is a key carrying the announcing site's identity, supplied by the CALLER:
    /// `ErrorMessageView` takes an optional `announcementKey`, and `MediaArtifactImageView`
    /// passes the artifact id plus a Retry-incremented attempt counter, so a retry that fails
    /// identically speaks again. Callers that pass nil still key on the sentence and still have
    /// the limitation above. No production caller does today: `MediaArtifactImageView` passes the
    /// artifact id + attempt, and the agent `.error` card passes the message id +
    /// `generationAttempts`, which Retry increments.
    static let repeatSuppressionWindow: TimeInterval = 300

    /// Hard cap on remembered keys, so a long session with many distinct announcements cannot
    /// grow this without bound. 32 — comfortably more distinct announcements than one 5-minute
    /// window plausibly holds; eviction is oldest-first, which is also the entry least likely to
    /// still be being re-posted by a rebuild.
    static let maxTrackedKeys = 32

    /// key -> when it was last actually spoken.
    ///
    /// ⚠️ Keyed by the announcement's own text and deliberately NOT scoped to a conversation or
    /// cleared when one is switched: a conversation switch is the single biggest rebuild, and
    /// clearing there would re-introduce exactly the defect this exists to stop. The cost is
    /// that an identical sentence in a DIFFERENT conversation within the window stays silent —
    /// bounded by the window and the cap, and the card itself is still read normally when the
    /// VoiceOver cursor reaches it.
    @MainActor private static var lastAnnounced: [String: Date] = [:]

    /// Claims the right to speak `key` at `now`, recording it when granted.
    ///
    /// Split out from `announceOnce` because `announceOnce` no-ops entirely when VoiceOver is
    /// off — which is every test environment — so this is the only testable form of the rule.
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
    ///
    /// For announcement sites driven by view appearance rather than by an event. Pass a key that
    /// identifies the THING being announced — an id, not its wording. ⚠️ A key derived from the
    /// message text makes every recurrence look like a rebuild; see `repeatSuppressionWindow`.
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

// NOTE: a `View.announceOnAppear(_:urgency:message:)` convenience lived here and was deleted
// on 2026-08-11 — it had ZERO call sites since the day it was written. Every announcement site
// (ChatSearchBar, InteractionBannerStack ×2 — and ErrorMessageView via `announceOnce`) calls
// this enum directly from its own `.task(id:)`/`.onChange`, which is the same amount of code.
// Re-add it only when something actually adopts it — and note that an "on appear" helper is
// precisely the shape that produced CF-40.

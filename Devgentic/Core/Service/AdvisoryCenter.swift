// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AdvisoryCenter.swift
//  Devgentic
//
//  Created on 12/07/26.
//
//  Non-blocking, actionable notices about AMBIENT conversation state — rendered
//  as a compact banner between the HITL stack and the chat input (HITL top,
//  advisory mid, input bottom). Deliberately separate from InteractionCenter:
//  HITL is blocking request/response with a durable audit; advisories are
//  dismissible, ephemeral, and update in place.
//
//  Lifecycle rules that keep the banner un-annoying:
//  - One advisory surfaced per conversation (highest = latest posted).
//  - Same dedupe key → update-in-place, never stacks.
//  - Dismiss suppresses that dedupe key until the underlying inputs change
//    (the key encodes them — e.g. profile + effective window).
//  - Callers clear the category when the condition resolves, so the banner
//    disappears on its own once a turn fits / the profile changes.
//

import Foundation

/// A single non-blocking notice with an optional navigation action.
struct Advisory: Identifiable, Equatable {
    enum Category: String {
        /// Assembled prompt exceeds the model's effective context window.
        case contextOverflow
        /// The vector store did not open, so retrieval is returning nothing for this conversation.
        /// ⚠️ Post this ONLY on `!VectorStoreService.shared.isAvailable` — never on "0 results".
        /// `retrieveRAGContext` returns nil for four different reasons, three of them healthy (no
        /// embedding, nothing above threshold, all hits were history duplicates), and those are the
        /// COMMON case early in a conversation. Bannering on nil would fire constantly, train the
        /// user to dismiss, and `dismiss` suppresses the key for the whole session — one reflexive
        /// dismissal would then disarm the real signal permanently.
        case knowledgeUnavailable
        /// The vector store hit its size cap: new conversation memory is not being saved (RAG-13).
        case knowledgeStoreFull
        /// A save of the shared SwiftData context failed, so changes may not be reaching disk
        /// (`SharedContextSave`, RAG-27). Posted for `Advisory.allConversations`.
        case changesNotSaved
        /// The selected profile's stored configuration could not be decoded, so the app is showing a
        /// placeholder rather than what the user configured.
        case profileUnreadable
        /// The selected agent/bot has no system instructions. Register B14.
        ///
        /// ⚠️ This category exists because `ProfileValidator`'s `.advisory` for missing
        /// instructions had **no reachable surface**. The save-advisory banner (A34) lives in the
        /// three editors, and both editors that could generate this finding hard-block the save
        /// before `saveProfile` is ever called — so the only paths that actually produce it are
        /// the out-of-band writers (the thinking auto-heal, the capability chips, the Tool
        /// Library, the quit-time save), every one of which discards the returned array.
        /// The finding was real, correctly computed, and structurally invisible.
        ///
        /// Chat is the right surface precisely because it is where the consequence lands: an agent
        /// with no instructions is about to answer with no guidance at all.
        case profileMissingInstructions
        /// A run in this conversation is waiting for the local model, which another run holds (local
        /// inference coordinator). Posted only after a short wait, cleared when the run starts or is
        /// withdrawn. Plain status — it names the holder and says nothing about what to do.
        case localModelBusy
        /// A run in this conversation is held until its user chooses Proceed or Stop (local inference
        /// coordinator, phase 7) — auto-denied at the deadline. The one advisory that asks.
        case runNeedsConfirmation
        /// A run in this conversation is waiting for the conversation's CURRENT run to finish (one run
        /// per conversation, `ConversationAdmission`). Plain status.
        case conversationQueue
    }

    /// How the banner reads: a warning, or plain status.
    enum Tone: Equatable {
        case warning
        case info
    }

    /// Run-state banners (queued, asking) outrank ambient ones: a fit hint posted while the user
    /// types must not hide the fact that their run is waiting (phase 7).
    static let runStatePriority = 10
    static let runQuestionPriority = 20

    enum Action: Equatable {
        /// Deep-link to the profile editor (router `.profileDetail`).
        case openProfileSettings(profileID: UUID)
        /// Reveal a path in Finder — for states the app cannot fix in-process and the user may want
        /// to inspect or move aside (the vector store has no re-open path: `static let shared` with a
        /// `private init`, so recovery is quit-and-relaunch).
        case revealInFinder(path: String)
        /// Phase 7: let the held run go ahead.
        case proceedRun(messageID: UUID)
        /// Phase 7: stop the held run — the same as the composer's Stop.
        case stopRun(messageID: UUID)
    }

    /// Sentinel `conversationID` for a condition of the whole app rather than of one conversation
    /// (a store that cannot save): `AdvisoryCenter.current(for:)` returns it in EVERY conversation.
    static let allConversations = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    let id = UUID()
    let conversationID: UUID
    let category: Category
    let message: String
    let actionLabel: String?
    let action: Action?
    /// Encodes the condition's inputs (e.g. "conv|category|profile|window") —
    /// identical key means "same situation": update in place, honor dismissal.
    let dedupeKey: String
    /// A second button (phase 7: Stop beside Proceed).
    var secondaryActionLabel: String? = nil
    var secondaryAction: Action? = nil
    var tone: Tone = .warning
    /// When set, the banner shows a live countdown to it, introduced by `deadlineLabel`.
    var deadline: Date? = nil
    var deadlineLabel: String? = nil
    /// Run-state banners cannot be dismissed: they go away when the state does.
    var dismissible: Bool = true
    /// The banner shows the highest priority, then the latest posted.
    var priority: Int = 0
}

@MainActor
@Observable
final class AdvisoryCenter {

    static let shared = AdvisoryCenter()

    private(set) var advisories: [Advisory] = []

    /// Dedupe keys the user dismissed — suppressed until the situation changes
    /// (a changed profile/window produces a different key). Session-scoped:
    /// unlike HITL there is nothing to audit or restore.
    private var dismissedKeys: Set<String> = []

    /// Internal (not private) so tests can build isolated instances; the app
    /// itself always goes through `.shared`.
    init() {}

    /// The one advisory the banner shows for a conversation: the highest priority, then the latest
    /// posted.
    func current(for conversationID: UUID) -> Advisory? {
        advisories.enumerated()
            .filter { $0.element.conversationID == conversationID || $0.element.conversationID == Advisory.allConversations }
            .max { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }?
            .element
    }

    /// Post or update-in-place; silently ignored while its dedupe key is dismissed.
    func post(_ advisory: Advisory) {
        guard !dismissedKeys.contains(advisory.dedupeKey) else { return }
        if let index = advisories.firstIndex(where: { $0.dedupeKey == advisory.dedupeKey }) {
            advisories[index] = advisory
        } else {
            advisories.append(advisory)
        }
    }

    /// User dismissed the banner: remove it and suppress its exact situation.
    func dismiss(_ advisory: Advisory) {
        guard advisory.dismissible else { return }
        advisories.removeAll { $0.id == advisory.id }
        dismissedKeys.insert(advisory.dedupeKey)
    }

    /// Condition resolved (e.g. this turn's prompt fits): drop the category's
    /// advisories for the conversation so the banner self-heals.
    func clear(category: Advisory.Category, conversationID: UUID) {
        advisories.removeAll { $0.category == category && $0.conversationID == conversationID }
    }
}

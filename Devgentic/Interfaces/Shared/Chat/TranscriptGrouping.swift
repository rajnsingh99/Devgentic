// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TranscriptGrouping.swift
//  Devgentic
//
//  Which messages the transcript draws as ONE turn (2026-09-27, user decision).
//
//  ⚠️ Why. A background task's report is stored as a machine-written "user" stub plus an agent
//  reply — the stub is load-bearing (the history walk drops an agent row with no user row in front;
//  see `ChatMessage.isSyntheticPrompt`). Drawn as stored, every report looked like a new exchange
//  nobody started: a ruled divider, its own "Thought for N steps" header, its own action bar.
//
//  ⚠️ DISPLAY ONLY. Nothing here changes what is stored or what the model sees; it only decides how
//  the transcript draws what is already there, so existing conversations regroup on load.
//
//  The rule: a GROUP is one human turn's reply plus every unprompted turn (a report today, a
//  sub-agent's result later) that follows it until the next human message. Continuations join the
//  group at the BOTTOM, in time order — the order the model sees — even when the task that produced
//  them was started by an earlier turn. Inside a group:
//    • the stub is not drawn; the report's timeline header carries it ("↳ … finished · 3 steps")
//    • ONE action bar, after the last message of the group, acting for the human turn
//    • reports from tasks an EARLIER attempt of the head started (the head was redone since) fold
//      under one row, so they don't read as answers to the attempt on screen
//

import Foundation

enum TranscriptGrouping {

    enum Role: Equatable {
        /// Drawn as it always was.
        case plain
        /// A human turn's reply followed by continuations: its own action bar is withheld and the
        /// group's is drawn after `groupEndID`.
        case head(groupEndID: UUID)
        case continuation(Continuation)
        /// A wake stub with no human turn in front (the conversation starts with it): nothing to
        /// continue, so it keeps the standalone divider.
        case orphanStub
    }

    struct Continuation: Equatable {
        let headID: UUID
        /// The stub this continuation hangs from — itself, for a stub.
        let stubID: UUID
        let isStub: Bool
        /// For a stub: whether its report follows. A stub whose report has not started yet (the
        /// wake is queued behind a run) is drawn as a lone lead row; otherwise the report draws it.
        let hasReport: Bool
        /// The group's action bar is drawn after this message.
        var isGroupEnd: Bool
        /// Non-nil when the task was started by an earlier attempt of the head.
        var fold: Fold?
    }

    struct Fold: Equatable {
        /// The first folded message of the group — the one that draws the fold row.
        let isFirst: Bool
        /// Folded REPORTS (stub + reply pairs count once) in the group.
        let count: Int
    }

    /// - Parameter oldestFirst: the transcript in display order.
    @MainActor
    static func roles(oldestFirst messages: [ChatMessage]) -> [UUID: Role] {
        var roles: [UUID: Role] = [:]
        var head: ChatMessage?
        var members: [UUID: [UUID]] = [:]          // head id → continuation ids, in order
        var previous: ChatMessage?

        for message in messages {
            defer { previous = message }
            if message.sender == .user {
                if isWakeStub(message) {
                    guard let head else { roles[message.id] = .orphanStub; continue }
                    roles[message.id] = .continuation(Continuation(
                        headID: head.id, stubID: message.id, isStub: true,
                        hasReport: false, isGroupEnd: false, fold: nil))
                    members[head.id, default: []].append(message.id)
                } else {
                    roles[message.id] = .plain
                    head = nil          // a human turn; its reply becomes the next head
                }
                continue
            }

            // An agent message. Behind a stub in a group → that stub's report.
            if let previous, case .continuation(var stub)? = roles[previous.id], stub.isStub {
                stub = Continuation(headID: stub.headID, stubID: stub.stubID, isStub: true,
                                    hasReport: true, isGroupEnd: false, fold: nil)
                roles[previous.id] = .continuation(stub)
                roles[message.id] = .continuation(Continuation(
                    headID: stub.headID, stubID: previous.id, isStub: false,
                    hasReport: true, isGroupEnd: false, fold: nil))
                members[stub.headID, default: []].append(message.id)
                continue
            }
            // Behind an orphan stub → drawn as before, and it starts nothing.
            if let previous, roles[previous.id] == .orphanStub {
                roles[message.id] = .plain
                continue
            }
            head = message
            roles[message.id] = .plain
        }

        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (headID, ids) in members {
            guard let last = ids.last, let headMessage = byID[headID] else { continue }
            roles[headID] = .head(groupEndID: last)

            // Earlier-attempt folding, decided per STUB and applied to its report too.
            let current = BackgroundTaskObserver.currentVariantID(of: headMessage)
            let foldedStubs = Set(ids.compactMap { id -> UUID? in
                guard let stub = byID[id], isWakeStub(stub),
                      isFromEarlierAttempt(stub: stub, head: headMessage, currentVariant: current) else { return nil }
                return id
            })
            var firstFolded = true
            for id in ids {
                guard case .continuation(var c)? = roles[id] else { continue }
                c.isGroupEnd = id == last
                if foldedStubs.contains(c.stubID) {
                    c.fold = Fold(isFirst: firstFolded, count: foldedStubs.count)
                    firstFolded = false
                }
                roles[id] = .continuation(c)
            }
        }
        return roles
    }

    /// A turn nobody typed. ⚠️ Keyed on `isSyntheticPrompt` ALONE, not on the background-task
    /// source: the transcript's invariant is that NO synthetic row is ever drawn as a user bubble,
    /// and every such row is routed from here — narrowing this would hand a future unprompted
    /// source (a sub-agent's result) straight to `ChatBubbleView`.
    @MainActor
    static func isWakeStub(_ message: ChatMessage) -> Bool {
        message.sender == .user && message.isSyntheticPrompt
    }

    /// Whether the task behind `stub` was started by an attempt of `head` other than the one on
    /// screen. Needs the stub's saved card (to name the log) and the head's card for that log (to
    /// name the attempt); anything older than either is treated as current — never folded away.
    @MainActor
    static func isFromEarlierAttempt(stub: ChatMessage, head: ChatMessage, currentVariant: UUID?) -> Bool {
        guard let currentVariant, let card = BackgroundTaskWakeCoordinator.reportCard(behind: stub) else { return false }
        let key = BackgroundTaskHistory.key(forLogPath: card.logPath)
        for event in head.flattenedTimelineEvents {
            if case .backgroundTask(let origin) = event, BackgroundTaskHistory.key(forLogPath: origin.logPath) == key {
                return origin.variantID.map { $0 != currentVariant } ?? false
            }
        }
        return false    // started by another turn's reply — not an attempt of this head
    }

    /// The lead-in a continuation's header shows: the stub's own words, which carry the
    /// authoritative status (read from the registry, not from the model's prose).
    @MainActor
    static func leadText(forStub stub: ChatMessage) -> String {
        let text = stub.content.textContent ?? ""
        return text.hasSuffix(".") ? String(text.dropLast()) : text
    }
}

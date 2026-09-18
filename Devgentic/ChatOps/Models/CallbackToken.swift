// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CallbackToken.swift
//  Devgentic
//
//  The wire payload behind a remote button — C2 of the ChatOps remote-interface plan.
//
//  ⚠️⚠️ THIS TYPE DOES NOT DEFINE THE GRAMMAR. IT TYPES THE ONE ALREADY SHIPPED.
//  `ChatOpsCommand.parseCallbackData` (ChatOpsCommand.swift:180) is the reader, it is live on all
//  three platforms, and the strings it accepts are already sitting in users' chat scrollback.
//  A button posted last week is still tappable today: re-cutting the grammar would make every one
//  of them decode as `.unknown` — a tap that silently does nothing. So every `wire` value below is
//  byte-identical to what the bridges emit now, and `CallbackTokenTests` round-trips each one
//  through the real parser rather than asserting the string shape in isolation.
//
//  ⚠️ THE 64-BYTE CEILING IS TELEGRAM'S, AND IT IS THE BINDING ONE. Telegram caps `callback_data`
//  at 64 bytes; Discord's `custom_id` allows 100 and Slack's `action_id` more still. Because the
//  grammar is shared across all three, Telegram's limit governs every case. The worst case today is
//  `hitl:approve:<uuid>` at 49 bytes, leaving 15 — see `CallbackTokenTests.testEveryTokenFitsTelegramsBudget`,
//  which is a standing probe rather than a one-off calculation.
//
//  ⚠️ WHAT THE HEADROOM MEANS FOR THE NEXT FEATURE. A canonical UUID is 36 bytes, so a token
//  carrying TWO of them cannot exist: `use:<profile>:<conversation>` is 77 bytes. The first feature
//  that needs one is per-node workflow approval, which must carry `(operationID, nodeID)`. The
//  answer is base64url — 16 raw bytes encode to 22 characters, taking that same token to 49 — but
//  it is a GRAMMAR CHANGE and therefore needs a legacy-decode window that accepts both forms for a
//  release. Do not reach for it to save bytes on a token that already fits.
//

import Foundation

/// A tappable action, as it travels over the wire and comes back.
enum CallbackToken: Equatable, Hashable, Sendable, Codable {

    /// `switch:<uuid>` — make this conversation the channel's active one.
    case switchConversation(UUID)

    /// `hitl:approve:<uuid>`
    case approveHITL(operationID: UUID)

    /// `hitl:deny:<uuid>`
    case denyHITL(operationID: UUID)

    /// `hitl:gate:<uuid>:<idx>`
    ///
    /// ⚠️ The INDEX travels, never the option label. Labels are user- and model-supplied and would
    /// blow the 64-byte budget on their own; the index is resolved back to a label by the mirror.
    case gateChoice(operationID: UUID, optionIndex: Int)

    /// `hitl:answer:<uuid>` — open a free-text answer for this parked clarification.
    ///
    /// ⚠️ 48 bytes, inside Telegram's binding 64. It joins the `hitl:` family deliberately: the
    /// grammar is shared across all three platforms and a new prefix is a new thing every parser
    /// must learn. Telegram does not emit this button — it force-replies instead, because it has no
    /// modal — but the token stays platform-neutral so Slack can reuse it unchanged.
    case answerClarification(operationID: UUID)

    /// `use:<uuid>` — bind this profile to the channel's conversation.
    ///
    /// ⚠️ 40 bytes, comfortably inside Telegram's 64. Note it carries the profile id ALONE: the
    /// conversation comes from the channel's cursor. A token naming both would be 77 bytes and
    /// could not exist — see this file's header.
    case selectProfile(UUID)

    /// `page:<offset>` — show the conversation list starting at this offset.
    ///
    /// ⚠️ AN OFFSET, NOT A PAGE NUMBER, and not a cursor. An offset is what the read model takes,
    /// so nothing has to translate; a page number would need the page SIZE to travel too, or be
    /// re-derived at the far end from a constant that could change between the button being posted
    /// and being tapped — a button in week-old scrollback would then jump somewhere unexpected.
    case conversationPage(offset: Int)

    /// `action:<name>` — the fixed verbs a button can invoke with no payload.
    case action(Action)

    /// ⚠️ Exactly the four `action:` strings `parseCallbackData` accepts (ChatOpsCommand.swift:212-219).
    /// `help` is deliberately absent: it is reachable as a slash command but no button emits it, and
    /// adding a case here that the parser answers `.unknown` to would be a button that does nothing.
    enum Action: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
        case conversations
        case new
        case status
        case cancel
    }

    /// Telegram's `callback_data` limit, in bytes. The binding constraint for all three platforms
    /// because the grammar is shared.
    static let telegramPayloadBudget = 64

    /// The exact bytes the platform carries.
    ///
    /// ⚠️ `UUID.uuidString` is UPPERCASE in Swift and that is what ships today. `parseCallbackData`
    /// feeds it to `UUID(uuidString:)`, which is case-insensitive, so this is not load-bearing for
    /// decoding — but it IS what existing scrollback contains, so keep it.
    var wire: String {
        switch self {
        case .switchConversation(let id):
            return "switch:\(id.uuidString)"
        case .approveHITL(let id):
            return "hitl:approve:\(id.uuidString)"
        case .denyHITL(let id):
            return "hitl:deny:\(id.uuidString)"
        case .gateChoice(let id, let index):
            return "hitl:gate:\(id.uuidString):\(index)"
        case .answerClarification(let id):
            return "hitl:answer:\(id.uuidString)"
        case .selectProfile(let id):
            return "use:\(id.uuidString)"
        case .conversationPage(let offset):
            return "page:\(offset)"
        case .action(let action):
            return "action:\(action.rawValue)"
        }
    }

    /// Whether this token fits the platform's payload budget.
    ///
    /// Every case fits today with room to spare, so this is not a runtime gate — it is the
    /// predicate the standing budget test uses, kept beside the grammar so a new case cannot be
    /// added without a way to check it.
    func fits(budget: Int = CallbackToken.telegramPayloadBudget) -> Bool {
        wire.utf8.count <= budget
    }
}

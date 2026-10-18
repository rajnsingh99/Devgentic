// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CallbackToken.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    /// `hitl:gate:<uuid>:<idx>` carries the option index, never the option label.
    /// The mirror resolves the index back to a label; labels would exceed the 64-byte budget.
    case gateChoice(operationID: UUID, optionIndex: Int)

    /// `hitl:answer:<uuid>` opens a free-text answer for this parked clarification.
    /// 48 bytes, platform-neutral; Telegram force-replies instead of emitting this button.
    case answerClarification(operationID: UUID)

    /// `use:<uuid>` binds this profile to the channel's conversation.
    /// Carries the profile id alone; the conversation comes from the channel's cursor.
    case selectProfile(UUID)

    /// `page:<offset>` shows the conversation list starting at this offset.
    /// An offset rather than a page number, because the read model takes an offset and the page size may change.
    case conversationPage(offset: Int)

    /// `action:<name>` — the fixed verbs a button can invoke with no payload.
    case action(Action)

    /// The `action:` strings `parseCallbackData` accepts.
    /// `help` is absent: no button emits it, and a case the parser answers `.unknown` to would do nothing.
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
    /// `UUID.uuidString` is uppercase, which is the form already present in existing messages.
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
    /// Lets the budget test check every case, so a new case cannot be added without a way to verify it.
    func fits(budget: Int = CallbackToken.telegramPayloadBudget) -> Bool {
        wire.utf8.count <= budget
    }
}

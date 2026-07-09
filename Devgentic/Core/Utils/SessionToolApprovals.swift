//
//  SessionToolApprovals.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation

/// Per-conversation allowlist of tools the user chose **"Allow for this chat"** for on a HITL banner.
///
/// Scope is strictly per-conversation: a choice in one conversation never affects another (the map is
/// keyed by conversationID), and it deliberately does NOT touch the shared agent profile — so an
/// approval can't leak to other conversations the way a profile-wide auto-approve flip would. Unlike a
/// one-time "Allow", this grant covers every later call of the same tool in the SAME conversation,
/// including across app restarts and resumed runs, so the user isn't re-prompted for a tool they
/// already trusted in this chat.
///
/// Durability: the allowlist is mirrored to `UserDefaults` so it survives a quit/relaunch. The
/// permission gate in `executeSingleTool` consults `isAllowed` to skip the confirmation banner. Entries
/// are dropped only when the conversation itself is deleted (`clear`) — NOT at the end of each run.
actor SessionToolApprovals {

    static let shared = SessionToolApprovals()

    /// `UserDefaults` key holding `[conversationID.uuidString: [toolName]]`.
    private static let storeKey = "hitl.perConversationToolApprovals.v1"

    private let defaults: UserDefaults
    private var allowed: [UUID: Set<String>] = [:]

    /// `defaults` is injectable so tests can exercise the durable round-trip on an isolated suite; the
    /// shared singleton uses `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Hydrate from durable storage so an "Allow for this chat" choice survives app restart.
        if let raw = defaults.dictionary(forKey: Self.storeKey) as? [String: [String]] {
            for (key, tools) in raw {
                guard let id = UUID(uuidString: key) else { continue }
                allowed[id] = Set(tools)
            }
        }
    }

    /// Marks `toolName` as allowed for `conversationID` for the lifetime of that conversation.
    func allow(toolName: String, conversationID: UUID) {
        allowed[conversationID, default: []].insert(toolName)
        persist()
    }

    /// Whether the user already chose "Allow for this chat" for this tool in this conversation.
    func isAllowed(toolName: String, conversationID: UUID) -> Bool {
        allowed[conversationID]?.contains(toolName) ?? false
    }

    /// Drops all allowances for a conversation (called when the conversation is deleted).
    func clear(conversationID: UUID) {
        guard allowed.removeValue(forKey: conversationID) != nil else { return }
        persist()
    }

    /// Mirrors the in-memory allowlist to `UserDefaults`.
    private func persist() {
        let raw = allowed.reduce(into: [String: [String]]()) { acc, entry in
            guard !entry.value.isEmpty else { return }
            acc[entry.key.uuidString] = Array(entry.value)
        }
        defaults.set(raw, forKey: Self.storeKey)
    }
}

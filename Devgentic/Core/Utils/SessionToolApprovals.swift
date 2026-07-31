//
//  SessionToolApprovals.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation

/// Allowlist of tools the user chose **"Allow for this chat"** for on a HITL banner.
///
/// Scope is the conversation, and inside a workflow it narrows further to the **node** that asked.
/// A choice in one conversation never affects another, and it deliberately does NOT touch the
/// shared agent profile — so an approval can't leak the way a profile-wide auto-approve flip
/// would. Unlike a one-time "Allow", the grant covers every later call of the same tool in the
/// same scope, including across app restarts and resumed runs, so the user isn't re-prompted for
/// a tool they already trusted here.
///
/// **Why the node is part of the scope.** Every node of a workflow run shares one conversationID,
/// so a conversation-wide grant meant that approving a tool in one node silently auto-approved
/// the same tool in every other node — including nodes the user had deliberately configured to
/// ask. Nodes are independent steps with independent tool configuration, so an approval given to
/// one is not an answer for another: the same tool, with the same arguments, called from a
/// different node asks again if that node is configured to ask. (Decision recorded 2026-07-31.)
///
/// Durability: mirrored to `UserDefaults` so it survives a quit/relaunch. Entries are dropped
/// only when the conversation itself is deleted (`clear`) — NOT at the end of each run.
actor SessionToolApprovals {

    static let shared = SessionToolApprovals()

    /// One approval scope: a conversation, and within a workflow the node that raised the prompt.
    ///
    /// `nodeID` is nil for ordinary chat/code runs, which have no node dimension — those keep
    /// exactly the conversation-wide behaviour they have always had.
    struct Scope: Hashable, Sendable {
        let conversationID: UUID
        let nodeID: UUID?

        init(conversationID: UUID, nodeID: UUID? = nil) {
            self.conversationID = conversationID
            self.nodeID = nodeID
        }

        /// `<conversation>` for a chat grant, `<conversation>|<node>` for a workflow-node grant.
        /// The un-suffixed form is also the v1 on-disk key, so previously persisted grants
        /// hydrate as conversation-scoped rather than being silently dropped.
        var storageKey: String {
            guard let nodeID else { return conversationID.uuidString }
            return "\(conversationID.uuidString)|\(nodeID.uuidString)"
        }

        static func parse(storageKey: String) -> Scope? {
            let parts = storageKey.split(separator: "|", maxSplits: 1).map(String.init)
            guard let conversationID = parts.first.flatMap(UUID.init(uuidString:)) else { return nil }
            guard parts.count == 2 else { return Scope(conversationID: conversationID) }
            guard let nodeID = UUID(uuidString: parts[1]) else { return nil }
            return Scope(conversationID: conversationID, nodeID: nodeID)
        }
    }

    /// Key unchanged from v1 on purpose: the old format is a strict subset of the new one (a key
    /// with no `|` is a conversation-scoped grant), so there is nothing to migrate and no version
    /// bump that would discard grants users already gave.
    private static let storeKey = "hitl.perConversationToolApprovals.v1"

    private let defaults: UserDefaults
    private var allowed: [Scope: Set<String>] = [:]

    /// `defaults` is injectable so tests can exercise the durable round-trip on an isolated suite;
    /// the shared singleton uses `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Hydrate from durable storage so an "Allow for this chat" choice survives app restart.
        if let raw = defaults.dictionary(forKey: Self.storeKey) as? [String: [String]] {
            for (key, tools) in raw {
                guard let scope = Scope.parse(storageKey: key) else { continue }
                allowed[scope] = Set(tools)
            }
        }
    }

    /// Marks `toolName` as allowed for this scope for the lifetime of the conversation.
    func allow(toolName: String, conversationID: UUID, nodeID: UUID? = nil) {
        allowed[Scope(conversationID: conversationID, nodeID: nodeID), default: []].insert(toolName)
        persist()
    }

    /// Whether the user already chose "Allow for this chat" for this tool **in this scope**.
    ///
    /// Deliberately an exact scope match, with no fall back to the conversation-wide grant when a
    /// `nodeID` is supplied: falling back is precisely the leak this scope exists to close.
    func isAllowed(toolName: String, conversationID: UUID, nodeID: UUID? = nil) -> Bool {
        allowed[Scope(conversationID: conversationID, nodeID: nodeID)]?.contains(toolName) ?? false
    }

    /// Drops all allowances for a conversation — every node scope within it included, since the
    /// conversation is what is being deleted.
    func clear(conversationID: UUID) {
        let doomed = allowed.keys.filter { $0.conversationID == conversationID }
        guard !doomed.isEmpty else { return }
        for scope in doomed { allowed.removeValue(forKey: scope) }
        persist()
    }

    /// Mirrors the in-memory allowlist to `UserDefaults`.
    private func persist() {
        let raw = allowed.reduce(into: [String: [String]]()) { acc, entry in
            guard !entry.value.isEmpty else { return }
            acc[entry.key.storageKey] = Array(entry.value)
        }
        defaults.set(raw, forKey: Self.storeKey)
    }
}

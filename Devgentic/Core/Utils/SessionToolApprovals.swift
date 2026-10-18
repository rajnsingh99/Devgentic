// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SessionToolApprovals.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "SessionToolApprovals")

// Why: the node is part of the scope: nodes share one conversationID, so a conversation-wide grant would approve other nodes.
/// Allowlist of tools the user chose "Allow for this chat" for on a HITL banner.
/// Scoped to the conversation, and inside a workflow to the node that asked; it never touches the shared agent profile.
/// Mirrored to `UserDefaults` so grants survive relaunch; entries drop only when the conversation is deleted (`clear`).
actor SessionToolApprovals {

    static let shared = SessionToolApprovals()

    /// One approval scope: a conversation, and within a workflow the node that raised the prompt.
    /// `nodeID` is nil for ordinary chat/code runs, which have no node dimension.
    struct Scope: Hashable, Sendable {
        let conversationID: UUID
        let nodeID: UUID?

        init(conversationID: UUID, nodeID: UUID? = nil) {
            self.conversationID = conversationID
            self.nodeID = nodeID
        }

        /// `<conversation>` for a chat grant, `<conversation>|<node>` for a workflow-node grant.
        /// The un-suffixed form doubles as the on-disk key for conversation-scoped grants.
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

    // Why: a grant must not cross a surface boundary: a bare conversation key let a paired phone inherit a voice grant.
    /// Conversations the user put in a blanket "approve everything" mode (Orb's Autonomous voice setting).
    /// In-memory only, unlike per-tool grants: a standing mode that survived relaunch would outlive the intent behind it.
    /// Checked inside `isAllowed` to inherit the `canReachAHuman` gate; keyed on (conversation, origin).
    private var autonomousConversations: Set<AutonomousGrant> = []

    /// One conversation, for runs started from ONE surface.
    struct AutonomousGrant: Hashable, Sendable {
        let conversationID: UUID
        /// The surface that was granted it, compared against `WorkflowRunAttendance.origin`.
        let origin: MessageSource
    }

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

    // Why: enforce in the model, not only in views: a caller that skipped the check would persist a permanent grant
    // to delete or run shell.
    /// Marks `toolName` as allowed for this scope for the lifetime of the conversation.
    /// `risk` is required and a destructive tool is refused here, since the grant is durable (survives the run and restart).
    func allow(toolName: String, risk: HITLRiskTier, conversationID: UUID, nodeID: UUID? = nil) {
        guard risk != .destructive else {
            logger.error("[HITL] REFUSED a durable 'allow for this chat' grant for destructive tool '\(toolName)' (conv \(conversationID.uuidString.prefix(8))). CONSEQUENCE: no grant was stored — this tool will ask again every time, which is the intended behaviour for something irreversible. The caller should not have offered the option.")
            return
        }
        allowed[Scope(conversationID: conversationID, nodeID: nodeID), default: []].insert(toolName)
        persist()
    }

    // Why: autonomous includes `execute_shell` by design; safety comes from its shape (typed picker, in-memory, one
    // conversation, `canReachAHuman` gate), so do not add a risk filter.
    /// Puts a conversation into (or out of) blanket-approval mode. See `autonomousConversations`.
    /// `origin` is required, not defaulted: a default would let a new caller grant approval to every surface by omission.
    func setAutonomous(_ enabled: Bool, conversationID: UUID, origin: MessageSource) {
        let grant = AutonomousGrant(conversationID: conversationID, origin: origin)
        let changed = enabled
            ? autonomousConversations.insert(grant).inserted
            : autonomousConversations.remove(grant) != nil
        guard changed else { return }
        logger.notice("[HITL] Autonomous approval \(enabled ? "ENABLED" : "disabled") for conversation \(conversationID.uuidString.prefix(8)), origin '\(origin.rawValue)'. CONSEQUENCE: while enabled, every tool in this conversation started FROM THAT SURFACE is approved without a prompt; a run of any other origin still asks. The grant is in-memory only and does not survive relaunch.")
    }

    /// Whether any surface holds a blanket grant on this conversation.
    /// Origin-agnostic on purpose: this answers a UI/reporting question; authorization is `isAllowed`, which compares origin.
    func isAutonomous(conversationID: UUID) -> Bool {
        autonomousConversations.contains { $0.conversationID == conversationID }
    }

    /// Whether the given surface holds a blanket grant on this conversation.
    func isAutonomous(conversationID: UUID, origin: MessageSource) -> Bool {
        autonomousConversations.contains(AutonomousGrant(conversationID: conversationID, origin: origin))
    }

    // Why: a banner grant must not serve scheduled runs nobody can answer; unattended approval is explicit per-node config.
    // ChatOps runs still get it (a human is reachable); blanket grants match `WorkflowRunAttendance.origin`.
    /// Whether the user already chose "Allow for this chat" for this tool in this scope.
    /// An exact scope match, with no fallback to the conversation-wide grant when a `nodeID` is supplied.
    /// Reachable-human runs only: `WorkflowRunAttendance.canReachAHuman` is read from TaskLocals on the caller's task.
    func isAllowed(toolName: String, conversationID: UUID, nodeID: UUID? = nil) -> Bool {
        guard WorkflowRunAttendance.canReachAHuman else {
            if allowed[Scope(conversationID: conversationID, nodeID: nodeID)]?.contains(toolName) == true {
                logger.notice("[HITL] Interactive grant for '\(toolName)' NOT served to a run nobody can answer (conv \(conversationID.uuidString.prefix(8)), scheduled). CONSEQUENCE: the tool is not auto-approved by the banner grant; unattended approval requires the node's explicit 'unattended auto-approve' setting.")
            }
            return false
        }
        let origin = WorkflowRunAttendance.origin
        if autonomousConversations.contains(AutonomousGrant(conversationID: conversationID, origin: origin)) {
            logger.notice("[HITL] '\(toolName)' auto-approved by AUTONOMOUS mode (conv \(conversationID.uuidString.prefix(8)), origin '\(origin.rawValue)'). CONSEQUENCE: no prompt was shown and the user did not see this tool's arguments.")
            return true
        }
        // A grant exists for this conversation but for a different surface: logged so "why did my phone prompt" is answerable.
        if autonomousConversations.contains(where: { $0.conversationID == conversationID }) {
            logger.notice("[HITL] Autonomous grant NOT served to a '\(origin.rawValue)' run of conversation \(conversationID.uuidString.prefix(8)) — the grant belongs to another surface. CONSEQUENCE: this tool asks for approval as normal; a standing 'approve everything' chosen on one surface deliberately does not carry to another.")
        }
        return allowed[Scope(conversationID: conversationID, nodeID: nodeID)]?.contains(toolName) ?? false
    }

    /// Drops all allowances for a conversation — every node scope within it included, since the
    /// conversation is what is being deleted.
    func clear(conversationID: UUID) {
        // Every surface's grant on this conversation: it is being deleted, so no origin retains a claim.
        autonomousConversations = autonomousConversations.filter { $0.conversationID != conversationID }
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

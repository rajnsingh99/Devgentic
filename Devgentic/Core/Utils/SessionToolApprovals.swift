// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SessionToolApprovals.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation

private let logger = DGLogger(category: "SessionToolApprovals")

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

    /// Conversations the user put in a blanket "approve everything" mode — Jarvis's Autonomous
    /// voice setting.
    ///
    /// ⚠️ IN-MEMORY ONLY, never persisted, unlike the per-tool grants above. A per-tool grant is
    /// a deliberate answer to a specific question the user read on a banner; a blanket grant is a
    /// standing mode, and one that survived relaunch would keep approving long after the intent
    /// behind it was forgotten. It is re-established from the Jarvis setting each time a voice
    /// conversation starts, so turning the setting off genuinely turns it off.
    ///
    /// ⚠️ Deliberately checked INSIDE `isAllowed` rather than short-circuiting at the call site,
    /// so it inherits the `canReachAHuman` gate below: a blanket grant given on a live voice
    /// session must not serve a scheduled run nobody can answer.
    private var autonomousConversations: Set<UUID> = []

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
    /// ⚠️ `risk` IS REQUIRED, AND DESTRUCTIVE IS REFUSED HERE.
    ///
    /// This grant is DURABLE: it survives the run and the app restart. Until now the only thing
    /// stopping a destructive tool from getting one was `if confirmation.risk != .destructive`
    /// written inside two SwiftUI views — a View convention standing in for what has to be a model
    /// invariant. Any third caller that forgot the check would have persisted a permanent grant to
    /// delete or run shell.
    ///
    /// This is defence for the NEXT caller. It changes no current behaviour: both existing sites
    /// already guard, so nothing that reaches here today is refused.
    func allow(toolName: String, risk: HITLRiskTier, conversationID: UUID, nodeID: UUID? = nil) {
        guard risk != .destructive else {
            logger.error("[HITL] REFUSED a durable 'allow for this chat' grant for destructive tool '\(toolName)' (conv \(conversationID.uuidString.prefix(8))). CONSEQUENCE: no grant was stored — this tool will ask again every time, which is the intended behaviour for something irreversible. The caller should not have offered the option.")
            return
        }
        allowed[Scope(conversationID: conversationID, nodeID: nodeID), default: []].insert(toolName)
        persist()
    }

    /// Puts a conversation into (or out of) blanket-approval mode. See `autonomousConversations`.
    ///
    /// ⚠️ AUTONOMOUS MEANS AUTONOMOUS — INCLUDING `execute_shell`. Confirmed as intended by the
    /// project owner 2026-09-05: this is the "approve everything in this conversation" switch, and
    /// a version that quietly withheld the destructive tools would be a worse lie than no switch
    /// at all. What keeps it safe is its SHAPE, not a tool filter: it is chosen deliberately from
    /// a typed settings picker (never by voice), held in memory only so it cannot survive a
    /// relaunch, scoped to one conversation, and gated above on `canReachAHuman` so it can never
    /// serve a scheduled run. Do not add a risk filter here.
    ///
    /// The spoken approval channel (`JarvisApprovalPolicy`) is a DIFFERENT question and is
    /// deliberately far narrower — see its header.
    func setAutonomous(_ enabled: Bool, conversationID: UUID) {
        let changed = enabled
            ? autonomousConversations.insert(conversationID).inserted
            : autonomousConversations.remove(conversationID) != nil
        guard changed else { return }
        logger.notice("[HITL] Autonomous approval \(enabled ? "ENABLED" : "disabled") for conversation \(conversationID.uuidString.prefix(8)). CONSEQUENCE: while enabled, every tool in this conversation is approved without a prompt; the grant is in-memory only and does not survive relaunch.")
    }

    func isAutonomous(conversationID: UUID) -> Bool {
        autonomousConversations.contains(conversationID)
    }

    /// Whether the user already chose "Allow for this chat" for this tool **in this scope**.
    ///
    /// Deliberately an exact scope match, with no fall back to the conversation-wide grant when a
    /// `nodeID` is supplied: falling back is precisely the leak this scope exists to close.
    ///
    /// ⚠️ REACHABLE-HUMAN RUNS ONLY [WF-SE6]. `WorkflowRunAttendance.canReachAHuman` is read off
    /// TaskLocals, and this actor method runs on the CALLER's task, so the check reads the run
    /// that is asking with no plumbing (an `await` hops executors but never leaves the task).
    ///
    /// Before this, a grant given on a live banner — labelled "Allow for this **chat**" — was
    /// served to SCHEDULED runs too: a scheduled task reuses one conversationID and one canvas
    /// nodeID on every fire, so a single click became a permanent unattended auto-approve with no
    /// revocation short of deleting the conversation. Unattended approval is now an EXPLICIT
    /// per-node configuration (`WorkflowNodeConfig.unattendedAutoApprove`), never a banner side
    /// effect.
    ///
    /// ⚠️ A CHATOPS run still gets the grant, deliberately: it IS "this chat" with a human who
    /// can be reached, and its confirmations are mirrored with working Approve/Deny. Only a run
    /// nobody can answer is refused.
    func isAllowed(toolName: String, conversationID: UUID, nodeID: UUID? = nil) -> Bool {
        guard WorkflowRunAttendance.canReachAHuman else {
            if allowed[Scope(conversationID: conversationID, nodeID: nodeID)]?.contains(toolName) == true {
                logger.notice("[HITL] Interactive grant for '\(toolName)' NOT served to a run nobody can answer (conv \(conversationID.uuidString.prefix(8)), scheduled). CONSEQUENCE: the tool is not auto-approved by the banner grant; unattended approval requires the node's explicit 'unattended auto-approve' setting.")
            }
            return false
        }
        if autonomousConversations.contains(conversationID) {
            logger.notice("[HITL] '\(toolName)' auto-approved by AUTONOMOUS mode (conv \(conversationID.uuidString.prefix(8))). CONSEQUENCE: no prompt was shown and the user did not see this tool's arguments.")
            return true
        }
        return allowed[Scope(conversationID: conversationID, nodeID: nodeID)]?.contains(toolName) ?? false
    }

    /// Drops all allowances for a conversation — every node scope within it included, since the
    /// conversation is what is being deleted.
    func clear(conversationID: UUID) {
        autonomousConversations.remove(conversationID)
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

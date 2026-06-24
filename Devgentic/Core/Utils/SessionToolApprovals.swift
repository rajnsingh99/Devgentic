//
//  SessionToolApprovals.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation

/// Runtime, per-conversation allowlist of tools the user chose **"Always allow"** for during an
/// in-flight run.
///
/// `BackendProfileService.setToolAutoApprove` persists `requiresConfirmation = false` to the profile,
/// but that only takes effect on the NEXT run — the live tool set (with its `requiresConfirmation`
/// flags) is resolved ONCE at stream start, so subsequent calls in the SAME run still hit the gate.
/// This actor closes that window: "Always allow" registers the tool here, and the permission gate in
/// `executeSingleTool` consults it to skip the banner for the rest of the current run.
///
/// Keyed by conversationID so a choice doesn't leak across conversations. In-memory only (the
/// persisted profile flip is the durable record); entries are cleared when a conversation is drained.
actor SessionToolApprovals {

    static let shared = SessionToolApprovals()

    private var allowed: [UUID: Set<String>] = [:]

    private init() {}

    /// Marks `toolName` as always-allowed for `conversationID` for the remainder of the live run.
    func allow(toolName: String, conversationID: UUID) {
        allowed[conversationID, default: []].insert(toolName)
    }

    /// Whether the user already chose "Always allow" for this tool in this conversation's run.
    func isAllowed(toolName: String, conversationID: UUID) -> Bool {
        allowed[conversationID]?.contains(toolName) ?? false
    }

    /// Drops all session allowances for a conversation (called when its live execution is drained).
    func clear(conversationID: UUID) {
        allowed.removeValue(forKey: conversationID)
    }
}

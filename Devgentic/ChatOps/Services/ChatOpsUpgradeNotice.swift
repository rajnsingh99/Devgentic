// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsUpgradeNotice.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Tells the remote user, in the chat they are watching, that this Mac needs re-pairing because no authorized
/// account was recorded. Posts only to the already-paired address, never for another sender in a shared room, and
/// at most once per provider per process.
@MainActor
enum ChatOpsUpgradeNotice {

    /// What the remote user is told; it names the fix and where to perform it.
    static let message = """
        ⚠️ This Mac was upgraded and needs to be paired again before it can accept commands.

        Open Devgentic → Settings → ChatOps and press Re-pair. Until then every message here is \
        refused, which is why you may have had no reply.
        """

    private static var announced: Set<RemoteChannel.Provider> = []

    /// Whether `provider` is paired to an address but has no authorized account. Pure and separate from the sending, so
    /// a test can check the condition without a transport.
    nonisolated static func needsRepairing(addressPresent: Bool, authorizedUserID: String?) -> Bool {
        addressPresent && authorizedUserID == nil
    }

    /// Announces once, and reports whether this call is the one that should send. The dedup is the return value, so a
    /// caller cannot forget to check it (as with `SlackEventAdmission.admitOnce`).
    static func claimAnnouncement(for provider: RemoteChannel.Provider) -> Bool {
        announced.insert(provider).inserted
    }

    /// Test seam only: the announced set is process-global, so a test resets it to avoid seeing another test's claim.
    static func resetForTesting() {
        announced.removeAll()
    }
}

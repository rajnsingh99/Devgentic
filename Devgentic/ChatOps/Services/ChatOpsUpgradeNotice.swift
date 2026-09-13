// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ChatOpsUpgradeNotice.swift
//  Devgentic
//
//  Telling the remote user, in the chat they are actually looking at, that this Mac needs re-pairing.
//
//  ⚠️⚠️ WHY A MESSAGE AND NOT JUST THE SETTINGS STATE. Per-sender authorization (invariant 38) fails
//  closed for any pairing made before it shipped, and nothing backfills `authorizedUserID` — so after
//  upgrading, every remote command is refused. The Settings pane now says so (see
//  `ChatOpsPairingRestore`), but the person affected is not looking at the Settings pane: they are on
//  their phone, in the chat, watching a bot that has stopped answering. All three gate call sites
//  bare-return, so without this they get nothing at all, forever, with no way to learn why.
//
//  ⚠️ SAFE TO POST, AND THE REASON IS NARROW. This fires ONLY for the "nothing was ever recorded"
//  case — where no account is authorized at all — and only into the chat or channel that is ALREADY
//  the paired address. It is never sent because some other person spoke in a shared room: that is
//  `sender != expected`, a different branch, which stays silent precisely so a bystander cannot probe
//  the bot. Announcing a re-pair to the paired room tells nobody anything they could not already see.
//
//  ⚠️ ONCE PER PROCESS PER PROVIDER. `start()` runs on every toggle and on every launch, and a bot
//  that repeats itself is a bot the user mutes.
//

import Foundation

@MainActor
enum ChatOpsUpgradeNotice {

    /// What the remote user is told. ⚠️ Names the fix and where to perform it — "something went
    /// wrong" would leave them exactly as stuck as the silence did.
    static let message = """
        ⚠️ This Mac was upgraded and needs to be paired again before it can accept commands.

        Open Devgentic → Settings → ChatOps and press Re-pair. Until then every message here is \
        refused, which is why you may have had no reply.
        """

    private static var announced: Set<RemoteChannel.Provider> = []

    /// Whether `provider` is paired to an address but has no authorized account — the upgrade case.
    ///
    /// ⚠️ PURE AND SEPARATE FROM THE SENDING, so a test can pin the condition without a transport.
    nonisolated static func needsRepairing(addressPresent: Bool, authorizedUserID: String?) -> Bool {
        addressPresent && authorizedUserID == nil
    }

    /// Announces once, and reports whether this call is the one that should send.
    ///
    /// ⚠️ THE DEDUP IS THE RETURN VALUE, not a side effect the caller can forget to check — the same
    /// shape as `SlackEventAdmission.admitOnce`, and for the same reason: a `guard` a caller may
    /// simply omit is not a guard.
    static func claimAnnouncement(for provider: RemoteChannel.Provider) -> Bool {
        announced.insert(provider).inserted
    }

    /// ⚠️ TEST SEAM ONLY. The set is process-global on purpose; a test that ran second would
    /// otherwise see another test's claim.
    static func resetForTesting() {
        announced.removeAll()
    }
}

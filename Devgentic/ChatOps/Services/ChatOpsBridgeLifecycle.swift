// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsBridgeLifecycle.swift
//  Devgentic
//
//  Starting a bridge that is already running, and reporting the one that died.
//
//  ⚠️⚠️ SHARED BECAUSE ALL THREE BRIDGES CARRIED THE SAME TWO DEFECTS. They deliberately share no base
//  type — `ChatOpsCoordinator` says so explicitly — so the seam is a pair of static functions each
//  bridge calls, the shape `PairingWindowExpiry` and `ChatOpsUpgradeNotice` already use.
//

import Foundation

enum ChatOpsBridgeStart {

    /// Whether `start()` may proceed.
    ///
    /// ⚠️⚠️ REFUSE, DO NOT RESTART — and the difference is not cosmetic. The obvious repair for a
    /// non-idempotent `start()` is `if isRunning { stop() }`, but `stop()` tears down the mirror
    /// session, which would destroy an IN-FLIGHT tool approval: a user who tapped Approve on their
    /// phone would have the prompt go dead because something re-entered `start()`. A second start is
    /// a caller mistake, not a request to reconnect; the running listener is the one that works.
    ///
    /// ⚠️ WHAT IT PREVENTS. Without this, a second start built a NEW client, listener and transport
    /// and overwrote the stored references — orphaning the previous connection with nothing left able
    /// to cancel it. It kept delivering every event a second time, and `stop()` could no longer reach
    /// it. On Telegram the orphan also kept polling `getUpdates`, so the two loops stole each other's
    /// updates at random (Telegram serves one poller and answers 409 to the other).
    static func shouldProceed(isRunning: Bool,
                              provider: RemoteChannel.Provider,
                              logger: DGLogger) -> Bool {
        guard isRunning else { return true }
        logger.warning("[CHATOPS] A second \(provider.rawValue) bridge start() was refused — one is already running. CONSEQUENCE: no second listener is opened and the existing one keeps serving. Before this guard the previous connection was orphaned rather than cancelled, so every event was delivered twice and stop() could never reach it again.")
        return false
    }
}

enum ChatOpsBridgeShutdown {

    /// Turns a transport's terminal failure into the one property every surface reads.
    ///
    /// ⚠️⚠️ THREE NEAR-IDENTICAL COPIES OF THIS EXISTED AND ONE OF THEM DID NOT EXIST. Telegram and
    /// Slack each turned a `terminalFailure` into `.error(...)`; Discord had no `terminalFailure` at
    /// all, so a permanently-closed Gateway left the Settings pane showing a green "Active" dot for
    /// the life of the process. Sharing the report is what stops the next platform being the one
    /// that gets forgotten.
    ///
    /// - Parameter isOwner: whether the run calling this is still the live one. ⚠️ CHECKED BY THE
    ///   CALLER AND PASSED IN, so this function stays pure and testable; see the generation note at
    ///   each call site. A stale orphan reaching here would otherwise paint a LIVE bridge red with a
    ///   dead run's failure — a user-visible lie on the property every surface reads.
    @discardableResult
    static func report(terminalFailure: String?,
                       provider: RemoteChannel.Provider,
                       isOwner: Bool,
                       logger: DGLogger,
                       write: (ChatOpsConnectionState) -> Void) -> Bool {
        guard isOwner else {
            logger.info("[CHATOPS] A superseded \(provider.rawValue) bridge run ended and was ignored. CONSEQUENCE: none — and that is the point. It is no longer the live run, so it must not write the connection state; before this check a stale run could paint a working bridge red with its own dead failure.")
            return false
        }
        guard let terminalFailure else {
            logger.info("[CHATOPS] The \(provider.rawValue) bridge stopped. CONSEQUENCE: none — it was asked to stop and no failure was recorded.")
            return false
        }
        write(.error(terminalFailure))
        logger.error("[CHATOPS] The \(provider.rawValue) bridge stopped because the platform will not serve it: \(terminalFailure) CONSEQUENCE: remote control over \(provider.rawValue) is DEAD until the user acts — no command is received and no notification is announced. The Settings connection status now shows this reason in red rather than a green 'Active' dot; it will not recover on its own.")
        return true
    }
}

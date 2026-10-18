// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsBridgeLifecycle.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Shared start-up helpers for the ChatOps bridges: refusing a second start and reporting a bridge that died.
/// The bridges share no base type, so each calls these static functions.
enum ChatOpsBridgeStart {

    // Why: stop() tears down the mirror session and kills a pending approval;
    // a second start would otherwise orphan the first connection with nothing able to cancel it.
    /// Whether `start()` may proceed.
    /// Refuses a second start while running instead of restarting, so an in-flight tool approval survives.
    static func shouldProceed(isRunning: Bool,
                              provider: RemoteChannel.Provider,
                              logger: DGLogger) -> Bool {
        guard isRunning else { return true }
        logger.warning("[CHATOPS] A second \(provider.rawValue) bridge start() was refused — one is already running. CONSEQUENCE: no second listener is opened and the existing one keeps serving. Before this guard the previous connection was orphaned rather than cancelled, so every event was delivered twice and stop() could never reach it again.")
        return false
    }
}

enum ChatOpsBridgeShutdown {

    // Why: a stale run must not paint a live bridge with a dead run's failure.
    /// Turns a transport's terminal failure into the status property every surface reads.
    /// - Parameter isOwner: whether the calling run is still the live one; passed in so this function stays pure.
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

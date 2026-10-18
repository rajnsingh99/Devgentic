// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsFarewell.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The last message a provider sends before its credentials are wiped.
/// Shared by all three platforms so a failed send is made visible (logged with its consequence) rather than swallowed;
/// it never throws, since disconnecting must not be blockable by a network failure.
enum ChatOpsFarewell {

    /// One literal, so three platforms cannot drift into three goodbyes.
    static let message = "Devgentic ChatOps disconnected. Goodbye!"

    /// Runs `send`, and logs a failure with the consequence that follows from it.
    ///
    /// - Parameter provider: named in the log, so a failure says WHICH chat never heard.
    static func send(provider: RemoteChannel.Provider,
                     logger: DGLogger,
                     _ send: () async throws -> Void) async {
        do {
            try await send()
        } catch {
            logger.warning("[CHATOPS] Failed to send the \(provider.rawValue) farewell before unpairing: \(error.localizedDescription). CONSEQUENCE: the credentials are wiped anyway, so the bot simply stops answering with no goodbye — the user cannot tell a deliberate disconnect from a crash, and nothing can retry because the token is gone a moment later.")
        }
    }
}

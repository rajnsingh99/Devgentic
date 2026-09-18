// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsFarewell.swift
//  Devgentic
//
//  The last message a provider sends before its credentials are wiped.
//
//  ⚠️⚠️ SHARED BECAUSE THE BUG WAS THE SHAPE, NOT THE PLATFORM. All three `disconnect()` bodies sent
//  the same sentence; Telegram wrapped it in `do/catch` and named its consequence, while Discord and
//  Slack wrote `_ = try? await client.sendMessage(...)` and swallowed the failure. That is this
//  subsystem's signature defect — one platform fixed, two left — and it survived a silent-drop test
//  suite that only ever scanned the three BRIDGES, never the pairing services.
//
//  ⚠️ THE FAILURE GENUINELY MATTERS HERE, which is why it is not an allowed silence. This is the only
//  notice the remote user gets that the disconnection was deliberate; lose it and the bot simply stops
//  answering, leaving them unable to tell "unpaired on purpose" from "crashed". Nothing can retry,
//  either — the token is deleted a moment later.
//
//  ⚠️ IT STILL DOES NOT THROW. Disconnecting must not be blockable by a network failure: the
//  credentials are wiped whatever happens here. The fix is to make the drop VISIBLE, not to make it
//  fatal.
//

import Foundation

enum ChatOpsFarewell {

    /// ⚠️ One literal, so three platforms cannot drift into three goodbyes.
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

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPServerAddFlow.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "MCPServerAddFlow")

/// What the form learns from an add. This was a `Bool` meaning "not a duplicate", which had no way
/// to say "the save itself failed" — and so it never did.
enum MCPAddOutcome {
    case added
    case duplicate
    case failed(MCPUserError)
}

@MainActor
enum MCPServerAddFlow {

    /// Adds a server, persisting its OAuth bundle first under the id the row will get.
    /// `persistBundle` throws on failure; `addTool` returns nil when the store could not insert;
    /// `discardBundle` removes a bundle written for a row that was never created.
    static func add(
        serverName: String,
        oauthBundle: MCPOAuthCredentialBundle?,
        isDuplicate: (String) -> Bool,
        persistBundle: (MCPOAuthCredentialBundle, UUID) throws -> Void,
        addTool: (UUID) -> UUID?,
        discardBundle: (UUID) -> Void
    ) -> MCPAddOutcome {
        if isDuplicate(serverName) { return .duplicate }

        // Chosen HERE so the bundle can be written before the row exists.
        let newID = UUID()

        if let oauthBundle {
            do {
                try persistBundle(oauthBundle, newID)
            } catch {
                logger.error("""
                    [MCP-OAUTH] Could not store the OAuth sign-in for the new server \
                    '\(serverName)': \(error.localizedDescription). CONSEQUENCE: the server was NOT \
                    added; the user is shown the failure, and the completed sign-in stays in the \
                    form so pressing Add again retries the write without another browser round trip.
                    """)
                return .failed(MCPUserError(
                    title: "Sign-in could not be saved",
                    message: "The server was verified and signed in, but its credentials could not be written to the Keychain, so it was not added.",
                    suggestion: "Unlock your login keychain (or allow Devgentic access if macOS asked), then press Add again — the sign-in you completed is still held by this form.",
                    rawLog: error.localizedDescription
                ))
            }
        }

        guard addTool(newID) != nil else {
            // Do not leave a live grant in the Keychain under an id nothing references.
            if oauthBundle != nil { discardBundle(newID) }
            logger.error("""
                [MCP-STORE] The new server '\(serverName)' could not be inserted. CONSEQUENCE: \
                nothing was saved (an OAuth bundle written ahead of the row has been removed again) \
                and the user is shown the failure instead of a dismissed form.
                """)
            return .failed(MCPUserError(
                title: "Server could not be saved",
                message: "The server could not be written to the Tool Library.",
                suggestion: "Try again; if it keeps failing, look for [MCP-STORE] in the log.",
                rawLog: nil
            ))
        }
        return .added
    }

    /// Persists a re-authenticated OAuth bundle ahead of an edit; returns true when a write happened.
    /// Only a changed bundle is written. When `stored == nil` the comparison fails closed: the write is attempted and,
    /// if it fails, the edit is refused.
    @discardableResult
    static func persistIfChanged(
        _ oauthBundle: MCPOAuthCredentialBundle?,
        stored: MCPOAuthCredentialBundle?,
        sourceID: UUID,
        persist: (MCPOAuthCredentialBundle, UUID) throws -> Void
    ) throws -> Bool {
        guard let oauthBundle, oauthBundle != stored else { return false }
        try persist(oauthBundle, sourceID)
        return true
    }
}

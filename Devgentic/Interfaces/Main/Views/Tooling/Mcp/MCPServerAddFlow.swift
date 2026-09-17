// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MCPServerAddFlow.swift
//  Devgentic
//
//  The order of operations for saving an MCP server that carries an OAuth sign-in. Register KC-5.
//
//  ⚠️ WHY THIS IS NOT INLINE IN THE CONTAINER VIEW. Adding a server used to be: insert the row,
//  THEN `try? MCPOAuthCoordinator.persist(bundle, sourceID: newID)`. A Keychain refusal — a locked
//  login keychain, or the ACL prompt after a re-sign or a Sparkle update — threw away a sign-in the
//  user had just completed in the browser: no log, no UI, the form dismissed as though it had
//  succeeded, and the server sat in the library with no credentials. The fix is an ordering rule
//  (the step that can fail runs FIRST, keyed on the identity the row will get) plus an outcome the
//  form can show. Both live here behind injected collaborators, so the ordering is testable without
//  SwiftUI, SwiftData or a Keychain — and the container's wiring is one call.
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

    /// Adds a server, persisting its OAuth bundle FIRST under the id the row will get.
    ///
    /// - Parameters:
    ///   - isDuplicate: whether `serverName` is already taken.
    ///   - persistBundle: writes the bundle under the given source id; throws on failure.
    ///   - addTool: inserts the row under the given id; nil when the store could not.
    ///   - discardBundle: removes a bundle written for a row that was never created.
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

    /// Persists a re-authenticated OAuth bundle AHEAD of an edit. Register KC-5, edit path.
    ///
    /// ⚠️ Only a CHANGED bundle is written. The form holds the stored bundle from the moment the
    /// editor opened, so on a plain rename `oauthBundle == stored` and there is nothing to persist —
    /// refusing a rename over a write it does not need would be a regression. When the stored
    /// bundle cannot be read (`stored == nil`) the comparison fails closed: the write is attempted,
    /// and if it fails the edit is refused rather than applied over an unconfirmed sign-in.
    /// - Returns: true when a write happened.
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

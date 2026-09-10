// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MCPOAuthBrowserRedirectHandler.swift
//  Devgentic
//
//  Concrete `MCPOAuthRedirectHandler` for desktop OAuth: spins up a one-shot
//  loopback listener, opens the authorize URL in the user's default browser,
//  awaits the redirect, validates the `state` round-trip, and returns the
//  authorization code.
//
//  Notes on browser choice:
//   - We use `NSWorkspace.open` (not ASWebAuthenticationSession) because
//     ASWebAuthenticationSession's `callbackURLScheme` can't match a loopback
//     `http://127.0.0.1` redirect URL — it only matches custom schemes.
//   - For users who'd prefer the in-app modal browser, Phase 4 can add a
//     custom-scheme variant (`devgentic://oauth/callback`) gated on Info.plist
//     registration. Loopback works without any project-level setup.
//

import AppKit
import Foundation
import os

private let logger = DGLogger(category: "MCPOAuthBrowserHandler")

enum MCPOAuthBrowserError: LocalizedError {
    case stateMismatch
    case authorizationServerError(error: String, description: String?)
    case openBrowserFailed
    case missingCode

    var errorDescription: String? {
        switch self {
        case .stateMismatch:
            return "Authorization redirect failed CSRF check (state mismatch). Sign in again."
        case .authorizationServerError(let err, let desc):
            return desc.map { "\(err): \($0)" } ?? "Authorization failed: \(err)"
        case .openBrowserFailed:
            return "Couldn't open the system browser. Try copying the URL manually."
        case .missingCode:
            return "Authorization redirect did not include a `code` parameter."
        }
    }
}

@MainActor
struct MCPOAuthBrowserRedirectHandler: MCPOAuthRedirectHandler {

    /// Default 5-minute window. Long enough for slow logins (MFA prompts,
    /// password manager dance) without leaving a listener bound forever.
    let timeout: TimeInterval

    init(timeout: TimeInterval = 300) {
        self.timeout = timeout
    }

    func awaitAuthorizationCode(
        authorizeURL: URL,
        redirectURI: URL,
        expectedState: String
    ) async throws -> String {
        // The listener owns its port and shuts itself down on success/timeout/cancel.
        // We hand its `redirectURL` to the AS via the authorize URL's `redirect_uri`
        // — caller has already done that, since they built the authorize URL with
        // this listener's redirect URL.
        guard NSWorkspace.shared.open(authorizeURL) else {
            throw MCPOAuthBrowserError.openBrowserFailed
        }
        logger.info("Opened authorize URL in default browser")

        // The actual listener was constructed by the caller (through the
        // coordinator) and its URL was used to build `redirectURI`. We have
        // to construct ours fresh here, but Phase 3's coordinator path
        // builds the listener inside this handler (see `runFlow` below).
        // The protocol method receives `redirectURI` already, so we re-bind
        // an internal listener here that the coordinator's authorize URL
        // is already pointing at.
        //
        // Implementation reality: the loopback listener has to be the
        // *same instance* whose URL got embedded in the authorize URL.
        // The coordinator hands us that URL via `redirectURI` — we look up
        // the live listener in `LoopbackRegistry` (a small per-flow map).
        guard let listener = LoopbackRegistry.shared.listener(for: redirectURI) else {
            throw MCPOAuthBrowserError.openBrowserFailed
        }

        let components: URLComponents
        do {
            components = try await listener.awaitCallback(timeout: timeout)
        } catch {
            LoopbackRegistry.shared.unregister(redirectURL: redirectURI)
            throw error
        }
        LoopbackRegistry.shared.unregister(redirectURL: redirectURI)

        // Validate state round-trip first — before reading `code`. A state
        // mismatch is the canonical sign of a redirect-confusion attack and
        // we want to fail loud rather than smuggle a hostile code through.
        let receivedState = components.queryItems?.first(where: { $0.name == "state" })?.value
        guard receivedState == expectedState else {
            throw MCPOAuthBrowserError.stateMismatch
        }

        // Some ASes redirect with `?error=…&error_description=…` instead of
        // `?code=…` when the user denies consent. Surface that cleanly.
        if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
            let description = components.queryItems?.first(where: { $0.name == "error_description" })?.value
            throw MCPOAuthBrowserError.authorizationServerError(error: error, description: description)
        }

        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw MCPOAuthBrowserError.missingCode
        }
        return code
    }
}

/// Tracks live loopback listeners by their redirect URL so the redirect
/// handler can find the right listener instance to await. Necessary because
/// the coordinator constructs the listener (so it can build the authorize
/// URL with the right `redirect_uri`) but the handler is who awaits the
/// callback — they need to share the same listener.
@MainActor
final class LoopbackRegistry {

    static let shared = LoopbackRegistry()

    private var listeners: [URL: MCPOAuthLoopbackListener] = [:]

    private init() {}

    func register(_ listener: MCPOAuthLoopbackListener) {
        listeners[listener.redirectURL] = listener
    }

    func listener(for redirectURL: URL) -> MCPOAuthLoopbackListener? {
        listeners[redirectURL]
    }

    func unregister(redirectURL: URL) {
        listeners.removeValue(forKey: redirectURL)
    }
}

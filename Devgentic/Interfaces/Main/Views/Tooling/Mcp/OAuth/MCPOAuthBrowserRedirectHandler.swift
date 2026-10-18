// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPOAuthBrowserRedirectHandler.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import AppKit
import Foundation
import os

private let logger = DGLogger(category: "MCPOAuthBrowserHandler")

/// Errors raised by the browser-based OAuth redirect handler.
enum MCPOAuthBrowserError: LocalizedError {
    case stateMismatch
    case authorizationServerError(error: String, description: String?)
    case openBrowserFailed
    /// The loopback listener this flow depends on is not registered; distinct from failing to open the browser.
    case noLoopbackListener
    case missingCode

    var errorDescription: String? {
        switch self {
        case .stateMismatch:
            return "Authorization redirect failed CSRF check (state mismatch). Sign in again."
        case .authorizationServerError(let err, let desc):
            return desc.map { "\(err): \($0)" } ?? "Authorization failed: \(err)"
        case .openBrowserFailed:
            return "Couldn't open the system browser. Try copying the URL manually."
        case .noLoopbackListener:
            return "The local redirect listener for this sign-in is no longer running. Restart the sign-in."
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
        // Why: look up the listener before opening the browser, so a missing one throws before the user starts a login.
        // Resolve the live listener for `redirectURI` from `LoopbackRegistry`; it owns its port and shuts itself down.
        // It must be the same instance whose URL was embedded in the authorize URL.
        guard let listener = LoopbackRegistry.shared.listener(for: redirectURI) else {
            throw MCPOAuthBrowserError.noLoopbackListener
        }
        guard NSWorkspace.shared.open(authorizeURL) else {
            throw MCPOAuthBrowserError.openBrowserFailed
        }
        logger.info("Opened authorize URL in default browser")

        let components: URLComponents
        do {
            components = try await listener.awaitCallback(timeout: timeout)
        } catch {
            LoopbackRegistry.shared.unregister(redirectURL: redirectURI)
            throw error
        }
        LoopbackRegistry.shared.unregister(redirectURL: redirectURI)

        // Validate the state round-trip before reading `code`: a mismatch signals redirect confusion,
        // so fail loudly rather than accept a hostile code.
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

/// Tracks live loopback listeners by redirect URL so the redirect handler can find the instance to await.
/// The coordinator builds the listener (for the authorize URL) but the handler awaits it, so both share one.
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
